// Sources/Daemon/OutcomeVerifier.swift
import Foundation

/// Receives finalized command traces from ActivationLogic.
protocol OutcomeVerifying {
    /// Record a command that never produced an on-screen action worth
    /// verifying (dropped/superseded/timeout/noop/pre-classified failure).
    func recordImmediate(_ trace: CommandTrace)
    /// Schedule outcome verification for a completed command. Window targets
    /// use one coalesced query; application targets wait for native activation.
    func verify(_ trace: CommandTrace)
    /// A new command began acting: any pending verification can no longer be
    /// attributed (a later dump would blame the previous press for the new
    /// command's switch) — finalize it as unverified-burst.
    func commandStarted()
}

/// Verifies command outcomes off the pump: window targets use a delayed
/// `queryAllWindows`; application targets poll AppKit until activation or a
/// bounded deadline. Successful window reads feed the (fenced) model. Every
/// command appends one JSONL record to the telemetry sink. Never blocks or
/// re-enters the command pump.
final class OutcomeVerifier: OutcomeVerifying {
    private let backend: WindowBackend
    private let workspace: ApplicationWorkspace
    private let model: WindowModelStore
    private let resolveAlias: (String) -> String
    private let sinkPath: String
    private let queue = DispatchQueue(label: "appfocus.verifier")

    /// Delay between command completion and the verification read: long
    /// enough for the WindowServer to settle the transition, short enough
    /// to attribute the state to the command. Instance-mutable for tests.
    var delay: TimeInterval = 0.35
    /// Native open completion can precede the application becoming frontmost
    /// by several seconds on a cold launch. Instance-mutable for tests.
    var applicationVerificationTimeout: TimeInterval = 10.0
    /// AppKit-only condition poll while native activation is still pending.
    /// Instance-mutable for tests.
    var applicationPollInterval: TimeInterval = 0.05
    /// Rotation threshold. Instance-mutable for tests.
    var maxSinkBytes: UInt64 = 5 * 1024 * 1024

    /// The command awaiting verification. A newer completion replaces it
    /// (burst coalescing): the replaced trace is finalized as
    /// `unverified-burst` so rapid switching costs at most one query.
    private var pending: CommandTrace?
    /// Earliest time the CURRENT pending trace may be verified: its own
    /// completion + delay. A replacement pushes this forward, and `fire`
    /// re-arms for the remainder — otherwise the newest press of a burst
    /// would be verified almost immediately after its completion, mid
    /// Space-animation, producing false `invisible`/`wrong-window` on
    /// exactly the burst scenario this telemetry exists to adjudicate.
    private var pendingEligibleAt = DispatchTime.now()
    private var timerArmed = false
    private var loggedWriteFailure = false
    private var activationObservation: AnyObject?
    private var lastActivation: (identity: ApplicationIdentity,
                                 observedAt: DispatchTime)?

    init(backend: WindowBackend,
         workspace: ApplicationWorkspace = SystemApplicationWorkspace(),
         model: WindowModelStore,
         resolveAlias: @escaping (String) -> String,
         sinkPath: String = SocketPath.stateDir + "/telemetry.jsonl") {
        self.backend = backend
        self.workspace = workspace
        self.model = model
        self.resolveAlias = resolveAlias
        self.sinkPath = sinkPath
        activationObservation = workspace.observeActivations { [weak self] identity in
            let observedAt = DispatchTime.now()
            self?.queue.async {
                self?.lastActivation = (identity, observedAt)
            }
        }
    }

    func recordImmediate(_ trace: CommandTrace) {
        queue.async { self.write(trace) }
    }

    func commandStarted() {
        queue.async {
            guard let replaced = self.pending else { return }
            self.pending = nil
            replaced.update { $0.outcome = "unverified-burst" }
            self.write(replaced)
            // The armed timer finds `pending == nil` and no-ops.
        }
    }

    func verify(_ trace: CommandTrace) {
        queue.async {
            // Pre-classified completions (e.g. the focus action itself
            // reported failure) are recorded as-is without a query.
            if trace.currentOutcome == "failed" {
                self.write(trace)
                return
            }
            if let replaced = self.pending {
                replaced.update { $0.outcome = "unverified-burst" }
                self.write(replaced)
            }
            self.pending = trace
            self.pendingEligibleAt = .now() + self.delay
            guard !self.timerArmed else { return }
            self.timerArmed = true
            self.queue.asyncAfter(deadline: self.pendingEligibleAt) {
                self.fire()
            }
        }
    }

    // Runs on `queue`.
    private func fire() {
        timerArmed = false
        guard let trace = pending else { return }
        // A replacement pushed the eligibility forward while this timer was
        // in flight — re-arm for the remainder instead of verifying the
        // newest press too early.
        if DispatchTime.now() < pendingEligibleAt {
            timerArmed = true
            queue.asyncAfter(deadline: pendingEligibleAt) { self.fire() }
            return
        }
        let target = trace.verificationTarget
        if target.kind == .application {
            if classifyApplication(trace, target: target) {
                pending = nil
                write(trace)
            } else {
                timerArmed = true
                queue.asyncAfter(deadline: .now() + applicationPollInterval) {
                    self.fire()
                }
            }
            return
        }
        pending = nil
        let queryStart = DispatchTime.now()
        backend.queryAllWindows { windows in
            self.queue.async {
                self.classify(trace, windows: windows, queryStart: queryStart)
                self.write(trace)
            }
        }
    }

