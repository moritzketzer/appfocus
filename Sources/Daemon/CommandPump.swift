// Sources/Daemon/CommandPump.swift
import Foundation

/// Serializes commands: one runs at a time, in order, with a watchdog, a
/// circuit breaker, a queue cap, and a one-shot retry of a watchdog-dropped
/// focus action. Owns no decision logic — the owner supplies each command's
/// async chain as a closure and replays a retry through `retryRunner`.
final class CommandPump {
    private let verifier: OutcomeVerifying

    /// Replays the focus action of a watchdog-dropped command. Set by the
    /// owner after construction, because it closes over the owner — set once,
    /// before the first submit, and never reassigned: a reassignment racing a
    /// retry fire is a data race. Left unwired, consumed retries vanish
    /// silently.
    var retryRunner: (RetryTarget) -> Void = { _ in }

    /// Serial queue guarding the command pump's mutable state
    /// (`currentToken`, `running`, `runningApp`, `pending`).
    private let activationQueue = DispatchQueue(label: "appfocus.activation")
    /// Serializes pump transitions with the instant a job invokes its action.
    /// Recursive because synchronous callbacks can finish one job and start
    /// the next before the original `job.run` invocation unwinds.
    private let jobStartLock = NSRecursiveLock()
    private var currentToken: UInt64 = 0

    // MARK: - Command pump state (guarded by activationQueue)

    enum JobDomain {
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

    struct RetryTarget {
        let appName: String?
        let windowId: Int
    }
    /// The in-flight command's resolved focus target (guarded by activationQueue).
    private var inFlightTarget: (token: UInt64, target: RetryTarget)?
    /// Armed by the watchdog, consumed (or cancelled) exactly once.
    private var pendingRetry: RetryTarget?

    private func withPumpTransition<T>(_ body: () -> T) -> T {
        jobStartLock.lock()
        defer { jobStartLock.unlock() }
        return activationQueue.sync(execute: body)
    }

