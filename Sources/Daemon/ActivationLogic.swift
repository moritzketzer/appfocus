// Sources/Daemon/ActivationLogic.swift
import AppKit
import Foundation

final class ActivationLogic {
    private let config: AppFocusConfig
    private let backend: WindowBackend
    private let launcher: AppLauncher
    private let store: StateStore
    private let processChecker: ProcessChecker
    private let workspace: ApplicationWorkspace
    private let model: WindowModelStore
    private let verifier: OutcomeVerifying

    /// Serial queue guarding the command pump's mutable state
    /// (`currentToken`, `running`, `runningApp`, `pending`).
    private let activationQueue = DispatchQueue(label: "appfocus.activation")
    private var currentToken: UInt64 = 0

    // MARK: - Command pump state (guarded by activationQueue)

    private enum JobDomain {
        case application
        case window
    }

    /// A queued command: its resolved target app (`nil` for cycle) plus the
    /// closure that runs its async chain with a fresh token and a completion.
    private struct PumpJob {
        let domain: JobDomain
        let app: String?
        let trace: CommandTrace
        let run: (_ token: UInt64, _ done: @escaping () -> Void) -> Void
    }
    private var running = false
    private var runningDomain: JobDomain?
    private var runningApp: String?
    private var runningTrace: CommandTrace?
    private var pending: [PumpJob] = []

    // MARK: - Resilience to a hung/slow yabai
    //
    // yabai intermittently blocks for seconds to minutes inside an
    // uninterruptible WindowServer/AX call (observed 38s and 328s hangs). Since
    // every command waits on yabai, a serial pump would otherwise wedge for the
    // full hang and pile up a backlog that storms on recovery. Three guards keep
    // the switcher self-healing:
    //   1. Watchdog — a command that doesn't finish within `commandDeadline` is
    //      force-abandoned (its token is bumped so its late callbacks bail), and
    //      the pump is released. No single hung call can freeze it for minutes.
    //   2. Backoff — after a watchdog fire, new commands are dropped for
    //      `hungBackoff` instead of hammering the still-hung yabai; a normal
    //      completion clears it immediately (auto-recover).
    //   3. Cap — at most `maxPending` queued commands, so hammering during a
    //      slow spell can't build a backlog that storms when yabai returns.

    /// Watchdog deadline. Instance-mutable so tests can shorten it without
    /// racing other parallel tests. A legit cross-Space jump is ~1-1.5s and the
    /// launch/poll path is bounded at ~3s, but during a hang we prefer to
    /// release early and retry over waiting.
    var commandDeadline: TimeInterval = 3.0
    var applicationDeadline: TimeInterval = 3.0
    var hungBackoff: TimeInterval = 1.0
    /// Backstop against pathological backlog during a slow-but-completing yabai.
    /// Generous: normal fast input drains faster than it arrives so the queue
    /// stays tiny, and a true hang is handled by the watchdog (which drops the
    /// backlog), so this only bites an extreme hammer during a slow spell.
    var maxPending = 16

    /// While `DispatchTime.now() < hungUntil`, yabai is presumed hung and new
    /// commands are dropped. Initialised to "now" (healthy).
    private var hungUntil = DispatchTime.now()

    // MARK: - One-shot retry of a watchdog-dropped focus action
    //
    // Observed: a cross-Space jump kept hitting the stall window and being
    // watchdog-dropped while quick same-Space toggles landed in the gaps, so
    // the user had to re-press. When the watchdog drops a command whose focus
    // TARGET was already resolved, replay just the focus action once after
    // the backoff. The decision logic is never replayed (an already-recorded
    // MRU toggle must not double-toggle), launch/reopen never retries, and
    // any newer user command cancels the pending retry.

    private struct RetryTarget {
        let appName: String?
        let windowId: Int
    }
    /// The in-flight command's resolved focus target (guarded by activationQueue).
    private var inFlightTarget: (token: UInt64, target: RetryTarget)?
    /// Armed by the watchdog, consumed (or cancelled) exactly once.
    private var pendingRetry: RetryTarget?

    init(config: AppFocusConfig, backend: WindowBackend,
         launcher: AppLauncher, store: StateStore,
         processChecker: ProcessChecker,
         workspace: ApplicationWorkspace = SystemApplicationWorkspace(),
         model: WindowModelStore,
         verifier: OutcomeVerifying) {
        self.config = config
        self.backend = backend
        self.launcher = launcher
        self.store = store
        self.processChecker = processChecker
        self.workspace = workspace
        self.model = model
        self.verifier = verifier
    }

