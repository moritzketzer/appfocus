// Sources/Common/TelemetryStats.swift
import Foundation

/// Pure aggregation over telemetry JSONL lines — the analysis behind
/// `appfocus stats`. Kept side-effect free so tests can drive it with
/// fixture lines.
enum TelemetryStats {

    /// Outcomes that mean "the press did what it should".
    private static let successOutcomes: Set<String> = ["ok", "ok-app", "noop"]
    /// Outcomes excluded from the success-rate denominator: the command
    /// never got a decided run of its own (or verification was skipped).
    private static let undecidedOutcomes: Set<String> = [
        "superseded", "dropped-backoff", "dropped-cap",
        "unverified-burst", "unverified-queryfail",
    ]

    static func parseSince(_ spec: String) -> TimeInterval? {
        guard spec.count >= 2, let value = Double(spec.dropLast()) else { return nil }
        switch spec.last! {
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86400
        default: return nil
        }
    }

    static func aggregate(lines: [String], since: Date? = nil,
                          now: Date = Date()) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var records: [[String: Any]] = []
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let since = since {
                guard let ts = obj["ts"] as? String,
                      let date = isoFormatter.date(from: ts),
                      date >= since else { continue }
            }
            records.append(obj)
        }
        guard !records.isEmpty else { return "No telemetry records in range." }

        var outcomeCounts: [String: Int] = [:]
        for r in records {
            let o = r["outcome"] as? String ?? "unknown"
            outcomeCounts[o, default: 0] += 1
        }

        let decided = records.filter {
            !undecidedOutcomes.contains($0["outcome"] as? String ?? "")
        }
        let successes = decided.filter {
            successOutcomes.contains($0["outcome"] as? String ?? "")
        }
        let rate = decided.isEmpty ? 0
            : Double(successes.count) / Double(decided.count) * 100

        func percentiles(_ values: [Int]) -> (p50: Int, p95: Int)? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let p50 = sorted[(sorted.count - 1) / 2]
            let p95 = sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
            return (p50, p95)
        }

        func latencyLine(_ label: String, _ subset: [[String: Any]]) -> String {
            let totals = subset.compactMap { $0["total_ms"] as? Int }
            guard let p = percentiles(totals) else { return "  \(label): n=0" }
            return "  \(label): n=\(totals.count) p50=\(p.p50)ms p95=\(p.p95)ms"
        }

        var out: [String] = []
        out.append("Telemetry: \(records.count) records\(since != nil ? " in range" : "")")
        out.append(String(format: "Success rate: %.1f%% (%d/%d decided)",
                          rate, successes.count, decided.count))
        out.append("Outcomes:")
        for (outcome, count) in outcomeCounts.sorted(by: { $0.value > $1.value }) {
            out.append("  \(outcome): \(count)")
        }
        out.append("Latency (total press→action):")
        out.append(latencyLine("hot path      ", decided.filter { $0["path"] as? String == "hot" }))
        out.append(latencyLine("confirm path  ", decided.filter { $0["path"] as? String == "confirm" }))
        out.append(latencyLine("other paths   ", decided.filter {
            let p = $0["path"] as? String ?? ""
            return p != "hot" && p != "confirm"
        }))
        out.append(latencyLine("same-Space    ", decided.filter { ($0["crossed_space"] as? Bool) == false }))
        out.append(latencyLine("cross-Space   ", decided.filter { ($0["crossed_space"] as? Bool) == true }))

        let failures = records.filter {
            let o = $0["outcome"] as? String ?? ""
            return !successOutcomes.contains(o) && !undecidedOutcomes.contains(o)
        }
        if !failures.isEmpty {
            out.append("Last \(min(10, failures.count)) non-ok records:")
            for r in failures.suffix(10) {
                let ts = r["ts"] as? String ?? "?"
                let cmd = r["cmd"] as? String ?? "?"
                let app = r["app"] as? String ?? "-"
                let o = r["outcome"] as? String ?? "?"
                let d = r["detail"] as? String ?? ""
                out.append("  \(ts) \(cmd) \(app): \(o)\(d.isEmpty ? "" : " — \(d)")")
            }
        }
        return out.joined(separator: "\n")
    }
}
