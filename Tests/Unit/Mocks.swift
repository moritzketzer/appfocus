// Tests/Unit/Mocks.swift
import Foundation

/// Mock native workspace that records URL activation and emits deterministic
/// frontmost-application notifications without touching AppKit.
final class MockApplicationWorkspace: ApplicationWorkspace, @unchecked Sendable {
    var urls: [String: URL] = [:]
    var openResult: Result<ApplicationIdentity, Error> = .success(
        ApplicationIdentity(bundleIdentifier: "com.apple.Safari",
                            localizedName: "Safari"))

    /// Guards the frontmost identity, the recorded opens, and the activation
    /// handlers: the daemon writes and reads them from GCD callback threads
    /// while the test thread asserts. Handlers and completions always run
    /// OUTSIDE the lock — an activation handler reads back
    /// `frontmostApplication`, which would deadlock on this NSLock.
    private let lock = NSLock()
    private var _frontmostApplication: ApplicationIdentity?
    private var _opened: [(url: URL, activates: Bool)] = []
    private var handlers: [(ApplicationIdentity) -> Void] = []

    var frontmostApplication: ApplicationIdentity? {
        get { lock.lock(); defer { lock.unlock() }; return _frontmostApplication }
        set { lock.lock(); _frontmostApplication = newValue; lock.unlock() }
    }
    var opened: [(url: URL, activates: Bool)] {
        lock.lock(); defer { lock.unlock() }; return _opened
    }

    func applicationURL(bundleIdentifier: String) -> URL? {
        urls[bundleIdentifier]
    }

    func openApplication(
        at url: URL,
        activates: Bool,
        completion: @escaping (Result<ApplicationIdentity, Error>) -> Void
    ) {
        lock.lock()
        _opened.append((url, activates))
        lock.unlock()
        completion(openResult)
    }

    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
        return NSObject()
    }

    func emitActivation(_ identity: ApplicationIdentity) {
        lock.lock()
        _frontmostApplication = identity
        let observers = handlers
        lock.unlock()
        observers.forEach { $0(identity) }
    }
}

/// Mock window backend that returns preset data and records calls.
final class MockWindowBackend: WindowBackend, @unchecked Sendable {
    var windows: [WindowInfo] = []
    var focusedWin: WindowInfo? = nil
    var focusSpaceCompletesImmediately = true
    var focusWindowCompletesImmediately = true
    var queryAllWindowsCompletesImmediately = true
    var onDeferredQueryReady: (() -> Void)?
    /// When true, queryAllWindows reports FAILURE (nil), not an empty list.
    var queryAllWindowsFails = false

    /// Guards every recorded call and pending completion: the daemon appends
    /// to them from GCD callback threads while the test thread asserts on
    /// them. Completions always run OUTSIDE the lock — they re-enter the mock,
    /// which would deadlock on this NSLock.
    private let lock = NSLock()
    private var _queryAllWindowsCallCount = 0
    private var _focusedWindowIds: [Int] = []
    private var _focusedSpaces: [Int] = []
    private var _focusCalls: [String] = []
    private var _pendingFocusSpaceCompletions: [(Bool) -> Void] = []
    private var _pendingFocusWindowCompletions: [(Bool) -> Void] = []
    private var _pendingQueryAllWindowsCompletions: [([WindowInfo]?) -> Void] = []