    // Runs on `queue`. Native application verification never touches yabai.
    private func classifyApplication(
        _ trace: CommandTrace,
        target: VerificationTarget
    ) -> Bool {
        let now = DispatchTime.now()
        let notificationIdentity: ApplicationIdentity?
        if let lastActivation,
           lastActivation.observedAt.uptimeNanoseconds
               >= target.evidenceAfter.uptimeNanoseconds {
            notificationIdentity = lastActivation.identity
        } else {
            notificationIdentity = nil
        }

        guard target.bundleIdentifier != nil || target.app != nil else {
            trace.update { t in
                t.verifyMs = 0
                t.outcome = "unverified-queryfail"
                t.detail = appendDetail(t.detail,
                    "no application target identity")
            }
            return true
        }

        let frontmost = workspace.frontmostApplication
        if applicationMatches(frontmost, target: target)
            || applicationMatches(notificationIdentity, target: target) {
            trace.update { t in
                t.verifyMs = elapsedMilliseconds(
                    from: target.evidenceAfter, to: now)
                t.outcome = "ok-app"
            }
            return true
        }

        // The current frontmost app may still be the source app while a cold
        // native launch is completing. Keep waiting until success or deadline.
        if now < target.evidenceAfter + applicationVerificationTimeout {
            return false
        }

        let actual = frontmost ?? notificationIdentity
        trace.update { t in
            t.verifyMs = elapsedMilliseconds(
                from: target.evidenceAfter, to: now)
            t.outcome = "wrong-window"
            let identity = actual.map {
                "\($0.bundleIdentifier ?? "unknown")/\($0.localizedName ?? "unknown")"
            } ?? "none"
            t.detail = appendDetail(t.detail, "actual=\(identity)")
        }
        return true
    }

    private func applicationMatches(
        _ identity: ApplicationIdentity?,
        target: VerificationTarget
    ) -> Bool {
        guard let identity else { return false }
        if let expectedBundle = target.bundleIdentifier {
            return identity.bundleIdentifier == expectedBundle
        }
        if let expectedName = target.app {
            return identity.localizedName.map(resolveAlias) == expectedName
        }
        return false
    }

    private func elapsedMilliseconds(
        from start: DispatchTime,
        to end: DispatchTime
    ) -> Int {
        Int((end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    // Runs on `queue`. All trace mutations under the trace's own lock.
    private func classify(_ trace: CommandTrace, windows: [WindowInfo]?,
                          queryStart: DispatchTime) {
        guard let windows = windows else {
            trace.update { $0.outcome = "unverified-queryfail" }
            return
        }
        let verifyMs = Int((DispatchTime.now().uptimeNanoseconds
            &- queryStart.uptimeNanoseconds) / 1_000_000)
        // Verification doubles as a fresh post-switch model rebuild.
        model.replaceSnapshot(windows, queryStartedAt: queryStart)

        let focused = windows.first(where: { $0.hasFocus })
        trace.update { t in
            t.verifyMs = verifyMs
            if let target = t.targetWindowId {
                if let focused = focused, focused.id == target {
                    t.outcome = focused.isVisible ? "ok" : "invisible"
                    if !focused.isVisible {
                        t.detail = appendDetail(t.detail,
                            "focused but not visible; space=\(focused.space)")
                    }
                } else if let focused = focused, let app = t.app,
                          resolveAlias(focused.appName) == app {
                    t.outcome = "ok-app"
                    t.detail = appendDetail(t.detail,
                        "landed on \(focused.id), predicted \(target)")
                } else {
                    t.outcome = "wrong-window"
                    t.detail = appendDetail(t.detail,
                        "actual=\(focused.map { "\(resolveAlias($0.appName))/\($0.id) space=\($0.space)" } ?? "none")")
                }
            } else if let app = t.app {
                // Launch/reopen/fallback paths: no window id was predictable;
                // success means the intended app is frontmost.
                if let focused = focused, resolveAlias(focused.appName) == app {
                    t.outcome = "ok-app"
                } else {
                    t.outcome = "wrong-window"
                    t.detail = appendDetail(t.detail,
                        "actual=\(focused.map { "\(resolveAlias($0.appName))/\($0.id)" } ?? "none")")
                }
            } else {
                t.outcome = "unverified-queryfail"
                t.detail = appendDetail(t.detail, "no target and no app")
            }
        }
    }

    private func appendDetail(_ existing: String?, _ add: String) -> String {
        existing.map { "\($0); \(add)" } ?? add
    }

    // Runs on `queue`. Best effort — telemetry must never affect commands.
    private func write(_ trace: CommandTrace) {
        let line = trace.jsonLine() + "\n"
        do {
            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: sinkPath) {
                FileManager.default.createFile(atPath: sinkPath, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: sinkPath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            if !loggedWriteFailure {
                loggedWriteFailure = true
                Log.error("telemetry: write failed (\(error)); further failures silenced")
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sinkPath),
              let size = attrs[.size] as? UInt64, size > maxSinkBytes else { return }
        let old = sinkPath + ".1"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: sinkPath, toPath: old)
    }
}
