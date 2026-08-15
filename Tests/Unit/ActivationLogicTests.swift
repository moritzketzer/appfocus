// Tests/Unit/ActivationLogicTests.swift
import Foundation
import Testing

private func win(_ id: Int, app: String = "Safari", space: Int = 1,
                 subrole: String = "AXStandardWindow",
                 sticky: Bool = false, floating: Bool = false,
                 hasFocus: Bool = false, role: String = "AXWindow",
                 ax: Bool = true) -> WindowInfo {
    WindowInfo(id: id, appName: app, space: space,
               isMinimized: false, role: role, title: "window \(id)",
               hasAXReference: ax, subrole: subrole,
               isSticky: sticky, isFloating: floating, hasFocus: hasFocus)
}

/// Deterministic xorshift RNG so the property test is reproducible (a failing
/// seed always reproduces) rather than flaky.
private struct FuzzRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xdead_beef_cafe_babe : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private struct Harness: @unchecked Sendable {
    let backend: MockWindowBackend
    let launcher: MockAppLauncher
    let store: StateStore
    let model: WindowModelStore
    let processChecker: MockProcessChecker
    let logic: ActivationLogic

    init(aliases: [String: String] = [:],
         strategies: [String: ReopenStrategy] = [:]) {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let config = AppFocusConfig(
            backend: "yabai", yabaiPath: "/usr/bin/true",
            aliases: aliases, reopenStrategies: strategies,
            pollIntervalMs: 2000)
        backend = MockWindowBackend()
        launcher = MockAppLauncher()
        store = StateStore(stateDir: dir)
        model = WindowModelStore()
        processChecker = MockProcessChecker()
        // All apps default to "running" so existing tests keep working
        processChecker.runningApps = ["Safari", "Visual Studio Code", "Other"]
        logic = ActivationLogic(config: config, backend: backend,
                                 launcher: launcher, store: store,
                                 processChecker: processChecker,
                                 model: model)
        // Disable the hung-yabai watchdog by default: tests that defer mock
        // completions hold a command "running" for the test's duration, which
        // under parallel execution can exceed the production deadline and let
        // the watchdog force-release mid-test. Watchdog tests opt back in.
        logic.commandDeadline = 3600
    }

    /// Simulate one background poll tick: the model absorbs the backend's
    /// current windows, with focusedWin marked as the focused one.
    func sync() {
        var wins = backend.windows
        if let f = backend.focusedWin {
            wins.removeAll { $0.id == f.id }
            wins.append(WindowInfo(id: f.id, appName: f.appName, space: f.space,
                                   isMinimized: f.isMinimized, role: f.role,
                                   title: f.title,
                                   hasAXReference: f.hasAXReference,
                                   subrole: f.subrole, isSticky: f.isSticky,
                                   isFloating: f.isFloating, hasFocus: true))
        }
        model.replaceSnapshot(wins)
    }

    /// Wait for async GCD callbacks to settle.
    func settle(ms: UInt32 = 300_000) {
        usleep(ms)
    }
}

@Suite("ActivationLogic")
struct ActivationLogicTests {

    // MARK: - Query-free hot path

