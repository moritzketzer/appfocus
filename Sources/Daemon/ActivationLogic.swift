// Sources/Daemon/ActivationLogic.swift
import AppKit
import Foundation

final class ActivationLogic {
    private let config: AppFocusConfig
    private let backend: WindowBackend
    private let launcher: AppLauncher
    private let store: StateStore
    private let processChecker: ProcessChecker

    /// Serial queue for activation. Newer commands increment `currentToken`;
    /// stale closures check `isActive()` and bail if their token is outdated.
    private let activationQueue = DispatchQueue(label: "appfocus.activation")
    private var currentToken: UInt64 = 0

    init(config: AppFocusConfig, backend: WindowBackend,
         launcher: AppLauncher, store: StateStore,
         processChecker: ProcessChecker) {
        self.config = config
        self.backend = backend
        self.launcher = launcher
        self.store = store
        self.processChecker = processChecker
    }

    // MARK: - Alias filtering

    private func windowsForApp(_ appName: String, from allWindows: [WindowInfo]) -> [WindowInfo] {
        allWindows.filter { config.resolveAlias($0.appName) == appName
                            && !$0.isMinimized && $0.isStandardWindow }
    }

    // MARK: - Jump

    func jump(appName rawName: String) {
        let appName = config.resolveAlias(rawName)
        let token = nextToken()
        Log.info("jump: \(appName)")

        // Step 1: Get fresh focus state before proceeding
        backend.focusedWindow { [self] focused in
            guard self.isActive(token) else { return }

            // Record the pre-jump focused window only if it is a real window;
            // a focused sticky dialog must not pollute MRU state.
            if let focused = focused, focused.isStandardWindow {
                let canonical = self.config.resolveAlias(focused.appName)
                self.store.recordFocus(appName: canonical, windowId: focused.id, space: focused.space)
            }

            // Step 2: Query windows for the target app
            self.backend.queryAllWindows { allWindows in
                let windows = self.windowsForApp(appName, from: allWindows)
                guard self.isActive(token) else { return }

                if windows.isEmpty {
                    self.handleNoWindows(appName: appName, focused: focused,
                                         token: token)
                } else {
                    self.handleHasWindows(appName: appName, windows: windows,
                                          focused: focused, token: token)
                }
            }
        }
    }

    private func handleNoWindows(appName: String, focused: WindowInfo?,
                                 token: UInt64) {
        // Check if app is running (has process but no windows)
        let isRunning = processChecker.isAppRunning(name: appName)

        if isRunning {
            Log.info("jump: \(appName) running but no windows, reopening")
            let strategy = config.reopenStrategy(for: appName)
            launcher.reopen(appName: appName, strategy: strategy) { [self] in
                guard self.isActive(token) else { return }
                self.pollForWindow(appName: appName, focused: focused,
                                   token: token)
            }
        } else {
            Log.info("jump: \(appName) not running, launching")
            launcher.launch(appName: appName) { [self] success in
                guard self.isActive(token), success else { return }
                self.pollForWindow(appName: appName, focused: focused,
                                   token: token)
            }
        }
    }

    private func handleHasWindows(appName: String, windows: [WindowInfo],
                                    focused: WindowInfo?, token: UInt64) {
        // Only treat the app as "already focused" (MRU toggle / cycle) when a
        // REAL window of it is focused. If a sticky dialog is focused, fall
        // through to focusBestWindow so the standard window stays reachable
        // (otherwise the single-real-window case hits mruToggleOrCycle's
        // count==1 no-op and the standard window becomes unreachable).
        if let focused = focused, focused.isStandardWindow,
           config.resolveAlias(focused.appName) == appName {
            mruToggleOrCycle(appName: appName, windows: windows,
                             focused: focused, token: token)
        } else {
            focusBestWindow(appName: appName, windows: windows,
                            focused: focused, token: token)
        }
    }

    private func mruToggleOrCycle(appName: String, windows: [WindowInfo],
                                   focused: WindowInfo, token: UInt64) {
        guard windows.count > 1 else {
            Log.info("jump: \(appName) already focused, only 1 window")
            return
        }

        let state = store.state(for: appName)
        let windowIds = Set(windows.map { $0.id })

        if let prevId = state.prevFocusedId, windowIds.contains(prevId) {
            Log.info("jump: \(appName) MRU switch to window \(prevId)")
            store.recordFocus(appName: appName, windowId: prevId)
            if let target = windows.first(where: { $0.id == prevId }) {
                focusWindow(target, from: focused, token: token)
            }
        } else {
            Log.info("jump: \(appName) no prev window, cycling next")
            let effectiveId = state.lastFocusedId ?? focused.id
            cycleWithKnownState(appName: appName, windows: windows,
                                focusedId: effectiveId, direction: .next,
                                current: focused, token: token)
        }
    }