    var queryAllWindowsCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _queryAllWindowsCallCount
    }
    var focusedWindowIds: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _focusedWindowIds
    }
    var focusedSpaces: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _focusedSpaces
    }
    var focusCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _focusCalls
    }
    var pendingFocusSpaceCompletions: [(Bool) -> Void] {
        lock.lock(); defer { lock.unlock() }
        return _pendingFocusSpaceCompletions
    }
    var pendingFocusWindowCompletions: [(Bool) -> Void] {
        lock.lock(); defer { lock.unlock() }
        return _pendingFocusWindowCompletions
    }

    func queryAllWindows(completion: @escaping ([WindowInfo]?) -> Void) {
        lock.lock()
        _queryAllWindowsCallCount += 1
        if queryAllWindowsCompletesImmediately {
            let result = queryAllWindowsFails ? nil : windows
            lock.unlock()
            completion(result)
        } else {
            _pendingQueryAllWindowsCompletions.append(completion)
            let ready = onDeferredQueryReady
            lock.unlock()
            ready?()
        }
    }

    @discardableResult
    func completeNextQueryAllWindows() -> Bool {
        lock.lock()
        guard !_pendingQueryAllWindowsCompletions.isEmpty else {
            lock.unlock()
            return false
        }
        let completion = _pendingQueryAllWindowsCompletions.removeFirst()
        let result = queryAllWindowsFails ? nil : windows
        lock.unlock()
        completion(result)
        return true
    }

    func focusedWindow(completion: @escaping (WindowInfo?) -> Void) {
        completion(focusedWin)
    }

    func focusWindow(id: Int, completion: @escaping (Bool) -> Void) {
        lock.lock()
        _focusedWindowIds.append(id)
        _focusCalls.append("window:\(id)")
        if focusWindowCompletesImmediately {
            lock.unlock()
            completion(true)
        } else {
            _pendingFocusWindowCompletions.append(completion)
            lock.unlock()
        }
    }

    func focusSpace(index: Int, completion: @escaping (Bool) -> Void) {
        lock.lock()
        _focusedSpaces.append(index)
        _focusCalls.append("space:\(index)")
        if focusSpaceCompletesImmediately {
            lock.unlock()
            completion(true)
        } else {
            _pendingFocusSpaceCompletions.append(completion)
            lock.unlock()
        }
    }

    func completeNextFocusSpace(success: Bool = true) {
        lock.lock()
        let completion = _pendingFocusSpaceCompletions.removeFirst()
        lock.unlock()
        completion(success)
    }

    @discardableResult
    func completeNextFocusWindow(success: Bool = true) -> Bool {
        lock.lock()
        guard !_pendingFocusWindowCompletions.isEmpty else {
            lock.unlock()
            return false
        }
        let completion = _pendingFocusWindowCompletions.removeFirst()
        lock.unlock()
        completion(success)
        return true
    }
}

/// Mock verifier capturing traces without queries or file writes.
final class MockOutcomeVerifier: OutcomeVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _immediate: [CommandTrace] = []
    private var _verified: [CommandTrace] = []
    var onNextImmediate: (() -> Void)?

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
        lock.lock()
        _immediate.append(trace)
        let callback = onNextImmediate
        onNextImmediate = nil
        lock.unlock()
        callback?()
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

/// Mock app launcher that records calls without side effects.
struct ApplicationActivationCall: Equatable {
    let appName: String
    let bundleIdentifier: String?
}

final class MockAppLauncher: AppLauncher, @unchecked Sendable {
    var activationCompletesImmediately = true
    var activationResult = ApplicationActionResult(
        success: true, path: .legacyName, bundleIdentifier: nil, detail: nil)
    var reopenResult = ApplicationActionResult(
        success: true, path: .reopen, bundleIdentifier: nil, detail: nil)

    /// Guards the recorded calls and pending completions, same reasoning as
    /// `MockWindowBackend`: appended from GCD callback threads, asserted on
    /// from the test thread, completions invoked outside the lock.
    private let lock = NSLock()
    private var _reopenedApps: [(String, ReopenStrategy)] = []
    private var _activationCalls: [ApplicationActivationCall] = []
    private var _pendingActivationCompletions: [
        (ApplicationActionResult) -> Void
    ] = []

    var reopenedApps: [(String, ReopenStrategy)] {
        lock.lock(); defer { lock.unlock() }
        return _reopenedApps
    }
    var activationCalls: [ApplicationActivationCall] {
        lock.lock(); defer { lock.unlock() }
        return _activationCalls
    }
    var pendingActivationCompletions: [(ApplicationActionResult) -> Void] {
        lock.lock(); defer { lock.unlock() }
        return _pendingActivationCompletions
    }

    func activate(
        appName: String,
        bundleIdentifier: String?,
        completion: @escaping (ApplicationActionResult) -> Void
    ) {
        lock.lock()
        _activationCalls.append(ApplicationActivationCall(
            appName: appName, bundleIdentifier: bundleIdentifier))
        if activationCompletesImmediately {
            lock.unlock()
            completion(activationResult)
        } else {
            _pendingActivationCompletions.append(completion)
            lock.unlock()
        }
    }

    @discardableResult
    func completeNextActivation(
        result: ApplicationActionResult? = nil
    ) -> Bool {
        lock.lock()
        guard !_pendingActivationCompletions.isEmpty else {
            lock.unlock()
            return false
        }
        let completion = _pendingActivationCompletions.removeFirst()
        lock.unlock()
        completion(result ?? activationResult)
        return true
    }

    func reopen(
        appName: String,
        strategy: ReopenStrategy,
        completion: @escaping (ApplicationActionResult) -> Void
    ) {
        lock.lock()
        _reopenedApps.append((appName, strategy))
        lock.unlock()
        completion(reopenResult)
    }

}
