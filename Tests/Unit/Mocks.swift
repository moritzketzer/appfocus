// Tests/Unit/Mocks.swift
import Foundation

/// Mock window backend that returns preset data and records calls.
final class MockWindowBackend: WindowBackend, @unchecked Sendable {
    var windows: [WindowInfo] = []
    var focusedWin: WindowInfo? = nil
    var focusedWindowIds: [Int] = []
    var focusedSpaces: [Int] = []
    var focusCalls: [String] = []
    var focusSpaceCompletesImmediately = true
    var pendingFocusSpaceCompletions: [(Bool) -> Void] = []
    var focusedWindowCompletesImmediately = true
    var pendingFocusedWindowCompletions: [(WindowInfo?) -> Void] = []
    var focusWindowUpdatesFocusedWin = false

    /// When true, `focusedWindow` never calls its completion — simulating
    /// a `yabai` invocation that hangs instead of returning.
    var focusedWindowHangs = false
    private let callCountLock = NSLock()
    private var _focusedWindowCallCount = 0
    var focusedWindowCallCount: Int {
        callCountLock.lock(); defer { callCountLock.unlock() }
        return _focusedWindowCallCount
    }

    func queryAllWindows(completion: @escaping ([WindowInfo]) -> Void) {
        completion(windows)
    }

    func focusedWindow(completion: @escaping (WindowInfo?) -> Void) {
        callCountLock.lock()
        _focusedWindowCallCount += 1
        callCountLock.unlock()
        guard !focusedWindowHangs else { return }
        if focusedWindowCompletesImmediately {
            completion(focusedWin)
        } else {
            pendingFocusedWindowCompletions.append(completion)
        }
    }

    func focusWindow(id: Int, completion: @escaping (Bool) -> Void) {
        focusedWindowIds.append(id)
        focusCalls.append("window:\(id)")
        if focusWindowUpdatesFocusedWin,
           let target = windows.first(where: { $0.id == id }) {
            focusedWin = target
        }
        completion(true)
    }

    func focusSpace(index: Int, completion: @escaping (Bool) -> Void) {
        focusedSpaces.append(index)
        focusCalls.append("space:\(index)")
        if focusSpaceCompletesImmediately {
            completion(true)
        } else {
            pendingFocusSpaceCompletions.append(completion)
        }
    }

    func completeNextFocusSpace(success: Bool = true) {
        pendingFocusSpaceCompletions.removeFirst()(success)
    }

    @discardableResult
    func completeNextFocusedWindow() -> Bool {
        guard !pendingFocusedWindowCompletions.isEmpty else { return false }
        pendingFocusedWindowCompletions.removeFirst()(focusedWin)
        return true
    }
}

final class MockProcessChecker: ProcessChecker, @unchecked Sendable {
    var runningApps: Set<String> = []

    func isAppRunning(name: String) -> Bool {
        runningApps.contains(name)
    }
}

/// Mock app launcher that records calls without side effects.
final class MockAppLauncher: AppLauncher, @unchecked Sendable {
    var launchedApps: [String] = []
    var reopenedApps: [(String, ReopenStrategy)] = []
    var launchSuccess = true

    func launch(appName: String, completion: @escaping (Bool) -> Void) {
        launchedApps.append(appName)
        completion(launchSuccess)
    }

    func reopen(appName: String, strategy: ReopenStrategy, completion: @escaping () -> Void) {
        reopenedApps.append((appName, strategy))
        completion()
    }
}
