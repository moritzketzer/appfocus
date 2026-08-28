// Tests/Unit/Mocks.swift
import Foundation

/// Mock native workspace that records URL activation and emits deterministic
/// frontmost-application notifications without touching AppKit.
final class MockApplicationWorkspace: ApplicationWorkspace, @unchecked Sendable {
    var frontmostApplication: ApplicationIdentity?
    var urls: [String: URL] = [:]
    var opened: [(url: URL, activates: Bool)] = []
    var openResult: Result<ApplicationIdentity, Error> = .success(
        ApplicationIdentity(bundleIdentifier: "com.apple.Safari",
                            localizedName: "Safari"))
    private var handlers: [(ApplicationIdentity) -> Void] = []

    func applicationURL(bundleIdentifier: String) -> URL? {
        urls[bundleIdentifier]
    }

    func openApplication(
        at url: URL,
        activates: Bool,
        completion: @escaping (Result<ApplicationIdentity, Error>) -> Void
    ) {
        opened.append((url, activates))
        completion(openResult)
    }

    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject {
        handlers.append(handler)
        return NSObject()
    }

    func emitActivation(_ identity: ApplicationIdentity) {
        frontmostApplication = identity
        handlers.forEach { $0(identity) }
    }
}

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

/// Mock verifier capturing traces without queries or file writes.
final class MockOutcomeVerifier: OutcomeVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _immediate: [CommandTrace] = []
    private var _verified: [CommandTrace] = []

    var immediate: [CommandTrace] {
        lock.lock(); defer { lock.unlock() }; return _immediate
    }
    var verified: [CommandTrace] {
        lock.lock(); defer { lock.unlock() }; return _verified
    }
    var all: [CommandTrace] {
        lock.lock(); defer { lock.unlock() }; return _immediate + _verified
    }

    func recordImmediate(_ trace: CommandTrace) {
        lock.lock(); _immediate.append(trace); lock.unlock()
    }

    func verify(_ trace: CommandTrace) {
        lock.lock(); _verified.append(trace); lock.unlock()
    }

    private var _commandStartedCount = 0
    var commandStartedCount: Int {
        lock.lock(); defer { lock.unlock() }; return _commandStartedCount
    }

    func commandStarted() {
        lock.lock(); _commandStartedCount += 1; lock.unlock()
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
    var activatedApps: [String] = []
    var launchSuccess = true

    func launch(appName: String, completion: @escaping (Bool) -> Void) {
        launchedApps.append(appName)
        completion(launchSuccess)
    }

    func activate(appName: String, completion: @escaping () -> Void) {
        activatedApps.append(appName)
        completion()
    }

    func reopen(appName: String, strategy: ReopenStrategy, completion: @escaping () -> Void) {
        reopenedApps.append((appName, strategy))
        completion()
    }
}