    @Test func jumpWithWindowsInModelIssuesNoQueries() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount == 0)
        #expect(h.backend.focusedWindowIds.contains(1))
    }

    @Test func jumpWithEmptyModelConfirmsOnceBeforeReopening() {
        // Model knows nothing, but yabai actually has windows: the confirm
        // query must find them and focus — never reopen a duplicate.
        let h = Harness()
        h.backend.windows = [win(1)]
        h.backend.focusedWin = nil
        // model NOT synced — stays empty

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount == 1)
        #expect(h.launcher.reopenedApps.isEmpty)
        #expect(h.backend.focusedWindowIds.contains(1))
    }

    @Test func jumpConfirmedNoWindowsReopens() {
        let h = Harness()
        h.processChecker.runningApps = ["Safari"]
        h.backend.windows = []
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount >= 1)
        #expect(h.launcher.reopenedApps.count == 1)
    }

    @Test func staleModelTargetGoneFromBackendFailsCleanly() {
        // The model still believes window 5 exists after it closed. The
        // command must complete cleanly and leave the pump idle; the next
        // poll heals the model.
        let h = Harness()
        h.backend.windows = [win(5)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()
        h.backend.windows = []  // window vanished after the last poll

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.logic.isIdleForTesting)
    }

    @Test func confirmQueryFailureNeverReopens() {
        // A FAILED confirm query (yabai error/timeout → nil) must not be
        // read as "no windows": reopening on it would create a duplicate
        // window. The press is dropped; the pump stays healthy.
        let h = Harness()
        h.processChecker.runningApps = ["Safari"]
        h.backend.windows = [win(1)]
        h.backend.queryAllWindowsFails = true
        // model empty → confirm path → failure

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.launcher.reopenedApps.isEmpty)
        #expect(h.launcher.launchedApps.isEmpty)
        #expect(h.backend.focusedWindowIds.isEmpty)
        #expect(h.logic.isIdleForTesting)
    }

    @Test func cycleIssuesNoQueries() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(1)
        h.sync()
        h.store.update(appName: "Safari") { $0.ring = [1, 2] }

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.queryAllWindowsCallCount == 0)
        #expect(h.backend.focusedWindowIds.last == 2)
    }

    @Test func cycleWithNoFocusInModelLogsAndCompletes() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.sync()  // nothing focused

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
        #expect(h.logic.isIdleForTesting)
    }

    // MARK: - Jump: focus existing window

    @Test func jumpFocusesExistingWindow() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusedWindowIds.contains(1))
    }

    @Test func jumpPrefersLastFocusedWindow() {
        let h = Harness()
        h.store.recordFocus(appName: "Safari", windowId: 2)
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusedWindowIds.last == 2)
    }

    @Test func jumpAcrossSpacesFocusesSpaceBeforeWindow() {
        let h = Harness()
        h.backend.windows = [win(1, space: 2)]
        h.backend.focusedWin = win(99, app: "Other", space: 1)
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusCalls == ["space:2", "window:1"])
    }

    @Test func jumpOnSameSpaceFocusesOnlyWindow() {
        let h = Harness()
        h.backend.windows = [win(1, space: 1)]
        h.backend.focusedWin = win(99, app: "Other", space: 1)
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusCalls == ["window:1"])
    }

    @Test func launchedWindowAcrossSpacesFocusesSpaceBeforeWindow() {
        let h = Harness()
        h.processChecker.runningApps = []
        h.backend.windows = []
        h.backend.focusedWin = win(99, app: "Other", space: 1)
        h.sync()

        h.logic.jump(appName: "Safari")
        h.backend.windows = [win(1, space: 2)]
        // Poll for the launch/pollForWindow chain instead of a fixed sleep, so
        // the real 0.2s poll timer isn't raced by parallel-test CPU load.
        for _ in 0..<100 where h.backend.focusCalls.count < 2 { usleep(50_000) }

        #expect(h.backend.focusCalls == ["space:2", "window:1"])
    }

    // MARK: - Jump: already focused → cycle

    @Test func jumpAlreadyFocusedCyclesToNext() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(1)
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(!h.backend.focusedWindowIds.isEmpty)
    }

    @Test func jumpAlreadyFocusedMruSwitchesToPrevWindow() {
        // With prevFocusedId set, jump-while-focused does MRU toggle (not ring cycle)
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(2)
        h.sync()

        // Simulate: user was on window 1, then switched to window 2
        h.store.recordFocus(appName: "Safari", windowId: 1)
        h.store.recordFocus(appName: "Safari", windowId: 2)
        // Now: lastFocusedId=2, prevFocusedId=1

        h.logic.jump(appName: "Safari")
        h.settle()

        // Should MRU-switch to window 1 (prev), not window 3 (ring next)
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func jumpMruAcrossSpacesFocusesSpaceBeforeWindow() {
        let h = Harness()
        h.backend.windows = [win(1, space: 1), win(2, space: 2)]
        h.backend.focusedWin = win(1, space: 1)
        h.sync()

        h.store.recordFocus(appName: "Safari", windowId: 2)
        h.store.recordFocus(appName: "Safari", windowId: 1)

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusCalls == ["space:2", "window:2"])
    }

    @Test func jumpAlreadyFocusedFallsBackToCycleWhenNoPrev() {
        // Without prevFocusedId, falls back to ring cycling
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(1)
        h.sync()

        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2, 3]
        }

        h.logic.jump(appName: "Safari")
        h.settle()

        // No prevFocusedId → fallback to ring cycle .next: 1 → 2
        #expect(h.backend.focusedWindowIds.last == 2)
    }

    @Test func jumpAlreadyFocusedSingleWindowNoOp() {
        let h = Harness()
        h.backend.windows = [win(1)]
        h.backend.focusedWin = win(1)
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
    }

    // MARK: - Jump: alias resolution

    @Test func jumpResolvesAlias() {
        let h = Harness(aliases: ["Code": "Visual Studio Code"])
        h.backend.windows = [win(1, app: "Visual Studio Code")]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()

        h.logic.jump(appName: "Visual Studio Code")
        h.settle()

        #expect(h.backend.focusedWindowIds.contains(1))
    }

    // MARK: - Jump: alias filtering at ActivationLogic level

    @Test func jumpResolvesAliasFromAllWindows() {
        // The model holds windows under the aliased app name "Code";
        // ActivationLogic must resolve "Code" → "Visual Studio Code".
        let h = Harness(aliases: ["Code": "Visual Studio Code"])
        h.backend.windows = [win(1, app: "Code"), win(2, app: "Code")]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()

        h.logic.jump(appName: "Visual Studio Code")
        h.settle()

        // Should focus the best window from the aliased "Code" windows
        #expect(h.backend.focusedWindowIds.contains(1) || h.backend.focusedWindowIds.contains(2))
    }

    // MARK: - Cycle

    @Test func cycleNextWrapsAround() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(2)
        h.sync()

        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2]
        }

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func cycleAcrossSpacesFocusesSpaceBeforeWindow() {
        let h = Harness()
        h.backend.windows = [win(1, space: 1), win(2, space: 2)]
        h.backend.focusedWin = win(1, space: 1)
        h.sync()
        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2]
        }

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.focusCalls == ["space:2", "window:2"])
    }

    @Test func rapidRepeatedCycleCommandsAreHandledInOrder() {
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(1)
        h.sync()
        h.backend.focusWindowCompletesImmediately = false
        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2, 3]
        }

        let presses = 12
        for _ in 0..<presses {
            h.logic.cycle(direction: .next)
        }

        for _ in 0..<presses {
            #expect(h.backend.completeNextFocusWindow())
            h.settle(ms: 20_000)
        }
        h.settle()

        // 12 presses from window 1 over ring [1,2,3]: every press must land,
        // in order, ending where a full 4x loop ends. What compounds each
        // press is the optimistic model update on the previous completion.
        #expect(h.backend.focusedWindowIds.count == presses)
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func rapidRepeatedJumpCommandsAreHandledInOrder() {
        let h = Harness()
        h.backend.windows = [win(1, app: "cmux"), win(2, app: "cmux")]
        h.backend.focusedWin = win(1, app: "cmux")
        h.sync()
        h.backend.focusWindowCompletesImmediately = false
        h.processChecker.runningApps.insert("cmux")
        h.store.update(appName: "cmux") { state in
            state.ring = [1, 2]
        }

        let presses = 8
        for _ in 0..<presses {
            h.logic.jump(appName: "cmux")
        }

        for _ in 0..<presses {
            #expect(h.backend.completeNextFocusWindow())
            h.settle(ms: 20_000)
        }
        h.settle()

        #expect(h.backend.focusedWindowIds.count == presses)
        #expect(h.backend.focusedWindowIds.last == 1)
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    // MARK: - Resilience to a hung/slow yabai

    @Test func watchdogReleasesPumpWhenAYabaiCallHangs() {
        // A command whose yabai call never returns must not wedge the serial
        // pump forever. The watchdog force-releases it so a later command runs.
        let h = Harness()
        h.logic.hungBackoff = 0.0        // no backoff, so the retry is never dropped
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(1)
        h.sync()
        h.backend.focusWindowCompletesImmediately = false  // focus action hangs

        h.logic.jump(appName: "Safari")   // wedges on the focus action
        h.settle(ms: 50_000)

        // Fire the watchdog as the real timer would once the deadline passes.
        h.logic.fireWatchdogNowForTesting()

        // yabai "recovers": a fresh jump must run, proving the pump was released
        // and not left wedged behind the hung command.
        h.backend.focusWindowCompletesImmediately = true
        h.logic.jump(appName: "Safari")
        h.settle()
        #expect(!h.backend.focusedWindowIds.isEmpty)
    }

    @Test func queueCapBoundsBacklogUnderHammering() {
        // Hammering the same app while the running command is stuck must not
        // build an unbounded backlog: only (1 running + maxPending) commands
        // ever reach the backend; the rest are dropped by the cap.
        let h = Harness()
        h.logic.maxPending = 3
        h.backend.windows = [win(1, app: "cmux"), win(2, app: "cmux")]
        h.backend.focusedWin = win(1, app: "cmux")
        h.sync()
        h.backend.focusWindowCompletesImmediately = false
        h.processChecker.runningApps.insert("cmux")

        for _ in 0..<10 { h.logic.jump(appName: "cmux") }

        var drained = 0
        while h.backend.completeNextFocusWindow() {
            h.settle(ms: 20_000); drained += 1
            if drained > 20 { break }
        }
        h.settle()
        #expect(h.backend.focusedWindowIds.count == 1 + h.logic.maxPending)
    }

    @Test func pumpStaysConsistentUnderRandomCommandSequences() {
        // Property test: for many random command sequences (jump across apps,
        // next, prev) with the focus action deferred to force queuing/
        // superseding/interleaving, once every deferred completion drains and
        // the watchdog fires, the pump must (a) return to idle — never
        // permanently wedged — and (b) never have focused a window that
        // doesn't exist.
        var rng = FuzzRNG(seed: 0xA11CE_5EED)
        let apps = ["cmux", "Safari", "ChatGPT"]
        for _ in 0..<150 {
            let h = Harness()
            h.logic.hungBackoff = 0.0
            var wins: [WindowInfo] = []
            for (i, app) in apps.enumerated() {
                wins.append(win(i * 10 + 1, app: app, space: i + 1))
                wins.append(win(i * 10 + 2, app: app, space: i + 1))
            }
            h.backend.windows = wins
            h.backend.focusedWin = wins.first
            h.sync()
            h.backend.focusWindowCompletesImmediately = false
            for app in apps { h.processChecker.runningApps.insert(app) }

            let commands = Int.random(in: 1...12, using: &rng)
            for _ in 0..<commands {
                switch Int.random(in: 0...3, using: &rng) {
                case 0, 1: h.logic.jump(appName: apps[Int.random(in: 0..<apps.count, using: &rng)])
                case 2: h.logic.cycle(direction: .next)
                default: h.logic.cycle(direction: .prev)
                }
                // Sometimes resolve an in-flight focus action mid-sequence.
                if Bool.random(using: &rng) { _ = h.backend.completeNextFocusWindow() }
            }

            // Drain everything, fire the watchdog for any straggler, then
            // drain until the pump settles (a one-shot retry may still submit
            // after the backoff) — condition-polled, not a fixed worst-case
            // sleep, so the 150 iterations stay fast.
            var guardN = 0
            while h.backend.completeNextFocusWindow() { guardN += 1; if guardN > 500 { break } }
            h.logic.fireWatchdogNowForTesting()
            var waited = 0
            while !h.logic.isIdleForTesting && waited < 60 {
                _ = h.backend.completeNextFocusWindow()
                usleep(10_000); waited += 1
            }

            #expect(h.logic.isIdleForTesting, "pump must return to idle, never wedge")
            let validIds = Set(wins.map { $0.id })
            #expect(h.backend.focusedWindowIds.allSatisfy { validIds.contains($0) },
                    "every focused window must be a real window")
        }
    }

    // MARK: - One-shot retry after a watchdog drop

    @Test func watchdogDroppedFocusRetriesOnceAfterBackoff() {
        let h = Harness()
        h.logic.hungBackoff = 0.0
        h.backend.windows = [win(1, space: 2)]
        h.backend.focusedWin = win(99, app: "Other", space: 1)
        h.sync()
        h.backend.focusWindowCompletesImmediately = false

        h.logic.jump(appName: "Safari")   // resolves target 1, focus hangs
        h.settle(ms: 100_000)
        h.logic.fireWatchdogNowForTesting()
        // GCD timers drift by seconds under parallel-suite load: poll for
        // the retry instead of sleeping a fixed interval.
        for _ in 0..<200 where h.backend.focusedWindowIds.count < 2 { usleep(20_000) }

        // The retry replays the focus action for the SAME window once.
        #expect(h.backend.focusedWindowIds == [1, 1])

        while h.backend.completeNextFocusWindow() {}
        for _ in 0..<100 where !h.logic.isIdleForTesting { usleep(10_000) }
        #expect(h.logic.isIdleForTesting)
    }

    @Test func userCommandCancelsPendingRetry() {
        let h = Harness()
        h.logic.hungBackoff = 0.2
        h.backend.windows = [win(1)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()
        h.backend.focusWindowCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.settle(ms: 100_000)
        h.logic.fireWatchdogNowForTesting()
        // Press during the backoff window: the circuit breaker drops the
        // press, but it still expresses newer intent — the pending retry is
        // cancelled and must never replay. Wait generously past the retry's
        // schedule (GCD timers drift under parallel-suite load) to prove
        // the absence.
        h.logic.jump(appName: "Safari")
        h.settle(ms: 2_500_000)

        #expect(h.backend.focusedWindowIds == [1])   // no replay
        while h.backend.completeNextFocusWindow() {}
        for _ in 0..<100 where !h.logic.isIdleForTesting { usleep(10_000) }
        #expect(h.logic.isIdleForTesting)
    }

    @Test func noRetryWhenDroppedBeforeTargetResolved() {
        // Stuck in the confirm query — no focus target was resolved yet, so
        // nothing must replay (launch/reopen paths never auto-retry).
        let h = Harness()
        h.logic.hungBackoff = 0.0
        h.backend.windows = []
        h.backend.focusedWin = nil
        // model empty → confirm path; hold the confirm query in flight so the
        // watchdog drops the command before any focus target exists.
        h.backend.queryAllWindowsCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.settle(ms: 100_000)
        h.logic.fireWatchdogNowForTesting()
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
        #expect(h.logic.isIdleForTesting)
    }

    @Test func retryTargetGoneFromModelIsDropped() {
        let h = Harness()
        h.logic.hungBackoff = 0.0
        h.backend.windows = [win(1)]
        h.backend.focusedWin = win(99, app: "Other")
        h.sync()
        h.backend.focusWindowCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.settle(ms: 100_000)
        h.model.replaceSnapshot([])       // window vanished before the retry
        h.logic.fireWatchdogNowForTesting()
        // Wait past the (drift-prone) retry schedule, then confirm the retry
        // validated against the model, found the window gone, and dropped.
        h.settle(ms: 2_000_000)

        #expect(h.backend.focusedWindowIds == [1])  // no replay
        for _ in 0..<100 where !h.logic.isIdleForTesting { usleep(10_000) }
        #expect(h.logic.isIdleForTesting)
    }

    @Test func newerJumpCancelsWindowFocusAfterOlderSpaceTransition() {
        let h = Harness()
        h.backend.windows = [win(1, app: "Safari", space: 2),
                             win(2, app: "Code", space: 3)]
        h.backend.focusedWin = win(99, app: "Other", space: 1)
        h.sync()
        h.backend.focusSpaceCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.logic.jump(appName: "Code")
        h.settle()

        #expect(h.backend.focusCalls == ["space:2", "space:3"])
        guard h.backend.pendingFocusSpaceCompletions.count == 2 else { return }

        h.backend.completeNextFocusSpace()
        h.settle()
        #expect(h.backend.focusedWindowIds.isEmpty)

        h.backend.completeNextFocusSpace()
        h.settle()
        #expect(h.backend.focusedWindowIds == [2])
    }

    @Test func cyclePrevWrapsAround() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(1)
        h.sync()

        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2]
        }

        h.logic.cycle(direction: .prev)
        h.settle()

        #expect(h.backend.focusedWindowIds.last == 2)
    }

    @Test func cycleNextFullLoop() {
        // 1 → 2 → 3 → 1
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]

        h.backend.focusedWin = win(1)
        h.sync()
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        h.backend.focusedWin = win(2)
        h.sync()
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 3)

        h.backend.focusedWin = win(3)
        h.sync()
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func cyclePrevFullLoop() {
        // 3 → 2 → 1 → 3
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]

        h.backend.focusedWin = win(3)
        h.sync()
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        h.backend.focusedWin = win(2)
        h.sync()
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)

        h.backend.focusedWin = win(1)
        h.sync()
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 3)
    }

    @Test func cycleSkipsGhostWindows() {
        let h = Harness()
        // A tooltip/ghost carries a non-standard role, so it is excluded by
        // the isStandardWindow eligibility predicate.
        let ghost = WindowInfo(id: 99, appName: "Safari", space: 1,
                               isMinimized: false, role: "AXHelpTag", title: "",
                               hasAXReference: true, subrole: "AXUnknown")
        h.backend.windows = [win(1), win(2), ghost, win(3)]

        // Should cycle 1 → 2 → 3 → 1, skipping AXHelpTag ghost window 99
        h.backend.focusedWin = win(1)
        h.sync()
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        h.backend.focusedWin = win(2)
        h.sync()
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 3)

        h.backend.focusedWin = win(3)
        h.sync()
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func cycleSingleWindowNoOp() {
        let h = Harness()
        h.backend.windows = [win(1)]
        h.backend.focusedWin = win(1)
        h.sync()

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
    }

    // MARK: - focusSpace failure resilience

    @Test func focusSpaceFailureStillFocusesWindow() {
        // yabai errors on focusing an already-focused Space. A stale model
        // can make the daemon issue exactly that spurious focusSpace; the
        // jump must proceed to the window focus instead of aborting, or the
        // press does nothing at all (observed live: "focus failed for space
        // 1/3" with the target window never focused).
        let h = Harness()
        h.backend.windows = [win(1, space: 2)]
        h.backend.focusedWin = win(99, app: "Other", space: 1)
        h.sync()
        h.backend.focusSpaceCompletesImmediately = false

        h.logic.jump(appName: "Safari")
        h.settle(ms: 100_000)
        h.backend.completeNextFocusSpace(success: false)   // "already focused"
        h.settle()

        #expect(h.backend.focusCalls == ["space:2", "window:1"])
        #expect(h.backend.focusedWindowIds == [1])
        #expect(h.logic.isIdleForTesting)
    }

    // MARK: - AX-less window fallback (ChatGPT Chromium lazy-AX state)

    @Test func jumpFallsBackToNativeActivationForAXlessWindows() {
        let h = Harness()
        h.processChecker.runningApps = ["ChatGPT"]
        h.backend.windows = [win(40, app: "ChatGPT", space: 4,
                                 subrole: "", role: "", ax: false)]
        // model not synced — confirm branch runs and sees the AX-less window

        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(h.backend.focusCalls == ["space:4"])
        #expect(h.launcher.activatedApps == ["ChatGPT"])
        #expect(h.launcher.reopenedApps.isEmpty)
        #expect(h.backend.focusedWindowIds.isEmpty)
        #expect(h.store.stateIfCached(for: "ChatGPT")?.lastFocusedId == nil)
        #expect(h.logic.isIdleForTesting)
    }

    @Test func stickyOverlayOnlyStillReopens() {
        let h = Harness()
        h.processChecker.runningApps = ["ChatGPT"]
        h.backend.windows = [win(41, app: "ChatGPT", subrole: "AXDialog",
                                 sticky: true, floating: true)]

        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(h.launcher.activatedApps.isEmpty)
        #expect(h.launcher.reopenedApps.count == 1)
    }

    @Test func stickyAXlessOverlayIsNotAFallbackCandidate() {
        // A sticky overlay that ALSO lost its AX reference must still route
        // to reopen: sticky windows are never valid jump destinations, with
        // or without an AX ref.
        let h = Harness()
        h.processChecker.runningApps = ["ChatGPT"]
        h.backend.windows = [win(42, app: "ChatGPT", subrole: "",
                                 sticky: true, floating: true,
                                 role: "", ax: false)]

        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(h.launcher.activatedApps.isEmpty)
        #expect(h.backend.focusedSpaces.isEmpty)
        #expect(h.launcher.reopenedApps.count == 1)
    }

    // MARK: - Jump: process checker branches

    @Test func jumpNotRunningLaunchesApp() {
        let h = Harness()
        h.processChecker.runningApps = []  // nothing running
        h.backend.windows = []
        h.backend.focusedWin = nil
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.launcher.launchedApps == ["Safari"])
    }

    @Test func jumpRunningNoWindowsReopens() {
        let h = Harness()
        h.processChecker.runningApps = ["Safari"]
        h.backend.windows = []
        h.backend.focusedWin = nil
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.launcher.reopenedApps.count == 1)
        #expect(h.launcher.reopenedApps.first?.0 == "Safari")
    }

    @Test func jumpRunningNoWindowsUsesConfiguredStrategy() {
        let h = Harness(strategies: ["Safari": .makeWindow])
        h.processChecker.runningApps = ["Safari"]
        h.backend.windows = []
        h.backend.focusedWin = nil
        h.sync()

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.launcher.reopenedApps.first?.1 == .makeWindow)
    }

    // MARK: - MRU toggle stability

    @Test func jumpMruToggleIsIdempotent() {
        // Double-tap: jump toggles A→B, then B→A
        let h = Harness()
        h.backend.windows = [win(1), win(2)]

        // Simulate focus history: window 1 then window 2
        h.store.recordFocus(appName: "Safari", windowId: 1)
        h.store.recordFocus(appName: "Safari", windowId: 2)

        // First jump while on window 2 → should go to window 1
        h.backend.focusedWin = win(2)
        h.sync()
        h.logic.jump(appName: "Safari")
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)

        // Simulate the focus change that the backend would apply
        h.store.recordFocus(appName: "Safari", windowId: 1)

        // Second jump while on window 1 → should go back to window 2
        h.backend.focusedWin = win(1)
        h.sync()
        h.logic.jump(appName: "Safari")
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)
    }

    @Test func jumpMruAfterCycleBackAndForth() {
        // Cycle A→B→A, then jump should MRU to B (not get stuck on A)
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]

        // Start on window 1
        h.store.recordFocus(appName: "Safari", windowId: 1)
        h.backend.focusedWin = win(1)
        h.sync()

        // Cycle next: 1 → 2
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        // Cycle prev: 2 → 1
        h.backend.focusedWin = win(2)
        h.sync()
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)

        // Now MRU jump while on window 1 — should go to 2 (prev from cycling)
        h.backend.focusedWin = win(1)
        h.sync()
        h.logic.jump(appName: "Safari")
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)
    }

    // MARK: - Alias-aware jump with process checker

    @Test func jumpAliasNotRunningLaunchesCanonicalName() {
        let h = Harness(aliases: ["Code": "Visual Studio Code"])
        h.processChecker.runningApps = []
        h.backend.windows = []
        h.backend.focusedWin = nil
        h.sync()

        h.logic.jump(appName: "Code")
        h.settle()

        #expect(h.launcher.launchedApps == ["Visual Studio Code"])
    }

    // MARK: - Cycle updates lastFocusedId

    @Test func cycleNextUpdatesLastFocusedId() {
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(1)
        h.sync()

        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2, 3]
        }

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.store.state(for: "Safari").lastFocusedId == 2)
    }

    // MARK: - Sticky/floating dialog exclusion (Codex/ChatGPT regression)

    @Test func jumpNeverMruSwitchesToTrackedDialog() {
        // Reproduces prod: prevFocusedId points at a sticky Codex dialog (793).
        // A dialog must never be an MRU/jump target; jump falls through to a
        // real window instead.
        let h = Harness()
        let real1 = win(786, app: "ChatGPT")
        let real2 = win(787, app: "ChatGPT")
        let dialog = win(793, app: "ChatGPT", subrole: "AXDialog",
                         sticky: true, floating: true)
        h.backend.windows = [real1, real2, dialog]

        // Pollute MRU so prevFocusedId == 793 (the dialog), lastFocusedId == 786.
        h.store.recordFocus(appName: "ChatGPT", windowId: 793)
        h.store.recordFocus(appName: "ChatGPT", windowId: 786)

        h.backend.focusedWin = real1  // focused on the real window 786
        h.sync()
        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(!h.backend.focusedWindowIds.contains(793))
        #expect(h.backend.focusedWindowIds.last == 787)
    }

    @Test func cycleNeverFocusesTrackedDialog() {
        // Cycling must skip the dialog entirely: wrapping .next from the
        // highest-id real window lands on the lowest-id REAL window, never the
        // even-lower-id dialog.
        let h = Harness()
        let dialog = win(785, app: "ChatGPT", subrole: "AXDialog",
                         sticky: true, floating: true)
        let real1 = win(786, app: "ChatGPT")
        let real2 = win(787, app: "ChatGPT")
        h.backend.windows = [dialog, real1, real2]
        h.backend.focusedWin = real2  // on 787
        h.sync()

        h.logic.cycle(direction: .next)  // wraps toward the lowest id
        h.settle()

        #expect(!h.backend.focusedWindowIds.contains(785))
        #expect(h.backend.focusedWindowIds.last == 786)
    }

    @Test func jumpFromFocusedDialogReachesStandardWindow() {
        // A sticky Codex dialog is the focused window and the app has one real
        // window. Jump must land on the real window, not no-op on the dialog.
        let h = Harness()
        let real = win(786, app: "ChatGPT")
        let dialog = win(793, app: "ChatGPT", subrole: "AXDialog",
                         sticky: true, floating: true)
        h.backend.windows = [real, dialog]
        h.backend.focusedWin = dialog  // focused ON the sticky dialog
        h.sync()

        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(h.backend.focusedWindowIds.contains(786))
    }

    @Test func jumpFromFocusedDialogDoesNotTrustItsReportedSpace() {
        // Sticky dialogs are visible on every Space but report their home
        // Space. Matching that stale value must not suppress an explicit
        // Space transition to the standard target window.
        let h = Harness()
        let real = win(786, app: "ChatGPT", space: 7)
        let dialog = win(793, app: "ChatGPT", space: 7, subrole: "AXDialog",
                         sticky: true, floating: true)
        h.backend.windows = [real, dialog]
        h.backend.focusedWin = dialog
        h.sync()

        h.logic.jump(appName: "ChatGPT")
        h.settle()

        #expect(h.backend.focusCalls == ["space:7", "window:786"])
    }
}
