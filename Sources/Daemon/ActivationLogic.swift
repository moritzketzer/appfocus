// Sources/Daemon/ActivationLogic.swift
import AppKit
import Foundation

final class ActivationLogic {
    private let config: AppFocusConfig
    private let backend: WindowBackend
    private let launcher: AppLauncher
    private let store: StateStore
    private let processChecker: ProcessChecker

    /// Serial queue guarding the command pump's mutable state
    /// (`currentToken`, `running`, `runningApp`, `pending`).
    private let activationQueue = DispatchQueue(label: "appfocus.activation")
    private var currentToken: UInt64 = 0

    // MARK: - Command pump state (guarded by activationQueue)

    /// A queued command: its resolved target app (`nil` for cycle) plus the
    /// closure that runs its async chain with a fresh token and a completion.
    private struct PumpJob {
        let app: String?
        let run: (_ token: UInt64, _ done: @escaping () -> Void) -> Void
    }
    private var running = false
    private var runningApp: String?
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
    var hungBackoff: TimeInterval = 1.0
    /// Backstop against pathological backlog during a slow-but-completing yabai.
    /// Generous: normal fast input drains faster than it arrives so the queue
    /// stays tiny, and a true hang is handled by the watchdog (which drops the
    /// backlog), so this only bites an extreme hammer during a slow spell.
    var maxPending = 16

    /// While `DispatchTime.now() < hungUntil`, yabai is presumed hung and new
    /// commands are dropped. Initialised to "now" (healthy).
    private var hungUntil = DispatchTime.now()

