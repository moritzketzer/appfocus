// Tests/Unit/TelemetryStatsTests.swift
import Foundation
import Testing

private func line(outcome: String, path: String = "hot", total: Int? = nil,
                  crossed: Bool = false, ts: String = "2026-08-15T12:00:00.000Z",
                  detail: String? = nil) -> String {
    var obj: [String: Any] = ["ts": ts, "cmd": "jump", "app": "Safari",
                              "path": path, "outcome": outcome,
                              "crossed_space": crossed]
    if let total = total { obj["total_ms"] = total }
    if let detail = detail { obj["detail"] = detail }
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}

@Suite("TelemetryStats")
struct TelemetryStatsTests {

    @Test func successRateCountsOnlyDecidedCommands() {
        let out = TelemetryStats.aggregate(lines: [
            line(outcome: "ok", total: 100),
            line(outcome: "ok", total: 120),
            line(outcome: "wrong-window", total: 200),
            line(outcome: "superseded"),         // excluded from denominator
            line(outcome: "unverified-burst"),   // excluded
        ])
        #expect(out.contains("66.7% (2/3 decided)"))
    }

    @Test func latencySplitsByPathAndSpaceCrossing() {
        let out = TelemetryStats.aggregate(lines: [
            line(outcome: "ok", path: "hot", total: 100, crossed: false),
            line(outcome: "ok", path: "hot", total: 300, crossed: true),
            line(outcome: "ok", path: "confirm", total: 500, crossed: false),
        ])
        #expect(out.contains("hot path"))
        #expect(out.contains("confirm path"))
        #expect(out.contains("cross-Space   : n=1"))
        #expect(out.contains("same-Space    : n=2"))
    }

    @Test func sinceFiltersOldRecords() {
        let out = TelemetryStats.aggregate(
            lines: [
                line(outcome: "ok", total: 100, ts: "2026-08-15T10:00:00.000Z"),
                line(outcome: "ok", total: 100, ts: "2026-08-15T12:30:00.000Z"),
            ],
            since: ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z"))
        #expect(out.contains("1 records"))
    }

    @Test func failuresAreListedWithDetail() {
        let out = TelemetryStats.aggregate(lines: [
            line(outcome: "ok", total: 90),
            line(outcome: "invisible", total: 250, detail: "space=1"),
        ])
        #expect(out.contains("invisible — space=1")
            || out.contains("invisible: 1"))
        #expect(out.contains("non-ok"))
    }

    @Test func nativePathsRemainDecidedSuccesses() {
        let out = TelemetryStats.aggregate(lines: [
            line(outcome: "ok-app", path: "native-bundle", total: 80),
            line(outcome: "ok-app", path: "legacy-name", total: 90),
            line(outcome: "ok-app", path: "native-axless", total: 100),
        ])
        #expect(out.contains("100.0% (3/3 decided)"))
        #expect(out.contains("other paths   : n=3"))
    }

    @Test func parseSinceHandlesUnits() {
        #expect(TelemetryStats.parseSince("30m") == 1800)
        #expect(TelemetryStats.parseSince("2h") == 7200)
        #expect(TelemetryStats.parseSince("1d") == 86400)
        #expect(TelemetryStats.parseSince("bogus") == nil)
    }

    @Test func emptyInputSaysSo() {
        #expect(TelemetryStats.aggregate(lines: []).contains("No telemetry"))
    }
}
