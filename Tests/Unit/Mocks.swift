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
    var focusWindowCompletesImmediately = true
    var pendingFocusWindowCompletions: [(Bool) -> Void] = []
    var queryAllWindowsCompletesImmediately = true
    var pendingQueryAllWindowsCompletions: [([WindowInfo]?) -> Void] = []
    /// When true, queryAllWindows reports FAILURE (nil), not an empty list.
    var queryAllWindowsFails = false

    private let callCountLock = NSLock()
    private var _queryAllWindowsCallCount = 0
    var queryAllWindowsCallCount: Int {
        callCountLock.lock(); defer { callCountLock.unlock() }
        return _queryAllWindowsCallCount
    }

    func queryAllWindows(completion: @escaping ([WindowInfo]?) -> Void) {
        callCountLock.lock()
        _queryAllWindowsCallCount += 1
        callCountLock.unlock()
        if queryAllWindowsCompletesImmediately {
            completion(queryAllWindowsFails ? nil : windows)
        } else {
            pendingQueryAllWindowsCompletions.append(completion)
        }
    }

    @discardableResult
    func completeNextQueryAllWindows() -> Bool {
        guard !pendingQueryAllWindowsCompletions.isEmpty else { return false }
        pendingQueryAllWindowsCompletions.removeFirst()(queryAllWindowsFails ? nil : windows)
        return true
    }

    func focusedWindow(completion: @escaping (WindowInfo?) -> Void) {
        completion(focusedWin)
    }

    func focusWindow(id: Int, completion: @escaping (Bool) -> Void) {
        focusedWindowIds.append(id)
        focusCalls.append("window:\(id)")
        if focusWindowCompletesImmediately {
            completion(true)
        } else {
            pendingFocusWindowCompletions.append(completion)
        }
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
    func completeNextFocusWindow(success: Bool = true) -> Bool {
        guard !pendingFocusWindowCompletions.isEmpty else { return false }
        pendingFocusWindowCompletions.removeFirst()(success)
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
