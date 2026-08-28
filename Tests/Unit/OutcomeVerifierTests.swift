// Tests/Unit/OutcomeVerifierTests.swift
import Foundation
import Testing

private func win(_ id: Int, app: String = "Safari", space: Int = 1,
                 hasFocus: Bool = false, visible: Bool = true) -> WindowInfo {
    WindowInfo(id: id, appName: app, space: space,
               isMinimized: false, role: "AXWindow", title: "w\(id)",
               hasAXReference: true, subrole: "AXStandardWindow",
               hasFocus: hasFocus, isVisible: visible)
}

private final class BlockingApplicationWorkspace:
    ApplicationWorkspace, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ApplicationIdentity?
    let frontmostReadStarted = DispatchSemaphore(value: 0)
    let releaseFrontmostRead = DispatchSemaphore(value: 0)

    init(frontmostApplication: ApplicationIdentity?) {
        identity = frontmostApplication
    }

    var frontmostApplication: ApplicationIdentity? {
        frontmostReadStarted.signal()
        releaseFrontmostRead.wait()
        lock.lock()
        defer { lock.unlock() }
        return identity
    }

    func setFrontmostApplication(_ identity: ApplicationIdentity?) {
        lock.lock()
        self.identity = identity
        lock.unlock()
    }

    func applicationURL(bundleIdentifier: String) -> URL? { nil }

    func openApplication(
        at url: URL,
        activates: Bool,
        completion: @escaping (Result<ApplicationIdentity, Error>) -> Void
    ) {}

    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject {
        NSObject()
    }
}

private final class CommandStartProbe: @unchecked Sendable {
    private let verifier: OutcomeVerifying
    let returned = DispatchSemaphore(value: 0)

    init(verifier: OutcomeVerifying) {
        self.verifier = verifier
    }

    func run() {
        verifier.commandStarted()
        returned.signal()
    }
}

private struct VerifierHarness {
    let backend: MockWindowBackend
    let workspace: MockApplicationWorkspace
    let model: WindowModelStore
    let verifier: OutcomeVerifier
    let sink: String

    init() {
        backend = MockWindowBackend()
        workspace = MockApplicationWorkspace()
        model = WindowModelStore()
        sink = NSTemporaryDirectory() + "appfocus-telemetry-\(UUID().uuidString).jsonl"
        verifier = OutcomeVerifier(backend: backend, workspace: workspace,
                                   model: model,
                                   resolveAlias: { $0 }, sinkPath: sink)
        verifier.delay = 0.05
        verifier.applicationVerificationTimeout = 0.15
        verifier.applicationPollInterval = 0.01
    }

    /// Condition-poll the sink until it holds `count` lines (GCD timers
    /// drift under parallel-test load; never assert on a fixed sleep).
    func waitForRecords(_ count: Int, timeoutMs: Int = 4000) -> [[String: Any]] {
        for _ in 0..<(timeoutMs / 20) {
            let lines = records()
            if lines.count >= count { return lines }
            usleep(20_000)
        }
        return records()
    }