    private func focusBestWindow(appName: String, windows: [WindowInfo],
                                 focused: WindowInfo?, token: UInt64) {
        let state = store.state(for: appName)

        let target = state.lastFocusedId.flatMap { lastId in
            windows.first(where: { $0.id == lastId })
        } ?? windows.first

        guard let target = target else {
            Log.error("jump: no target window for \(appName)")
            return
        }

        Log.info("jump: focusing window \(target.id) for \(appName)")
        focusWindow(target, from: focused, token: token)
    }

    private func focusWindow(_ target: WindowInfo, from current: WindowInfo?,
                             token: UInt64) {
        let focusTarget = { [self] in
            guard isActive(token) else { return }
            backend.focusWindow(id: target.id) { success in
                if !success {
                    Log.error("focus: yabai focus failed for window \(target.id)")
                }
            }
        }

        if let current, current.isStandardWindow,
           current.space == target.space {
            focusTarget()
            return
        }

        Log.info("focus: switching to space \(target.space) for window \(target.id)")
        backend.focusSpace(index: target.space) { [self] success in
            guard isActive(token) else { return }
            guard success else {
                Log.error("focus: yabai focus failed for space \(target.space)")
                return
            }
            focusTarget()
        }
    }

    private static let windowPollMaxAttempts = 15
    private static let windowPollInterval: TimeInterval = 0.2

    private func pollForWindow(appName: String, focused: WindowInfo?,
                               token: UInt64,
                               attempt: Int = 0) {
        guard attempt < Self.windowPollMaxAttempts else {
            Log.error("jump: timed out waiting for \(appName) window")
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.windowPollInterval) { [self] in
            guard self.isActive(token) else { return }

            self.backend.queryAllWindows { allWindows in
                let windows = self.windowsForApp(appName, from: allWindows)
                guard self.isActive(token) else { return }

                if let win = windows.first {
                    Log.info("jump: found window for \(appName) after \(attempt + 1) polls")
                    self.focusWindow(win, from: focused, token: token)
                } else {
                    self.pollForWindow(appName: appName, focused: focused,
                                       token: token,
                                       attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Next/Prev

    /// Cycle windows using pre-fetched state. No async calls.
    private func cycleWithKnownState(appName: String, windows: [WindowInfo],
                                      focusedId: Int, direction: CycleDirection,
                                      current: WindowInfo, token: UInt64) {
        guard isActive(token) else { return }
        guard windows.count > 1 else {
            Log.info("cycle: only \(windows.count) window(s)")
            return
        }

        store.update(appName: appName) { state in
            state.ring = Self.preserveRingOrder(prevRing: state.ring, windows: windows)
        }

        let ring = store.state(for: appName).ring
        guard ring.count > 1 else { return }

        let currentIdx = ring.firstIndex(of: focusedId) ?? 0
        let step = direction == .next ? 1 : -1
        let nextIdx = (currentIdx + step + ring.count) % ring.count
        let nextId = ring[nextIdx]

        Log.info("cycle: \(currentIdx) -> \(nextIdx) of \(ring.count) (window \(nextId))")
        store.recordFocus(appName: appName, windowId: nextId)
        if let target = windows.first(where: { $0.id == nextId }) {
            focusWindow(target, from: current, token: token)
        }
    }

    func cycle(direction: CycleDirection) {
        let token = nextToken()
        Log.info("cycle: \(direction)")

        backend.focusedWindow { [self] focused in
            guard self.isActive(token), let focused = focused else {
                Log.error("cycle: no focused window")
                return
            }

            let appName = self.config.resolveAlias(focused.appName)

            self.backend.queryAllWindows { allWindows in
                guard self.isActive(token) else { return }
                let windows = self.windowsForApp(appName, from: allWindows)
                self.cycleWithKnownState(appName: appName, windows: windows,
                                          focusedId: focused.id, direction: direction,
                                          current: focused, token: token)
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

    // MARK: - Cancellation token (last-write-wins)

    private func nextToken() -> UInt64 {
        activationQueue.sync {
            currentToken &+= 1
            return currentToken
        }
    }

    private func isActive(_ token: UInt64) -> Bool {
        return activationQueue.sync { currentToken == token }
    }
}
