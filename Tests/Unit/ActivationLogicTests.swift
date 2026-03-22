// Tests/Unit/ActivationLogicTests.swift
import Foundation
import Testing

private func win(_ id: Int, app: String = "Safari", space: Int = 1) -> WindowInfo {
    WindowInfo(id: id, appName: app, space: space,
               isMinimized: false, role: "AXWindow", title: "window \(id)")
}

private struct Harness: @unchecked Sendable {
    let backend: MockWindowBackend
    let launcher: MockAppLauncher
    let store: StateStore
    let processChecker: MockProcessChecker
    let logic: ActivationLogic

    init(aliases: [String: String] = [:],
         strategies: [String: ReopenStrategy] = [:]) {
        let dir = NSTemporaryDirectory() + "appfocus-test-\(UUID().uuidString)"
        let config = AppFocusConfig(
            backend: "yabai", yabaiPath: "/usr/bin/true",
            aliases: aliases, reopenStrategies: strategies,
            pollIntervalMs: 1000)
        backend = MockWindowBackend()
        launcher = MockAppLauncher()
        store = StateStore(stateDir: dir)
        processChecker = MockProcessChecker()
        // All apps default to "running" so existing tests keep working
        processChecker.runningApps = ["Safari", "Visual Studio Code", "Other"]
        logic = ActivationLogic(config: config, backend: backend,
                                 launcher: launcher, store: store,
                                 processChecker: processChecker)
    }

    /// Wait for async GCD callbacks to settle.
    func settle(ms: UInt32 = 300_000) {
        usleep(ms)
    }
}

@Suite("ActivationLogic")
struct ActivationLogicTests {

    // MARK: - Jump: focus existing window

    @Test func jumpFocusesExistingWindow() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(99, app: "Other")

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusedWindowIds.contains(1))
    }

    @Test func jumpPrefersLastFocusedWindow() {
        let h = Harness()
        h.store.recordFocus(appName: "Safari", windowId: 2)
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(99, app: "Other")

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusedWindowIds.last == 2)
    }

    // MARK: - Jump: already focused → cycle

    @Test func jumpAlreadyFocusedCyclesToNext() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(1)

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(!h.backend.focusedWindowIds.isEmpty)
    }

    @Test func jumpAlreadyFocusedMruSwitchesToPrevWindow() {
        // With prevFocusedId set, jump-while-focused does MRU toggle (not ring cycle)
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(2)

        // Simulate: user was on window 1, then switched to window 2
        h.store.recordFocus(appName: "Safari", windowId: 1)
        h.store.recordFocus(appName: "Safari", windowId: 2)
        // Now: lastFocusedId=2, prevFocusedId=1

        h.logic.jump(appName: "Safari")
        h.settle()

        // Should MRU-switch to window 1 (prev), not window 3 (ring next)
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func jumpAlreadyFocusedFallsBackToCycleWhenNoPrev() {
        // Without prevFocusedId, falls back to ring cycling
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(1)

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

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
    }

    // MARK: - Jump: alias resolution

    @Test func jumpResolvesAlias() {
        let h = Harness(aliases: ["Code": "Visual Studio Code"])
        h.backend.windows = [win(1, app: "Visual Studio Code")]
        h.backend.focusedWin = win(99, app: "Other")

        h.logic.jump(appName: "Visual Studio Code")
        h.settle()

        #expect(h.backend.focusedWindowIds.contains(1))
    }

    // MARK: - Jump: alias filtering at ActivationLogic level

    @Test func jumpResolvesAliasFromAllWindows() {
        // Backend returns all windows including aliased app name "Code"
        // ActivationLogic must resolve "Code" → "Visual Studio Code" via config alias
        let h = Harness(aliases: ["Code": "Visual Studio Code"])
        h.backend.windows = [win(1, app: "Code"), win(2, app: "Code")]
        h.backend.focusedWin = win(99, app: "Other")

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

        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2]
        }

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func cyclePrevWrapsAround() {
        let h = Harness()
        h.backend.windows = [win(1), win(2)]
        h.backend.focusedWin = win(1)

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
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        h.backend.focusedWin = win(2)
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 3)

        h.backend.focusedWin = win(3)
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func cyclePrevFullLoop() {
        // 3 → 2 → 1 → 3
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]

        h.backend.focusedWin = win(3)
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        h.backend.focusedWin = win(2)
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)

        h.backend.focusedWin = win(1)
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 3)
    }

    @Test func cycleSkipsGhostWindows() {
        let h = Harness()
        let ghost = WindowInfo(id: 99, appName: "Safari", space: 1,
                               isMinimized: false, role: "AXHelpTag", title: "")
        h.backend.windows = [win(1), win(2), ghost, win(3)]
        h.backend.focusedWin = win(1)

        // Should cycle 1 → 2 → 3 → 1, skipping AXHelpTag ghost window 99
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        h.backend.focusedWin = win(2)
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 3)

        h.backend.focusedWin = win(3)
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)
    }

    @Test func cycleSingleWindowNoOp() {
        let h = Harness()
        h.backend.windows = [win(1)]
        h.backend.focusedWin = win(1)

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.backend.focusedWindowIds.isEmpty)
    }

    // MARK: - Jump: process checker branches

    @Test func jumpNotRunningLaunchesApp() {
        let h = Harness()
        h.processChecker.runningApps = []  // nothing running
        h.backend.windows = []
        h.backend.focusedWin = nil

        h.logic.jump(appName: "Safari")
        h.settle()

        #expect(h.launcher.launchedApps == ["Safari"])
    }

    @Test func jumpRunningNoWindowsReopens() {
        let h = Harness()
        h.processChecker.runningApps = ["Safari"]
        h.backend.windows = []
        h.backend.focusedWin = nil

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
        h.logic.jump(appName: "Safari")
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)

        // Simulate the focus change that the backend would apply
        h.store.recordFocus(appName: "Safari", windowId: 1)

        // Second jump while on window 1 → should go back to window 2
        h.backend.focusedWin = win(1)
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

        // Cycle next: 1 → 2
        h.logic.cycle(direction: .next)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 2)

        // Cycle prev: 2 → 1
        h.backend.focusedWin = win(2)
        h.logic.cycle(direction: .prev)
        h.settle()
        #expect(h.backend.focusedWindowIds.last == 1)

        // Now MRU jump while on window 1 — should go to 2 (prev from cycling)
        h.backend.focusedWin = win(1)
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

        h.logic.jump(appName: "Code")
        h.settle()

        #expect(h.launcher.launchedApps == ["Visual Studio Code"])
    }

    // MARK: - Cycle updates lastFocusedId

    @Test func cycleNextUpdatesLastFocusedId() {
        let h = Harness()
        h.backend.windows = [win(1), win(2), win(3)]
        h.backend.focusedWin = win(1)

        h.store.update(appName: "Safari") { state in
            state.ring = [1, 2, 3]
        }

        h.logic.cycle(direction: .next)
        h.settle()

        #expect(h.store.state(for: "Safari").lastFocusedId == 2)
    }
}