    init(config: AppFocusConfig, backend: WindowBackend,
         launcher: AppLauncher, store: StateStore,
         processChecker: ProcessChecker) {
        self.config = config
        self.backend = backend
        self.launcher = launcher
        self.store = store
        self.processChecker = processChecker
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
    private func submit(app: String?,
                        _ run: @escaping (UInt64, @escaping () -> Void) -> Void) {
        let job = PumpJob(app: app, run: run)
        var start: (UInt64, PumpJob)?
        var action = ""
        activationQueue.sync {
            // Circuit breaker: if a recent command timed out on yabai, drop new
            // commands briefly instead of hammering the still-hung backend.
            if DispatchTime.now() < hungUntil {
                action = "DROP \(app ?? "cycle") (yabai unresponsive, backing off)"
                return
            }
            if running, let newApp = app,
               let curApp = runningApp, curApp != newApp {
                // Genuine target change: cancel the in-flight command's async
                // tail (bump token) and run the new jump immediately.
                currentToken &+= 1
                pending.removeAll()
                runningApp = newApp
                start = (currentToken, job)
                action = "SUPERSEDE \(curApp)->\(newApp) tok=\(currentToken)"
            } else if running {
                // Cap the queue so hammering during a slow spell can't build a
                // backlog that storms when yabai recovers; keep the newest.
                if pending.count >= self.maxPending {
                    pending.removeFirst()
                    action = "QUEUE \(app ?? "cycle") (cap: dropped oldest) depth=\(pending.count + 1)"
                } else {
                    action = "QUEUE \(app ?? "cycle") behind \(runningApp ?? "cycle") depth=\(pending.count + 1)"
                }
                pending.append(job)
            } else {
                running = true
                currentToken &+= 1
                runningApp = app
                start = (currentToken, job)
                action = "START \(app ?? "cycle") tok=\(currentToken)"
            }
        }
        Log.debug("pump: \(action)")
        if let (token, job) = start { runJob(token, job) }
    }

    /// Run one job outside the state lock. Wraps its completion so the pump is
    /// advanced exactly once, regardless of how many terminal paths call it.
    private func runJob(_ token: UInt64, _ job: PumpJob) {
        // Watchdog: if this command hasn't finished by the deadline, assume
        // yabai is hung and force-release the pump. Runs off the activation
        // queue so it can take the lock. Self-invalidates when the command
        // finished normally (token no longer current).
        DispatchQueue.global().asyncAfter(deadline: .now() + self.commandDeadline) { [self] in
            self.watchdogFire(token)
        }
        let lock = NSLock()
        var fired = false
        job.run(token) { [self] in
            lock.lock(); let first = !fired; fired = true; lock.unlock()
            guard first else { return }
            self.finish(token)
        }
    }

    /// Force-release the pump when a command overran the deadline (yabai hung).
    /// Bumps the token so the wedged command's late callbacks bail, drops the
    /// backlog, and backs off so the next presses don't immediately re-hammer a
    /// still-hung yabai.
    private func watchdogFire(_ token: UInt64) {
        var fired = false
        activationQueue.sync {
            guard token == currentToken, running else { return }  // already finished
            currentToken &+= 1
            pending.removeAll()
            running = false
            runningApp = nil
            hungUntil = DispatchTime.now() + self.hungBackoff
            fired = true
        }
        if fired {
            Log.error("pump: WATCHDOG tok=\(token) exceeded \(self.commandDeadline)s — yabai unresponsive; released + backing off \(self.hungBackoff)s")
        }
    }

    /// Test hook: synchronously fire the watchdog on the in-flight command,
    /// exercising the force-release path deterministically without waiting on
    /// the real GCD timer (which races under parallel test execution).
    func fireWatchdogNowForTesting() {
        watchdogFire(activationQueue.sync { currentToken })
    }

    /// Advance the pump when a command completes. Ignored when the completing
    /// command was already superseded (its token is no longer current), so a
    /// cancelled command's late callback cannot start the next one twice.
    private func finish(_ token: UInt64) {
        var next: (UInt64, PumpJob)?
        var note = ""
        activationQueue.sync {
            guard token == currentToken else { note = "STALE tok=\(token) cur=\(currentToken)"; return }
            // A normal completion means yabai responded — clear any backoff.
            hungUntil = DispatchTime.now()
            if pending.isEmpty {
                running = false
                runningApp = nil
                note = "DONE tok=\(token) idle"
            } else {
                let job = pending.removeFirst()
                currentToken &+= 1
                runningApp = job.app
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
        submit(app: appName) { [self] token, done in
            Log.info("jump: \(appName)")
            self.performJump(appName: appName, token: token, done: done)
        }
    }

    private func performJump(appName: String, token: UInt64,
                             done: @escaping () -> Void) {
        // Step 1: Get fresh focus state before proceeding
        backend.focusedWindow { [self] focused in
            guard self.isActive(token) else { done(); return }

            // Record the pre-jump focused window only if it is a real window;
            // a focused sticky dialog must not pollute MRU state.
            if let focused = focused, focused.isStandardWindow {
                let canonical = self.config.resolveAlias(focused.appName)
                self.store.recordFocus(appName: canonical, windowId: focused.id, space: focused.space)
            }

            // Step 2: Query windows for the target app
            self.backend.queryAllWindows { allWindows in
                guard self.isActive(token) else { done(); return }
                let windows = self.windowsForApp(appName, from: allWindows)

                if windows.isEmpty {
                    self.handleNoWindows(appName: appName, focused: focused,
                                         token: token, done: done)
                } else {
                    self.handleHasWindows(appName: appName, windows: windows,
                                          focused: focused, token: token, done: done)
                }
            }
        }
    }

    private func handleNoWindows(appName: String, focused: WindowInfo?,
                                 token: UInt64, done: @escaping () -> Void) {
        // Check if app is running (has process but no windows)
        let isRunning = processChecker.isAppRunning(name: appName)

        if isRunning {
            Log.info("jump: \(appName) running but no windows, reopening")
            let strategy = config.reopenStrategy(for: appName)
            launcher.reopen(appName: appName, strategy: strategy) { [self] in
                guard self.isActive(token) else { done(); return }
                self.pollForWindow(appName: appName, focused: focused,
                                   token: token, done: done)
            }
        } else {
            Log.info("jump: \(appName) not running, launching")
            launcher.launch(appName: appName) { [self] success in
                guard self.isActive(token), success else { done(); return }
                self.pollForWindow(appName: appName, focused: focused,
                                   token: token, done: done)
            }
        }
    }

    private func handleHasWindows(appName: String, windows: [WindowInfo],
                                    focused: WindowInfo?, token: UInt64,
                                    done: @escaping () -> Void) {
        // Only treat the app as "already focused" (MRU toggle / cycle) when a
        // REAL window of it is focused. If a sticky dialog is focused, fall
        // through to focusBestWindow so the standard window stays reachable
        // (otherwise the single-real-window case hits mruToggleOrCycle's
        // count==1 no-op and the standard window becomes unreachable).
        if let focused = focused, focused.isStandardWindow,
           config.resolveAlias(focused.appName) == appName {
            mruToggleOrCycle(appName: appName, windows: windows,
                             focused: focused, token: token, done: done)
        } else {
            focusBestWindow(appName: appName, windows: windows,
                            focused: focused, token: token, done: done)
        }
    }

    private func mruToggleOrCycle(appName: String, windows: [WindowInfo],
                                   focused: WindowInfo, token: UInt64,
                                   done: @escaping () -> Void) {
        guard windows.count > 1 else {
            Log.info("jump: \(appName) already focused, only 1 window")
            done(); return
        }

        let state = store.state(for: appName)
        let windowIds = Set(windows.map { $0.id })

        if let prevId = state.prevFocusedId, windowIds.contains(prevId) {
            Log.info("jump: \(appName) MRU switch to window \(prevId)")
            store.recordFocus(appName: appName, windowId: prevId)
            if let target = windows.first(where: { $0.id == prevId }) {
                focusWindow(target, from: focused, token: token, done: done)
            } else {
                done()
            }
        } else {
            Log.info("jump: \(appName) no prev window, cycling next")
            let effectiveId = state.lastFocusedId ?? focused.id
            cycleWithKnownState(appName: appName, windows: windows,
                                focusedId: effectiveId, direction: .next,
                                current: focused, token: token, done: done)
        }
    }

    private func focusBestWindow(appName: String, windows: [WindowInfo],
                                 focused: WindowInfo?, token: UInt64,
                                 done: @escaping () -> Void) {
        let state = store.state(for: appName)

        let target = state.lastFocusedId.flatMap { lastId in
            windows.first(where: { $0.id == lastId })
        } ?? windows.first

        guard let target = target else {
            Log.error("jump: no target window for \(appName)")
            done(); return
        }

        Log.info("jump: focusing window \(target.id) for \(appName)")
        focusWindow(target, from: focused, token: token, done: done)
    }

    private func focusWindow(_ target: WindowInfo, from current: WindowInfo?,
                             token: UInt64, done: @escaping () -> Void) {
        let focusTarget = { [self] in
            guard isActive(token) else { done(); return }
            backend.focusWindow(id: target.id) { success in
                if !success {
                    Log.error("focus: yabai focus failed for window \(target.id)")
                }
                done()
            }
        }

        if let current, current.isStandardWindow,
           current.space == target.space {
            focusTarget()
            return
        }

        Log.info("focus: switching to space \(target.space) for window \(target.id)")
        backend.focusSpace(index: target.space) { [self] success in
            guard isActive(token) else { done(); return }
            guard success else {
                Log.error("focus: yabai focus failed for space \(target.space)")
                done(); return
            }
            focusTarget()
        }
    }

    private static let windowPollMaxAttempts = 15
    private static let windowPollInterval: TimeInterval = 0.2

    private func pollForWindow(appName: String, focused: WindowInfo?,
                               token: UInt64, attempt: Int = 0,
                               done: @escaping () -> Void) {
        guard attempt < Self.windowPollMaxAttempts else {
            Log.error("jump: timed out waiting for \(appName) window")
            done(); return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.windowPollInterval) { [self] in
            guard self.isActive(token) else { done(); return }

            self.backend.queryAllWindows { allWindows in
                let windows = self.windowsForApp(appName, from: allWindows)
                guard self.isActive(token) else { done(); return }

                if let win = windows.first {
                    Log.info("jump: found window for \(appName) after \(attempt + 1) polls")
                    self.focusWindow(win, from: focused, token: token, done: done)
                } else {
                    self.pollForWindow(appName: appName, focused: focused,
                                       token: token, attempt: attempt + 1, done: done)
                }
            }
        }
    }

    // MARK: - Next/Prev

    /// Cycle windows using pre-fetched state. No async calls.
    private func cycleWithKnownState(appName: String, windows: [WindowInfo],
                                      focusedId: Int, direction: CycleDirection,
                                      current: WindowInfo, token: UInt64,
                                      done: @escaping () -> Void) {
        guard isActive(token) else { done(); return }
        guard windows.count > 1 else {
            Log.info("cycle: only \(windows.count) window(s)")
            done(); return
        }

        store.update(appName: appName) { state in
            state.ring = Self.preserveRingOrder(prevRing: state.ring, windows: windows)
        }

        let ring = store.state(for: appName).ring
        guard ring.count > 1 else { done(); return }

        let currentIdx = ring.firstIndex(of: focusedId) ?? 0
        let step = direction == .next ? 1 : -1
        let nextIdx = (currentIdx + step + ring.count) % ring.count
        let nextId = ring[nextIdx]

        Log.info("cycle: \(currentIdx) -> \(nextIdx) of \(ring.count) (window \(nextId))")
        store.recordFocus(appName: appName, windowId: nextId)
        if let target = windows.first(where: { $0.id == nextId }) {
            focusWindow(target, from: current, token: token, done: done)
        } else {
            done()
        }
    }

    func cycle(direction: CycleDirection) {
        submit(app: nil) { [self] token, done in
            Log.info("cycle: \(direction)")
            self.performCycle(direction: direction, token: token, done: done)
        }
    }

    private func performCycle(direction: CycleDirection, token: UInt64,
                              done: @escaping () -> Void) {
        backend.focusedWindow { [self] focused in
            // Separate supersession from a genuinely missing focused window:
            // a superseded command is expected and silent, whereas a nil
            // focused window is a real yabai state worth logging. Conflating
            // them (the old combined guard) made every superseded cycle log
            // "cycle: no focused window".
            guard self.isActive(token) else { done(); return }
            guard let focused = focused else {
                Log.error("cycle: no focused window")
                done(); return
            }

            let appName = self.config.resolveAlias(focused.appName)

            self.backend.queryAllWindows { allWindows in
                guard self.isActive(token) else { done(); return }
                let windows = self.windowsForApp(appName, from: allWindows)
                self.cycleWithKnownState(appName: appName, windows: windows,
                                          focusedId: focused.id, direction: direction,
                                          current: focused, token: token, done: done)
            }
        }
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
