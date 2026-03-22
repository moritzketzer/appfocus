// Tests/Unit/Mocks.swift
import Foundation

/// Mock window backend that returns preset data and records calls.
final class MockWindowBackend: WindowBackend, @unchecked Sendable {
    var windows: [WindowInfo] = []
    var focusedWin: WindowInfo? = nil
    var focusedWindowIds: [Int] = []
    var focusedSpaces: [Int] = []

    func queryAllWindows(completion: @escaping ([WindowInfo]) -> Void) {
        completion(windows)
    }

    func focusedWindow(completion: @escaping (WindowInfo?) -> Void) {
        completion(focusedWin)
    }

    func focusWindow(id: Int, completion: @escaping (Bool) -> Void) {
        focusedWindowIds.append(id)
        completion(true)
    }

    func focusSpace(index: Int, completion: @escaping (Bool) -> Void) {
        focusedSpaces.append(index)
        completion(true)
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