    // MARK: - Command pump (in-order serialization)

    /// Submit a command to the pump. Commands run one at a time, in order, so
    /// rapid repeated navigation compounds step-by-step instead of collapsing
    /// to the last press. Each command's async chain reads a settled focus
    /// state — the previous command has already committed its focus — which is
    /// what makes `next`/`prev` and same-app `jump` MRU toggles advance once
    /// per press.
    ///
    /// Last-write-wins is retained for a *genuine target change*: a `jump` to a
    /// different app than the in-flight command supersedes it (bumps the token,
    /// cancelling its async tail) and runs immediately. That is the cross-Space
    /// stale-callback protection — an older command's `focusSpace`/`focusWindow`
    /// continuation must not steal focus after a newer, different jump. A
    /// command that continues navigating the same context (`next`/`prev`, or a
    /// `jump` to the same app) is never a stale-focus hazard, so it queues and
    /// compounds instead of being discarded.
    private func submit(domain: JobDomain, app: String?, trace: CommandTrace,
                        userInitiated: Bool = true,
                        _ run: @escaping (UInt64, @escaping () -> Void) -> Void) {
        let job = PumpJob(domain: domain, app: app, trace: trace, run: run)
        var start: (UInt64, PumpJob)?
        var action = ""
        var recordNow: [CommandTrace] = []
        activationQueue.sync {
            // A fresh user command expresses newer intent than any armed
            // retry. Clearing INSIDE this critical section (not in a separate
            // sync before submit) closes the race where a watchdog fire
            // interleaves between clear and breaker-check and revives a stale
            // target against the newer press.
            if userInitiated { pendingRetry = nil }
            // The breaker protects yabai only. Native application activation
            // remains available while the window backend is backing off.
            if job.domain == .window, DispatchTime.now() < hungUntil {
                action = "DROP \(app ?? "cycle") (yabai unresponsive, backing off)"
                trace.update { $0.outcome = "dropped-backoff" }
                recordNow.append(trace)
                return
            }
            let targetChanged = app != nil && runningApp != nil
                && app != runningApp
            let applicationSupersedesWindow = job.domain == .application
                && runningDomain == .window
            if running, targetChanged || applicationSupersedesWindow {
                let previousApp = runningApp
                // Genuine target change: cancel the in-flight command's async
                // tail (bump token) and run the new jump immediately. Native
                // activation also supersedes any window job, including cycle.
                currentToken &+= 1
                if let cur = runningTrace {
                    cur.update { $0.outcome = "superseded" }
                    recordNow.append(cur)
                }
                for dropped in pending {
                    dropped.trace.update { $0.outcome = "superseded" }
                    recordNow.append(dropped.trace)
                }
                pending.removeAll()
                inFlightTarget = nil
                runningDomain = job.domain
                runningApp = app
                runningTrace = job.trace
                start = (currentToken, job)
                action = "SUPERSEDE \(previousApp ?? "cycle")->\(app ?? "cycle") tok=\(currentToken)"
            } else if running {
                // Cap only queued window work. Repeated native activations are
                // ordered user intent and never participate in the yabai cap.
                let queuedWindows = pending.indices.filter {
                    pending[$0].domain == .window
                }
                if job.domain == .window,
                   queuedWindows.count >= self.maxPending,
                   let evictionIndex = queuedWindows.first {
                    let evicted = pending.remove(at: evictionIndex)
                    evicted.trace.update { $0.outcome = "dropped-cap" }
                    recordNow.append(evicted.trace)
                    action = "QUEUE \(app ?? "cycle") (cap: dropped oldest) depth=\(pending.count + 1)"
                } else {
                    action = "QUEUE \(app ?? "cycle") behind \(runningApp ?? "cycle") depth=\(pending.count + 1)"
                }
                pending.append(job)
            } else {
                running = true
                currentToken &+= 1
                runningDomain = job.domain
                runningApp = app
                runningTrace = job.trace
                start = (currentToken, job)
                action = "START \(app ?? "cycle") tok=\(currentToken)"
            }
        }
        Log.debug("pump: \(action)")
        for t in recordNow { verifier.recordImmediate(t) }
        if let (token, job) = start { runJob(token, job) }
    }