    init(verifier: OutcomeVerifying) {
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
    func submit(domain: JobDomain, app: String?, trace: CommandTrace,
                userInitiated: Bool = true,
                _ run: @escaping (UInt64, @escaping () -> Void) -> Void) {
        let job = PumpJob(domain: domain, app: app, trace: trace, run: run)
        var start: (UInt64, PumpJob)?
        var action = ""
        var recordNow: [CommandTrace] = []
        withPumpTransition {
            // A fresh user command expresses newer intent than any armed
            // retry. Clearing INSIDE this critical section (not in a separate
            // sync before submit) closes the race where a watchdog fire
            // interleaves between clear and breaker-check and revives a stale
            // target against the newer press.
            if userInitiated { pendingRetry = nil }
            // The breaker protects yabai only. Native application activation
            // remains available while the window backend is backing off.
            if job.domain == .window, DispatchTime.now() < hungUntil {
                action = dropForBackoff(job, recordNow: &recordNow)
                return
            }
            let targetChanged = app != nil && runningApp != nil
                && app != runningApp
            let applicationSupersedesWindow = job.domain == .application
                && runningDomain == .window
            if running, targetChanged || applicationSupersedesWindow {
                action = supersedeRunning(with: job, start: &start,
                                          recordNow: &recordNow)
            } else if running {
                action = enqueue(job, recordNow: &recordNow)
            } else {
                action = startFresh(job, start: &start)
            }
        }
        Log.debug("pump: \(action)")
        for t in recordNow { verifier.recordImmediate(t) }
        if let (token, job) = start { runJob(token, job) }
    }

    /// Drop a window command while the breaker is open. Runs inside
    /// `withPumpTransition`.
    private func dropForBackoff(_ job: PumpJob,
                                recordNow: inout [CommandTrace]) -> String {
        job.trace.update { $0.outcome = .droppedBackoff }
        recordNow.append(job.trace)
        return "DROP \(job.app ?? "cycle") (yabai unresponsive, backing off)"
    }

    /// Hand the running slot to `job` and discard the queue. Runs inside
    /// `withPumpTransition`.
    private func supersedeRunning(with job: PumpJob,
                                  start: inout (UInt64, PumpJob)?,
                                  recordNow: inout [CommandTrace]) -> String {
        let previousApp = runningApp
        // Genuine target change: cancel the in-flight command's async
        // tail (bump token) and run the new jump immediately. Native
        // activation also supersedes any window job, including cycle.
        currentToken &+= 1
        if let cur = runningTrace {
            cur.update { $0.outcome = .superseded }
            recordNow.append(cur)
        }
        for dropped in pending {
            dropped.trace.update { $0.outcome = .superseded }
            recordNow.append(dropped.trace)
        }
        pending.removeAll()
        inFlightTarget = nil
        runningDomain = job.domain
        runningApp = job.app
        runningTrace = job.trace
        start = (currentToken, job)
        return "SUPERSEDE \(previousApp ?? "cycle")->\(job.app ?? "cycle") tok=\(currentToken)"
    }

    /// Queue `job` behind the running command, evicting the oldest queued
    /// window work at the cap. Runs inside `withPumpTransition`.
    private func enqueue(_ job: PumpJob,
                         recordNow: inout [CommandTrace]) -> String {
        let action: String
        // Cap only queued window work. Repeated native activations are
        // ordered user intent and never participate in the yabai cap.
        let queuedWindows = pending.indices.filter {
            pending[$0].domain == .window
        }
        if job.domain == .window,
           queuedWindows.count >= self.maxPending,
           let evictionIndex = queuedWindows.first {
            let evicted = pending.remove(at: evictionIndex)
            evicted.trace.update { $0.outcome = .droppedCap }
            recordNow.append(evicted.trace)
            action = "QUEUE \(job.app ?? "cycle") (cap: dropped oldest) depth=\(pending.count + 1)"
        } else {
            action = "QUEUE \(job.app ?? "cycle") behind \(runningApp ?? "cycle") depth=\(pending.count + 1)"
        }
        pending.append(job)
        return action
    }

    /// Start `job` on an idle pump. Runs inside `withPumpTransition`.
    private func startFresh(_ job: PumpJob,
                            start: inout (UInt64, PumpJob)?) -> String {
        running = true
        currentToken &+= 1
        runningDomain = job.domain
        runningApp = job.app
        runningTrace = job.trace
        start = (currentToken, job)
        return "START \(job.app ?? "cycle") tok=\(currentToken)"
    }

    /// Run one job outside the state lock. Wraps its completion so the pump is
    /// advanced exactly once, regardless of how many terminal paths call it.
    private func runJob(_ token: UInt64, _ job: PumpJob) {
        jobStartLock.lock()
        defer { jobStartLock.unlock() }
        let canStart = activationQueue.sync {
            token == currentToken && running
        }
        guard canStart else {
            Log.debug("pump: SKIP stale start tok=\(token)")
            return
        }
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

    /// Promote the head of the queue, or park the pump idle when nothing is
    /// queued. Returns the job to run outside the state lock.
    ///
    /// Runs inside `withPumpTransition`. `bumpToken` is for the normal
    /// completion path, which has not fenced the finishing command yet; the
    /// abandon paths bump before recording their own outcome.
    private func advanceToNextOrIdle(bumpToken: Bool) -> (UInt64, PumpJob)? {
        guard !pending.isEmpty else {
            running = false
            runningDomain = nil
            runningApp = nil
            runningTrace = nil
            return nil
        }
        let job = pending.removeFirst()
        if bumpToken { currentToken &+= 1 }
        runningDomain = job.domain
        runningApp = job.app
        runningTrace = job.trace
        return (currentToken, job)
    }

    /// Release a native activation whose AppKit callback never arrived. This
    /// fences late callbacks and advances queued work without touching yabai's
    /// breaker or retry state.
    private func applicationDeadlineFire(_ token: UInt64) {
        var next: (UInt64, PumpJob)?
        var fired = false
        withPumpTransition {
            guard token == currentToken, running,
                  runningDomain == .application else { return }
            currentToken &+= 1
            if let trace = runningTrace {
                trace.update { $0.outcome = .nativeTimeout }
                verifier.recordImmediate(trace)
            }
            next = advanceToNextOrIdle(bumpToken: false)
            fired = true
        }
        if fired {
            Log.error("pump: native activation tok=\(token) exceeded \(applicationDeadline)s")
        }
        if let (nextToken, job) = next { runJob(nextToken, job) }
    }

    /// Force-release the window domain when a command overran the deadline
    /// (yabai hung). Bumps the token so the wedged command's late callbacks
    /// bail, drops queued window work, promotes queued native work, and backs
    /// off so later window presses don't immediately re-hammer a still-hung
    /// yabai.
    private func watchdogFire(
        _ token: UInt64,
        onRetryConsumedForTesting: (() -> Void)? = nil
    ) {
        var next: (UInt64, PumpJob)?
        var fired = false
        var armed = false
        var timedOut: [CommandTrace] = []
        withPumpTransition {
            guard token == currentToken, running,
                  runningDomain == .window else { return }
            currentToken &+= 1
            if let cur = runningTrace {
                cur.update { $0.outcome = .timeout }
                timedOut.append(cur)
            }
            let hasNewerIntent = !pending.isEmpty
            dropQueuedWindowWork(into: &timedOut)
            hungUntil = DispatchTime.now() + self.hungBackoff
            fired = true
            armed = armPendingRetry(for: token, hasNewerIntent: hasNewerIntent)
            next = advanceToNextOrIdle(bumpToken: false)
        }
        for t in timedOut { verifier.recordImmediate(t) }
        if fired {
            Log.error("pump: WATCHDOG tok=\(token) exceeded \(self.commandDeadline)s — yabai unresponsive; released window domain + backing off \(self.hungBackoff)s")
        }
        if let (nextToken, job) = next { runJob(nextToken, job) }
        if armed {
            // Fire just past the backoff window so the resubmission is not
            // dropped by the circuit breaker.
            DispatchQueue.global().asyncAfter(deadline: .now() + hungBackoff + 0.05) { [weak self] in
                self?.consumePendingRetry(
                    onConsumedForTesting: onRetryConsumedForTesting)
            }
        }
    }

    /// Drop the queued window backlog (yabai is presumed hung) and retain
    /// queued native work, which never touches yabai. Runs inside
    /// `withPumpTransition`.
    private func dropQueuedWindowWork(into timedOut: inout [CommandTrace]) {
        var retainedApplications: [PumpJob] = []
        for dropped in pending {
            if dropped.domain == .application {
                retainedApplications.append(dropped)
            } else {
                dropped.trace.update {
                    $0.outcome = .droppedCap
                    $0.detail = "backlog dropped by watchdog"
                }
                timedOut.append(dropped.trace)
            }
        }
        pending = retainedApplications
    }

    /// Arm the one-shot retry when the dropped command's focus target was
    /// already resolved and no newer intent is waiting. Returns whether it
    /// armed. Runs inside `withPumpTransition`.
    private func armPendingRetry(for token: UInt64,
                                 hasNewerIntent: Bool) -> Bool {
        var armed = false
        if !hasNewerIntent, let f = inFlightTarget, f.token == token {
            pendingRetry = f.target
            armed = true
        }
        inFlightTarget = nil
        return armed
    }

    /// Record the in-flight command's resolved focus target, so a watchdog
    /// drop can arm a replay of exactly this focus.
    func armRetryTarget(_ target: RetryTarget, token: UInt64) {
        activationQueue.sync { inFlightTarget = (token, target) }
    }

    /// Hand the armed retry to `retryRunner`, which resubmits it through the
    /// normal pump. One shot — the pending slot is cleared before submission.
    private func consumePendingRetry(
        onConsumedForTesting: (() -> Void)? = nil
    ) {
        // Make consumption and submission one transition: a newer user press
        // either clears the retry first or supersedes it after it has started.
        jobStartLock.lock()
        defer { jobStartLock.unlock() }
        var retry: RetryTarget?
        activationQueue.sync {
            retry = pendingRetry
            pendingRetry = nil
        }
        guard let retry else { return }  // cancelled by a newer user command
        onConsumedForTesting?()
        retryRunner(retry)
    }

    /// Test hook: synchronously fire the watchdog on the in-flight command,
    /// exercising the force-release path deterministically without waiting on
    /// the real GCD timer (which races under parallel test execution).
    func fireWatchdogNowForTesting(
        onRetryConsumed: (() -> Void)? = nil
    ) {
        watchdogFire(
            activationQueue.sync { currentToken },
            onRetryConsumedForTesting: onRetryConsumed)
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
        withPumpTransition {
            guard token == currentToken else { note = "STALE tok=\(token) cur=\(currentToken)"; return }
            if domain == .window { noteWindowRecovery(token) }
            completed = runningTrace
            // Hand the completed trace to the verifier INSIDE this critical
            // section: when the pump goes idle, a keypress on another thread
            // could otherwise START (and enqueue commandStarted on the
            // verifier queue) before this trace's verify() enqueues —
            // reordering that would let a stale verification be attributed
            // mid-next-command. Both verifier calls are non-blocking
            // queue.async wrappers, so no lock-order hazard.
            handOffCompletedTrace(completed)
            next = advanceToNextOrIdle(bumpToken: true)
            if let (nextToken, _) = next {
                note = "DONE tok=\(token) -> next tok=\(nextToken) depth=\(pending.count)"
            } else {
                note = "DONE tok=\(token) idle"
            }
        }
        Log.debug("pump: \(note)")
        if let (token, job) = next { runJob(token, job) }
    }

    /// Only a normal window completion proves yabai recovered. Runs inside
    /// `withPumpTransition`.
    private func noteWindowRecovery(_ token: UInt64) {
        hungUntil = DispatchTime.now()
        if inFlightTarget?.token == token { inFlightTarget = nil }
    }

    /// Route a completed trace: an unknown outcome still needs on-screen
    /// verification, a pre-classified one is recorded as-is. Runs inside
    /// `withPumpTransition`.
    private func handOffCompletedTrace(_ completed: CommandTrace?) {
        if let completed = completed {
            if completed.currentOutcome == .unknown {
                verifier.verify(completed)
            } else {
                verifier.recordImmediate(completed)
            }
        }
    }

    func isActive(_ token: UInt64) -> Bool {
        return activationQueue.sync { currentToken == token }
    }
}