    func records() -> [[String: Any]] {
        guard let content = try? String(contentsOfFile: sink, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    func trace(_ command: String = "jump", app: String? = "Safari",
               target: Int? = nil) -> CommandTrace {
        let t = CommandTrace(command: command, app: app)
        t.path = "hot"
        t.targetWindowId = target
        t.decidedAt = .now()
        t.actionedAt = .now()
        t.outcome = "unknown"
        return t
    }

    func applicationTrace(app: String, bundle: String?) -> CommandTrace {
        let t = trace(app: app)
        t.path = bundle == nil ? "legacy-name" : "native-bundle"
        t.verificationTargetKind = .application
        t.targetBundleIdentifier = bundle
        return t
    }
}

@Suite("OutcomeVerifier")
struct OutcomeVerifierTests {

    @Test func nativeApplicationVerificationNeverQueriesBackend() {
        let h = VerifierHarness()
        h.workspace.frontmostApplication = ApplicationIdentity(
            bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords")

        h.verifier.verify(h.applicationTrace(
            app: "Passwords", bundle: "com.apple.Passwords"))

        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "ok-app")
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func activationNotificationCanVerifyNativeApplication() {
        let h = VerifierHarness()
        let trace = h.applicationTrace(
            app: "Passwords", bundle: "com.apple.Passwords")
        h.verifier.verify(trace)
        h.workspace.emitActivation(ApplicationIdentity(
            bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords"))
        h.workspace.frontmostApplication = nil

        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "ok-app")
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func delayedActivationDoesNotPrematurelyRecordWrongWindow() {
        let h = VerifierHarness()
        h.verifier.applicationVerificationTimeout = 1.0
        h.workspace.frontmostApplication = ApplicationIdentity(
            bundleIdentifier: "com.cmuxterm.app", localizedName: "cmux")

        h.verifier.verify(h.applicationTrace(
            app: "Passwords", bundle: "com.apple.Passwords"))

        #expect(h.waitForRecords(1, timeoutMs: 200).isEmpty)
        h.workspace.emitActivation(ApplicationIdentity(
            bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords"))

        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "ok-app")
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func applicationVerificationRejectsWrongBundle() {
        let h = VerifierHarness()
        h.workspace.frontmostApplication = ApplicationIdentity(
            bundleIdentifier: "com.apple.Safari", localizedName: "Safari")

        h.verifier.verify(h.applicationTrace(
            app: "Passwords", bundle: "com.apple.Passwords"))

        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "wrong-window")
        #expect((recs.first?["detail"] as? String)?.contains("com.apple.Safari") == true)
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func legacyApplicationVerificationUsesLocalizedName() {
        let h = VerifierHarness()
        h.workspace.frontmostApplication = ApplicationIdentity(
            bundleIdentifier: nil, localizedName: "Generic App")

        h.verifier.verify(h.applicationTrace(app: "Generic App", bundle: nil))

        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "ok-app")
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func preFailedApplicationTraceRecordsWithoutQuery() {
        let h = VerifierHarness()
        let trace = h.applicationTrace(
            app: "Passwords", bundle: "com.apple.Passwords")
        trace.outcome = "failed"

        h.verifier.verify(trace)

        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "failed")
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func applicationBurstCoalescesWithoutBackendQuery() {
        let h = VerifierHarness()
        h.workspace.frontmostApplication = ApplicationIdentity(
            bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords")
        h.verifier.verify(h.applicationTrace(
            app: "Safari", bundle: "com.apple.Safari"))
        h.verifier.verify(h.applicationTrace(
            app: "Passwords", bundle: "com.apple.Passwords"))

        let recs = h.waitForRecords(2)
        let outcomes = recs.compactMap { $0["outcome"] as? String }.sorted()
        #expect(outcomes == ["ok-app", "unverified-burst"])
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func staleActivationNotificationCannotVerifyLaterCommand() {
        let h = VerifierHarness()
        h.workspace.emitActivation(ApplicationIdentity(
            bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords"))
        h.workspace.frontmostApplication = ApplicationIdentity(
            bundleIdentifier: "com.apple.Safari", localizedName: "Safari")

        h.verifier.verify(h.applicationTrace(
            app: "Passwords", bundle: "com.apple.Passwords"))

        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "wrong-window")
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func classifiesOkWhenTargetFocusedAndVisible() {
        let h = VerifierHarness()
        h.backend.windows = [win(1, hasFocus: true, visible: true), win(2)]
        h.verifier.verify(h.trace(target: 1))
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "ok")
        #expect(recs.first?["verify_ms"] != nil)
    }

    @Test func classifiesInvisibleWhenTargetFocusedButNotVisible() {
        let h = VerifierHarness()
        h.backend.windows = [win(1, hasFocus: true, visible: false)]
        h.verifier.verify(h.trace(target: 1))
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "invisible")
    }

    @Test func classifiesOkAppWhenSameAppDifferentWindow() {
        let h = VerifierHarness()
        h.backend.windows = [win(2, hasFocus: true), win(1)]
        h.verifier.verify(h.trace(target: 1))
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "ok-app")
    }

    @Test func classifiesWrongWindowWhenOtherAppFocused() {
        let h = VerifierHarness()
        h.backend.windows = [win(9, app: "cmux", hasFocus: true), win(1)]
        h.verifier.verify(h.trace(target: 1))
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "wrong-window")
        #expect((recs.first?["detail"] as? String)?.contains("cmux") == true)
    }

    @Test func classifiesOkAppForAppOnlyIntent() {
        let h = VerifierHarness()
        h.backend.windows = [win(5, hasFocus: true)]
        h.verifier.verify(h.trace(target: nil))   // launch/reopen/fallback
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "ok-app")
    }

    @Test func queryFailureYieldsUnverified() {
        let h = VerifierHarness()
        h.backend.queryAllWindowsFails = true
        h.verifier.verify(h.trace(target: 1))
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "unverified-queryfail")
    }

    @Test func burstCoalescesToOneVerification() {
        let h = VerifierHarness()
        h.backend.windows = [win(3, hasFocus: true)]
        h.verifier.verify(h.trace(target: 1))
        h.verifier.verify(h.trace(target: 2))
        h.verifier.verify(h.trace(target: 3))
        let recs = h.waitForRecords(3)
        let outcomes = recs.compactMap { $0["outcome"] as? String }.sorted()
        #expect(outcomes == ["ok", "unverified-burst", "unverified-burst"])
        #expect(h.backend.queryAllWindowsCallCount == 1)
    }

    @Test func newCommandStartInvalidatesPendingVerification() {
        // At medium cadence (~500ms) a pending verification can fire just as
        // the NEXT command's switch lands, blaming the previous press
        // (observed live 2026-08-16: 15 false wrong-window records). Once a
        // new command starts acting, the previous outcome must become
        // unverified-burst — never attributed from a later dump.
        let h = VerifierHarness()
        h.backend.windows = [win(2, hasFocus: true), win(1)]
        h.verifier.verify(h.trace(target: 1))
        h.verifier.commandStarted()
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "unverified-burst")
        // The armed timer must find nothing to verify: no query ever runs.
        usleep(200_000)
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func commandStartFencesAnInFlightApplicationPoll() {
        let backend = MockWindowBackend()
        let workspace = BlockingApplicationWorkspace(frontmostApplication:
            ApplicationIdentity(bundleIdentifier: "com.cmuxterm.app",
                                localizedName: "cmux"))
        let sink = NSTemporaryDirectory()
            + "appfocus-telemetry-\(UUID().uuidString).jsonl"
        let verifier = OutcomeVerifier(
            backend: backend,
            workspace: workspace,
            model: WindowModelStore(),
            resolveAlias: { $0 },
            sinkPath: sink)
        verifier.delay = 0.01
        verifier.applicationVerificationTimeout = 1.0
        verifier.applicationPollInterval = 0.01
        let trace = CommandTrace(command: "jump", app: "Passwords")
        trace.path = "native-bundle"
        trace.verificationTargetKind = .application
        trace.targetBundleIdentifier = "com.apple.Passwords"
        trace.decidedAt = .now()
        trace.actionedAt = .now()
        trace.outcome = "unknown"

        verifier.verify(trace)
        #expect(workspace.frontmostReadStarted.wait(
            timeout: .now() + 10) == .success)

        let commandStart = CommandStartProbe(verifier: verifier)
        let commandStartThread = Thread { commandStart.run() }
        commandStartThread.start()
        #expect(commandStart.returned.wait(
            timeout: .now() + 10) == .success)

        // The newer action lands after commandStarted returns but before the
        // older poll reads. A generation fence must keep that newer focus
        // transition from verifying the older trace.
        workspace.setFrontmostApplication(ApplicationIdentity(
            bundleIdentifier: "com.apple.Passwords",
            localizedName: "Passwords"))
        workspace.releaseFrontmostRead.signal()

        var records: [[String: Any]] = []
        for _ in 0..<500 where records.isEmpty {
            if let content = try? String(contentsOfFile: sink,
                                         encoding: .utf8) {
                records = content.split(separator: "\n").compactMap {
                    (try? JSONSerialization.jsonObject(
                        with: Data($0.utf8))) as? [String: Any]
                }
            }
            if records.isEmpty { usleep(20_000) }
        }

        #expect(records.count == 1)
        #expect(records.first?["outcome"] as? String == "unverified-burst")
        #expect(records.contains {
            $0["outcome"] as? String == "ok-app"
        } == false)
        #expect(backend.queryAllWindowsCallCount == 0)
    }

    @Test func commandStartFencesAnInFlightWindowQuery() {
        let h = VerifierHarness()
        let deferredQueryReady = DispatchSemaphore(value: 0)
        let releaseDeferredQuery = DispatchSemaphore(value: 0)
        h.backend.onDeferredQueryReady = {
            deferredQueryReady.signal()
            releaseDeferredQuery.wait()
        }
        h.backend.queryAllWindowsCompletesImmediately = false
        h.verifier.verify(h.trace(target: 1))

        #expect(deferredQueryReady.wait(timeout: .now() + 10) == .success)
        #expect(h.backend.queryAllWindowsCallCount == 1)

        h.verifier.commandStarted()
        h.backend.windows = [win(1, hasFocus: true)]
        let completionWasReady = h.backend.completeNextQueryAllWindows()
        releaseDeferredQuery.signal()
        #expect(completionWasReady)

        let records = h.waitForRecords(1)
        #expect(records.count == 1)
        #expect(records.first?["outcome"] as? String == "unverified-burst")
        #expect(records.contains {
            $0["outcome"] as? String == "ok"
        } == false)
    }

    @Test func preFailedTraceRecordsWithoutQuery() {
        let h = VerifierHarness()
        let t = h.trace(target: 1)
        t.outcome = "failed"
        h.verifier.verify(t)
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "failed")
        #expect(h.backend.queryAllWindowsCallCount == 0)
    }

    @Test func recordImmediateWrites() {
        let h = VerifierHarness()
        let t = h.trace()
        t.outcome = "dropped-backoff"
        h.verifier.recordImmediate(t)
        let recs = h.waitForRecords(1)
        #expect(recs.first?["outcome"] as? String == "dropped-backoff")
    }

    @Test func verificationFeedsModel() {
        let h = VerifierHarness()
        h.backend.windows = [win(7, hasFocus: true)]
        h.verifier.verify(h.trace(target: 7))
        _ = h.waitForRecords(1)
        #expect(h.model.focusedWindow?.id == 7)
    }

    @Test func sinkRotatesAtThreshold() {
        let h = VerifierHarness()
        h.verifier.maxSinkBytes = 200
        h.backend.windows = [win(1, hasFocus: true)]
        for i in 0..<8 {
            let t = h.trace()
            t.outcome = "noop"
            t.detail = "filler-\(i)-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
            h.verifier.recordImmediate(t)
        }
        _ = h.waitForRecords(1)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: h.sink + ".1") {
            usleep(20_000)
        }
        #expect(FileManager.default.fileExists(atPath: h.sink + ".1"))
    }
}