    /// Run one job outside the state lock. Wraps its completion so the pump is
    /// advanced exactly once, regardless of how many terminal paths call it.
    private func runJob(_ token: UInt64, _ job: PumpJob) {
        // A new command is about to act: any pending verification of a
        // previous command can no longer be attributed truthfully.
        verifier.commandStarted()
        let lock = NSLock()
        var fired = false
        let claimCompletion = {
            lock.lock(); defer { lock.unlock() }
            guard !fired else { return false }
            fired = true
            return true
        }
        let deadline = job.domain == .application
            ? applicationDeadline : commandDeadline
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [self] in
            guard claimCompletion() else { return }
            if job.domain == .application {
                self.applicationDeadlineFire(token)
            } else {
                self.watchdogFire(token)
            }
        }
        job.run(token) { [self] in
            guard claimCompletion() else { return }
            self.finish(token, domain: job.domain)
        }
    }

    /// Release a native activation whose AppKit callback never arrived. This
    /// fences late callbacks and advances queued work without touching yabai's
    /// breaker or retry state.
    private func applicationDeadlineFire(_ token: UInt64) {
        var next: (UInt64, PumpJob)?
        var fired = false
        activationQueue.sync {
            guard token == currentToken, running,
                  runningDomain == .application else { return }
            currentToken &+= 1
            if let trace = runningTrace {
                trace.update { $0.outcome = "native-timeout" }
                verifier.recordImmediate(trace)
            }
            if pending.isEmpty {
                running = false
                runningDomain = nil
                runningApp = nil
                runningTrace = nil
            } else {
                let job = pending.removeFirst()
                runningDomain = job.domain
                runningApp = job.app
                runningTrace = job.trace
                next = (currentToken, job)
            }
            fired = true
        }
        if fired {
            Log.error("pump: native activation tok=\(token) exceeded \(applicationDeadline)s")
        }
        if let (nextToken, job) = next { runJob(nextToken, job) }
    }

    /// Force-release the pump when a command overran the deadline (yabai hung).
    /// Bumps the token so the wedged command's late callbacks bail, drops the
    /// backlog, and backs off so the next presses don't immediately re-hammer a
    /// still-hung yabai.
    private func watchdogFire(_ token: UInt64) {
        var fired = false
        var armed = false
        var timedOut: [CommandTrace] = []
        activationQueue.sync {
            guard token == currentToken, running,
                  runningDomain == .window else { return }
            currentToken &+= 1
            if let cur = runningTrace {
                cur.update { $0.outcome = "timeout" }
                timedOut.append(cur)
            }
            for dropped in pending {
                dropped.trace.update {
                    $0.outcome = "dropped-cap"
                    $0.detail = "backlog dropped by watchdog"
                }
                timedOut.append(dropped.trace)
            }
            pending.removeAll()
            running = false
            runningDomain = nil
            runningApp = nil
            runningTrace = nil
            hungUntil = DispatchTime.now() + self.hungBackoff
            fired = true
            if let f = inFlightTarget, f.token == token {
                pendingRetry = f.target
                armed = true
            }
            inFlightTarget = nil
        }
        for t in timedOut { verifier.recordImmediate(t) }
        if fired {
            Log.error("pump: WATCHDOG tok=\(token) exceeded \(self.commandDeadline)s — yabai unresponsive; released + backing off \(self.hungBackoff)s")
        }
        if armed {
            // Fire just past the backoff window so the resubmission is not
            // dropped by the circuit breaker.
            DispatchQueue.global().asyncAfter(deadline: .now() + hungBackoff + 0.05) { [weak self] in
                self?.submitPendingRetry()
            }
        }
    }

    /// Submit the armed retry through the normal pump: re-validate the target
    /// against the current model and replay ONLY the focus action. One shot —
    /// the pending slot is cleared before submission, and the replayed focus
    /// runs with armRetry=false so its own watchdog drop cannot re-arm.
    private func submitPendingRetry() {
        var retry: RetryTarget?
        activationQueue.sync {
            retry = pendingRetry
            pendingRetry = nil
        }
        guard let retry else { return }  // cancelled by a newer user command
        let trace = CommandTrace(command: "jump", app: retry.appName)
        trace.update { $0.path = "retry" }
        submit(domain: .window, app: retry.appName, trace: trace,
               userInitiated: false) { [self] token, done in
            let windows = self.model.snapshot().windows
            guard let target = windows.first(where: { $0.id == retry.windowId }),
                  target.isStandardWindow, !target.isMinimized else {
                Log.info("retry: window \(retry.windowId) gone, dropping")
                trace.update {
                    $0.outcome = "noop"
                    $0.detail = "retry target gone"
                }
                done(); return
            }
            Log.info("retry: replaying focus for window \(target.id)")
            // focusSpace is issued unconditionally now; the model's focused
            // window only labels the trace's same/cross stats split.
            self.focusWindow(target, from: self.model.focusedWindow,
                             trace: trace, token: token, armRetry: false,
                             done: done)
        }
    }

    /// Test hook: synchronously fire the watchdog on the in-flight command,
    /// exercising the force-release path deterministically without waiting on
    /// the real GCD timer (which races under parallel test execution).
    func fireWatchdogNowForTesting() {
        watchdogFire(activationQueue.sync { currentToken })
    }

    /// Test hook: the pump holds no in-flight or queued command. The core
    /// resilience invariant is that this becomes true again after any command
    /// sequence drains — the pump is never left permanently wedged.
    var isIdleForTesting: Bool {
        activationQueue.sync { !running && pending.isEmpty }
    }

    /// Advance the pump when a command completes. Ignored when the completing
    /// command was already superseded (its token is no longer current), so a
    /// cancelled command's late callback cannot start the next one twice.
    private func finish(_ token: UInt64, domain: JobDomain) {
        var next: (UInt64, PumpJob)?
        var note = ""
        var completed: CommandTrace?
        activationQueue.sync {
            guard token == currentToken else { note = "STALE tok=\(token) cur=\(currentToken)"; return }
            if domain == .window {
                // Only a normal window completion proves yabai recovered.
                hungUntil = DispatchTime.now()
                if inFlightTarget?.token == token { inFlightTarget = nil }
            }
            completed = runningTrace
            // Hand the completed trace to the verifier INSIDE this critical
            // section: when the pump goes idle, a keypress on another thread
            // could otherwise START (and enqueue commandStarted on the
            // verifier queue) before this trace's verify() enqueues —
            // reordering that would let a stale verification be attributed
            // mid-next-command. Both verifier calls are non-blocking
            // queue.async wrappers, so no lock-order hazard.
            if let completed = completed {
                if completed.currentOutcome == "unknown" {
                    verifier.verify(completed)
                } else {
                    verifier.recordImmediate(completed)
                }
            }
            if pending.isEmpty {
                running = false
                runningDomain = nil
                runningApp = nil
                runningTrace = nil
                note = "DONE tok=\(token) idle"
            } else {
                let job = pending.removeFirst()
                currentToken &+= 1
                runningDomain = job.domain
                runningApp = job.app
                runningTrace = job.trace
                next = (currentToken, job)
                note = "DONE tok=\(token) -> next tok=\(currentToken) depth=\(pending.count)"
            }
        }
        Log.debug("pump: \(note)")
        if let (token, job) = next { runJob(token, job) }
    }

    private func isActive(_ token: UInt64) -> Bool {
        return activationQueue.sync { currentToken == token }
    }

    // MARK: - Alias filtering

    private func windowsForApp(_ appName: String, from allWindows: [WindowInfo]) -> [WindowInfo] {
        allWindows.filter { config.resolveAlias($0.appName) == appName
                            && !$0.isMinimized && $0.isStandardWindow }
    }

    // MARK: - Jump

    func jump(appName rawName: String) {
        let appName = config.resolveAlias(rawName)
        let trace = CommandTrace(command: "jump", app: appName)
        let bundleIdentifier = config.bundleIdentifier(for: appName)
        let frontmost = workspace.frontmostApplication
        let targetIsFrontmost: Bool
        if let bundleIdentifier {
            targetIsFrontmost = frontmost?.bundleIdentifier == bundleIdentifier
        } else {
            targetIsFrontmost = frontmost?.localizedName.map(config.resolveAlias)
                == appName
        }

        if !targetIsFrontmost {
            trace.update {
                $0.path = bundleIdentifier == nil
                    ? ApplicationActionPath.legacyName.rawValue
                    : ApplicationActionPath.nativeBundle.rawValue
                $0.verificationTargetKind = .application
                $0.targetBundleIdentifier = bundleIdentifier
                $0.decidedAt = .now()
            }
            submit(domain: .application, app: appName,
                   trace: trace) { [self] token, done in
                Log.info("jump: activating \(appName)")
                self.launcher.activate(
                    appName: appName,
                    bundleIdentifier: bundleIdentifier
                ) { result in
                    guard self.isActive(token) else { done(); return }
                    trace.update {
                        $0.path = result.path.rawValue
                        $0.actionedAt = .now()
                        if !result.success {
                            $0.outcome = "failed"
                            $0.detail = result.detail
                        }
                    }
                    done()
                }
            }
            return
        }

        submit(domain: .window, app: appName, trace: trace) { [self] token, done in
            Log.info("jump: \(appName)")
            self.performJump(appName: appName, trace: trace, token: token, done: done)
        }
    }

    private func performJump(appName: String, trace: CommandTrace,
                             token: UInt64, done: @escaping () -> Void) {
        // Read the model ONCE — no yabai round-trip on the hot path, and no
        // torn read across a concurrent poller rebuild. A stalled
        // WindowServer now only delays the background refresh, never a press.
        let snapshot = model.snapshot()
        let focused = snapshot.focusedId.flatMap { id in
            snapshot.windows.first(where: { $0.id == id })
        }

        // Record the pre-jump focused window only if it is a real window;
        // a focused sticky dialog must not pollute MRU state.
        if let focused = focused, focused.isStandardWindow {
            let canonical = config.resolveAlias(focused.appName)
            store.recordFocus(appName: canonical, windowId: focused.id,
                              space: focused.space)
        }

        let windows = windowsForApp(appName, from: snapshot.windows)
        trace.update {
            $0.modelGeneration = snapshot.generation
            $0.modelFocusedId = snapshot.focusedId
        }
        if windows.isEmpty {
            trace.update { $0.path = "confirm" }
            confirmNoWindows(appName: appName, focused: focused,
                             trace: trace, token: token, done: done)
        } else {
            trace.update { $0.path = "hot" }
            handleHasWindows(appName: appName, windows: windows,
                             focused: focused, trace: trace,
                             token: token, done: done)
        }
    }

    /// The one deliberately fresh read: a stale "no windows" would reopen a
    /// duplicate window (the Safari-reopen bug class), so this rare branch
    /// pays for a live query and feeds the result back into the model.
    private func confirmNoWindows(appName: String, focused: WindowInfo?,
                                  trace: CommandTrace,
                                  token: UInt64, done: @escaping () -> Void) {
        backend.queryAllWindows { [self] all in
            guard self.isActive(token) else { done(); return }
            guard let all = all else {
                // Query FAILED — indistinguishable from "no windows" only if
                // conflated, and acting on it would reopen a duplicate. Do
                // nothing; the press is lost, the next one retries.
                Log.error("jump: confirm query failed for \(appName), not reopening")
                trace.update {
                    $0.outcome = "failed"
                    $0.detail = "confirm query failed"
                }
                done(); return
            }
            self.model.replaceSnapshot(all)
            let windows = self.windowsForApp(appName, from: all)
            if windows.isEmpty {
                let axless = all.filter {
                    self.config.resolveAlias($0.appName) == appName
                        && !$0.isMinimized && $0.isAXlessCandidate
                }
                self.handleNoWindows(appName: appName, focused: focused,
                                     axlessCandidates: axless, trace: trace,
                                     token: token, done: done)
            } else {
                Log.info("jump: confirm found \(windows.count) window(s) for \(appName)")
                self.handleHasWindows(appName: appName, windows: windows,
                                      focused: focused, trace: trace,
                                      token: token, done: done)
            }
        }
    }

    private func handleNoWindows(appName: String, focused: WindowInfo?,
                                 axlessCandidates: [WindowInfo],
                                 trace: CommandTrace,
                                 token: UInt64, done: @escaping () -> Void) {
        // Check if app is running (has process but no windows)
        let isRunning = processChecker.isAppRunning(name: appName)

        if isRunning {
            // AX-less fallback: the app HAS a would-be-standard window, but
            // yabai holds no AX reference for it (ChatGPT's lazy-ephemeral
            // Chromium AX tree), so it cannot be focused via the backend.
            // Reopening surfaces nothing; switching to the window's Space and
            // natively activating the app does — and being frontmost on its
            // own Space is what lets the AX tree materialize.
            if let target = axlessCandidates.first {
                Log.error("jump: \(appName) has \(axlessCandidates.count) window(s) without AX reference — native fallback to space \(target.space); tiling needs a warm yabai restart (see gotchas)")
                trace.update {
                    $0.path = "fallback"
                    $0.targetSpace = target.space
                    $0.crossedSpace = true
                    $0.decidedAt = .now()
                }
                backend.focusSpace(index: target.space) { [self] _ in
                    guard self.isActive(token) else { done(); return }
                    launcher.activate(appName: appName) {
                        trace.update { $0.actionedAt = .now() }
                        done()
                    }
                }
                return
            }
            Log.info("jump: \(appName) running but no windows, reopening")
            trace.update {
                $0.path = "reopen"
                $0.decidedAt = .now()
            }
            let strategy = config.reopenStrategy(for: appName)
            launcher.reopen(appName: appName, strategy: strategy) { [self] in
                guard self.isActive(token) else { done(); return }
                self.pollForWindow(appName: appName, focused: focused,
                                   trace: trace, token: token, done: done)
            }
        } else {
            Log.info("jump: \(appName) not running, launching")
            trace.update {
                $0.path = "launch"
                $0.decidedAt = .now()
            }
            launcher.launch(appName: appName) { [self] success in
                guard self.isActive(token), success else {
                    if !success {
                        trace.update {
                            $0.outcome = "failed"
                            $0.detail = "launch failed"
                        }
                    }
                    done(); return
                }
                self.pollForWindow(appName: appName, focused: focused,
                                   trace: trace, token: token, done: done)
            }
        }
    }

    private func handleHasWindows(appName: String, windows: [WindowInfo],
                                    focused: WindowInfo?, trace: CommandTrace,
                                    token: UInt64,
                                    done: @escaping () -> Void) {
        // Only treat the app as "already focused" (MRU toggle / cycle) when a
        // REAL window of it is focused. If a sticky dialog is focused, fall
        // through to focusBestWindow so the standard window stays reachable
        // (otherwise the single-real-window case hits mruToggleOrCycle's
        // count==1 no-op and the standard window becomes unreachable).
        if let focused = focused, focused.isStandardWindow,
           config.resolveAlias(focused.appName) == appName {
            mruToggleOrCycle(appName: appName, windows: windows,
                             focused: focused, trace: trace,
                             token: token, done: done)
        } else {
            focusBestWindow(appName: appName, windows: windows,
                            focused: focused, trace: trace,
                            token: token, done: done)
        }
    }

    private func mruToggleOrCycle(appName: String, windows: [WindowInfo],
                                   focused: WindowInfo, trace: CommandTrace,
                                   token: UInt64,
                                   done: @escaping () -> Void) {
        guard windows.count > 1 else {
            // Re-assert focus instead of no-oping. The model can claim the
            // app is focused while the world is mid-transition — observed
            // live: a superseded command's uncancellable `space --focus` was
            // still in flight, this branch no-oped the press, and the zombie
            // Space switch then carried the user AWAY (the 10% Space-1 dead
            // presses, 2026-08-16). Re-asserting is idempotent and
            // guarantees "jump X" always ENDS on X.
            // focusSpace is now issued unconditionally in focusWindow, so
            // the real `focused` is safe to pass — it only labels the
            // trace's same/cross stats split honestly.
            Log.info("jump: \(appName) already focused, single window — re-asserting")
            focusBestWindow(appName: appName, windows: windows,
                            focused: focused, trace: trace,
                            token: token, done: done)
            return
        }

        let state = store.state(for: appName)
        let windowIds = Set(windows.map { $0.id })

        if let prevId = state.prevFocusedId, windowIds.contains(prevId) {
            Log.info("jump: \(appName) MRU switch to window \(prevId)")
            store.recordFocus(appName: appName, windowId: prevId)
            if let target = windows.first(where: { $0.id == prevId }) {
                focusWindow(target, from: focused, trace: trace,
                            token: token, done: done)
            } else {
                trace.update {
                    $0.outcome = "failed"
                    $0.detail = "MRU target vanished from window set"
                }
                done()
            }
        } else {
            Log.info("jump: \(appName) no prev window, cycling next")
            let effectiveId = state.lastFocusedId ?? focused.id
            cycleWithKnownState(appName: appName, windows: windows,
                                focusedId: effectiveId, direction: .next,
                                current: focused, trace: trace,
                                token: token, done: done)
        }
    }

    private func focusBestWindow(appName: String, windows: [WindowInfo],
                                 focused: WindowInfo?, trace: CommandTrace,
                                 token: UInt64,
                                 done: @escaping () -> Void) {
        let state = store.state(for: appName)

        let target = state.lastFocusedId.flatMap { lastId in
            windows.first(where: { $0.id == lastId })
        } ?? windows.first

        guard let target = target else {
            Log.error("jump: no target window for \(appName)")
            trace.update {
                $0.outcome = "failed"
                $0.detail = "no target window"
            }
            done(); return
        }

        Log.info("jump: focusing window \(target.id) for \(appName)")
        focusWindow(target, from: focused, trace: trace,
                    token: token, done: done)
    }

    private func focusWindow(_ target: WindowInfo, from current: WindowInfo?,
                             trace: CommandTrace,
                             token: UInt64, armRetry: Bool = true,
                             done: @escaping () -> Void) {
        trace.update {
            $0.targetWindowId = target.id
            $0.targetSpace = target.space
            $0.decidedAt = .now()
        }
        if armRetry {
            // The focus target is resolved: if the watchdog drops this
            // command mid-action, the retry can replay exactly this focus.
            let retry = RetryTarget(appName: config.resolveAlias(target.appName),
                                    windowId: target.id)
            activationQueue.sync { inFlightTarget = (token, retry) }
        }
        let focusTarget = { [self] in
            guard isActive(token) else { done(); return }
            backend.focusWindow(id: target.id) { success in
                trace.update { $0.actionedAt = .now() }
                if success {
                    // Read-your-writes: the next queued command must see the
                    // settled focus without a query, so bursts compound.
                    // Deliberately NOT token-gated: the model records the
                    // last-COMPLETED focus action. A superseded command's
                    // late-landing success really did move OS focus, so the
                    // unguarded write tracks reality better than a fenced
                    // one would; any residual disagreement self-heals at the
                    // next poll.
                    self.model.noteFocused(id: target.id)
                } else {
                    Log.error("focus: yabai focus failed for window \(target.id)")
                    trace.update {
                        $0.outcome = "failed"
                        $0.detail = "yabai window focus failed"
                    }
                }
                done()
            }
        }

        // ALWAYS issue the Space switch — the same-Space skip is gone. Three
        // separate live defects came from trusting the model's Space claim
        // (superseded-zombie dead press, re-assert invisible landing, and
        // the first-press invisible landing at 09:45:58 on 2026-08-16 where
        // a stale model skipped the switch and the press needed a re-press).
        // The skip saved one ~10-70ms subprocess call on same-Space presses;
        // focusSpace on the already-active Space errors harmlessly and the
        // chain continues to the window focus either way. Correctness over
        // a micro-optimization. `crossedSpace` still records the MODEL's
        // view for the stats' same/cross split.
        if let current, current.isStandardWindow,
           current.space == target.space {
            trace.update { $0.crossedSpace = false }
        } else {
            trace.update { $0.crossedSpace = true }
        }
        Log.info("focus: switching to space \(target.space) for window \(target.id)")
        backend.focusSpace(index: target.space) { [self] success in
            guard isActive(token) else { done(); return }
            if !success {
                // yabai refuses to focus an already-focused Space, and a
                // stale model can make this call spurious — aborting here
                // made the press do nothing at all (observed live). Continue
                // to the window focus: if we were already on the target
                // Space it lands visibly; a genuine Space-focus failure
                // still sets AX focus and the next press retries fresher.
                // Info, not error: the always-issued re-assert Space switch
                // hits "already focused" on every healthy same-Space press;
                // genuine anomalies surface as `invisible` telemetry.
                Log.info("focus: yabai space focus for \(target.space) failed — continuing to window focus")
            }
            focusTarget()
        }
    }

    private static let windowPollMaxAttempts = 15
    private static let windowPollInterval: TimeInterval = 0.2

    private func pollForWindow(appName: String, focused: WindowInfo?,
                               trace: CommandTrace,
                               token: UInt64, attempt: Int = 0,
                               done: @escaping () -> Void) {
        guard attempt < Self.windowPollMaxAttempts else {
            Log.error("jump: timed out waiting for \(appName) window")
            trace.update {
                $0.outcome = "failed"
                $0.detail = "timed out waiting for window after launch/reopen"
            }
            done(); return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.windowPollInterval) { [self] in
            guard self.isActive(token) else { done(); return }

            self.backend.queryAllWindows { allWindows in
                // nil = failed query: keep polling on the next attempt.
                if let allWindows { self.model.replaceSnapshot(allWindows) }
                let windows = self.windowsForApp(appName, from: allWindows ?? [])
                guard self.isActive(token) else { done(); return }

                if let win = windows.first {
                    Log.info("jump: found window for \(appName) after \(attempt + 1) polls")
                    self.focusWindow(win, from: focused, trace: trace,
                                     token: token, done: done)
                } else {
                    self.pollForWindow(appName: appName, focused: focused,
                                       trace: trace, token: token,
                                       attempt: attempt + 1, done: done)
                }
            }
        }
    }

    // MARK: - Next/Prev

    /// Cycle windows using pre-fetched state. No async calls.
    private func cycleWithKnownState(appName: String, windows: [WindowInfo],
                                      focusedId: Int, direction: CycleDirection,
                                      current: WindowInfo, trace: CommandTrace,
                                      token: UInt64,
                                      done: @escaping () -> Void) {
        guard isActive(token) else { done(); return }
        guard windows.count > 1 else {
            Log.info("cycle: only \(windows.count) window(s)")
            trace.update {
                $0.path = "noop"
                $0.outcome = "noop"
                $0.detail = "only \(windows.count) window(s)"
            }
            done(); return
        }

        store.update(appName: appName) { state in
            state.ring = Self.preserveRingOrder(prevRing: state.ring, windows: windows)
        }

        let ring = store.state(for: appName).ring
        guard ring.count > 1 else {
            trace.update {
                $0.path = "noop"
                $0.outcome = "noop"
                $0.detail = "ring too small"
            }
            done(); return
        }

        let currentIdx = ring.firstIndex(of: focusedId) ?? 0
        let step = direction == .next ? 1 : -1
        let nextIdx = (currentIdx + step + ring.count) % ring.count
        let nextId = ring[nextIdx]

        Log.info("cycle: \(currentIdx) -> \(nextIdx) of \(ring.count) (window \(nextId))")
        store.recordFocus(appName: appName, windowId: nextId)
        if let target = windows.first(where: { $0.id == nextId }) {
            focusWindow(target, from: current, trace: trace,
                        token: token, done: done)
        } else {
            trace.update {
                $0.outcome = "failed"
                $0.detail = "ring id \(nextId) not in window set"
            }
            done()
        }
    }

    func cycle(direction: CycleDirection) {
        let trace = CommandTrace(command: direction.rawValue, app: nil)
        submit(domain: .window, app: nil, trace: trace) { [self] token, done in
            Log.info("cycle: \(direction)")
            self.performCycle(direction: direction, trace: trace, token: token, done: done)
        }
    }

    private func performCycle(direction: CycleDirection, trace: CommandTrace,
                              token: UInt64,
                              done: @escaping () -> Void) {
        // One model read — no yabai queries, no torn read across a poller
        // rebuild. The pump has already settled the previous command's focus
        // into the model (optimistic update).
        let snapshot = model.snapshot()
        trace.update {
            $0.path = "hot"
            $0.modelGeneration = snapshot.generation
            $0.modelFocusedId = snapshot.focusedId
        }
        guard let focused = snapshot.focusedId.flatMap({ id in
            snapshot.windows.first(where: { $0.id == id })
        }) else {
            Log.error("cycle: no focused window")
            trace.update {
                $0.outcome = "failed"
                $0.detail = "no focused window in model"
            }
            done(); return
        }

        let appName = config.resolveAlias(focused.appName)
        let windows = windowsForApp(appName, from: snapshot.windows)
        cycleWithKnownState(appName: appName, windows: windows,
                            focusedId: focused.id, direction: direction,
                            current: focused, trace: trace,
                            token: token, done: done)
    }

    enum CycleDirection: String {
        case next, prev
    }

    // MARK: - Ring reconciliation

    static func preserveRingOrder(prevRing: [Int], windows: [WindowInfo]) -> [Int] {
        let currentIds = Set(windows.map { $0.id })

        // Keep existing ring entries that still exist
        var kept = prevRing.filter { currentIds.contains($0) }

        if kept.isEmpty {
            // Fresh ring: sort by space then ID
            return windows
                .sorted { ($0.space, $0.id) < ($1.space, $1.id) }
                .map { $0.id }
        }

        // Append new windows not already in ring
        let keptSet = Set(kept)
        for win in windows where !keptSet.contains(win.id) {
            kept.append(win.id)
        }
        return kept
    }
}
