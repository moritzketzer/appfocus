// Sources/Daemon/CommandTrace.swift
import Foundation

/// Per-command telemetry record: what was intended, which path the daemon
/// took, what happened on screen, and how long each phase took. Created at
/// command entry, enriched along the existing chain (assignments only), and
/// finalized by the OutcomeVerifier into one JSONL line.
///
/// A reference type on purpose: the async chain captures and mutates one
/// shared trace instead of re-threading a value through every completion.
///
/// Thread-safety: fields are written from the pump's activation queue, from
/// backend completion queues (late callbacks of superseded commands
/// included), and read by the verifier's queue during serialization. All
/// mutations go through `update`, and `jsonLine` serializes under the same
/// lock, so an emission can never observe a torn write and a late callback
/// can never corrupt a record mid-serialization.
final class CommandTrace {
    private let lock = NSLock()

    let command: String        // "jump" | "next" | "prev"
    let app: String?           // resolved target app (nil for cycle at entry)
    var path: String = "unknown"  // hot|confirm|launch|reopen|fallback|retry|noop
    var targetWindowId: Int?
    var targetSpace: Int?
    var crossedSpace = false   // model's view: target on another Space than
                               // the focused window (focusSpace is ALWAYS
                               // issued; this drives the stats split only)
    let receivedAt: DispatchTime
    var decidedAt: DispatchTime?
    var actionedAt: DispatchTime?
    var verifyMs: Int?
    var outcome: String = "unknown"
    var detail: String?
    /// Forensics captured at decision time (model state the decision used).
    var modelGeneration: UInt64?
    var modelFocusedId: Int?

    init(command: String, app: String?,
         receivedAt: DispatchTime = .now()) {
        self.command = command
        self.app = app
        self.receivedAt = receivedAt
    }

    /// All post-init mutations funnel through here.
    func update(_ body: (CommandTrace) -> Void) {
        lock.lock()
        body(self)
        lock.unlock()
    }

    /// Locked read of the current outcome (routing decisions).
    var currentOutcome: String {
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    private static func ms(_ from: DispatchTime, _ to: DispatchTime) -> Int {
        Int((to.uptimeNanoseconds &- from.uptimeNanoseconds) / 1_000_000)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One JSONL line. `at` is the wall-clock stamp for the record (the
    /// trace itself only holds monotonic times). Serializes under the lock.
    func jsonLine(at date: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        var obj: [String: Any] = [
            "ts": Self.isoFormatter.string(from: date),
            "cmd": command,
            "path": path,
            "outcome": outcome,
            "crossed_space": crossedSpace,
        ]
        if let app = app { obj["app"] = app }
        if let id = targetWindowId { obj["target_id"] = id }
        if let sp = targetSpace { obj["target_space"] = sp }
        if let decided = decidedAt {
            obj["decide_ms"] = Self.ms(receivedAt, decided)
        }
        if let decided = decidedAt, let actioned = actionedAt {
            obj["act_ms"] = Self.ms(decided, actioned)
        }
        if let actioned = actionedAt {
            obj["total_ms"] = Self.ms(receivedAt, actioned)
        }
        if let v = verifyMs { obj["verify_ms"] = v }
        if let d = detail { obj["detail"] = d }
        if let g = modelGeneration { obj["model_gen"] = g }
        if let f = modelFocusedId { obj["model_focused"] = f }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"outcome\":\"encode-error\"}"
        }
        return line
    }
}
