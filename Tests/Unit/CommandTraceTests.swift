// Tests/Unit/CommandTraceTests.swift
import Foundation
import Testing

private func parse(_ line: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
}

@Suite("CommandTrace")
struct CommandTraceTests {

    @Test func applicationTargetEncodesIdentity() {
        let trace = CommandTrace(command: "jump", app: "Passwords")
        trace.verificationTargetKind = .application
        trace.targetBundleIdentifier = "com.apple.Passwords"

        let obj = parse(trace.jsonLine())
        #expect(obj["target_kind"] as? String == "application")
        #expect(obj["target_bundle_id"] as? String == "com.apple.Passwords")
        #expect(obj["crossed_space"] == nil)
    }

    @Test func encodesCoreFieldsAndDurations() {
        let t0 = DispatchTime.now()
        let trace = CommandTrace(command: "jump", app: "Safari", receivedAt: t0)
        trace.path = "hot"
        trace.targetWindowId = 42
        trace.targetSpace = 2
        trace.crossedSpace = true
        trace.decidedAt = t0 + 0.010
        trace.actionedAt = t0 + 0.110
        trace.verifyMs = 350
        trace.outcome = "ok"

        let obj = parse(trace.jsonLine())
        #expect(obj["cmd"] as? String == "jump")
        #expect(obj["app"] as? String == "Safari")
        #expect(obj["path"] as? String == "hot")
        #expect(obj["target_id"] as? Int == 42)
        #expect(obj["target_space"] as? Int == 2)
        #expect(obj["crossed_space"] as? Bool == true)
        #expect(obj["outcome"] as? String == "ok")
        #expect(obj["verify_ms"] as? Int == 350)
        let decide = obj["decide_ms"] as? Int ?? -1
        let act = obj["act_ms"] as? Int ?? -1
        let total = obj["total_ms"] as? Int ?? -1
        #expect(decide >= 9 && decide <= 12)
        #expect(act >= 99 && act <= 102)
        #expect(total >= 109 && total <= 113)
        #expect((obj["ts"] as? String)?.contains("T") == true)
    }

    @Test func omitsAbsentPhases() {
        let trace = CommandTrace(command: "next", app: nil)
        trace.outcome = "dropped-backoff"

        let obj = parse(trace.jsonLine())
        #expect(obj["app"] == nil)
        #expect(obj["decide_ms"] == nil)
        #expect(obj["act_ms"] == nil)
        #expect(obj["total_ms"] == nil)
        #expect(obj["verify_ms"] == nil)
        #expect(obj["detail"] == nil)
        #expect(obj["outcome"] as? String == "dropped-backoff")
    }

    @Test func detailIsCarried() {
        let trace = CommandTrace(command: "jump", app: "X")
        trace.outcome = "wrong-window"
        trace.detail = "actual=cmux/678 space=3"
        let obj = parse(trace.jsonLine())
        #expect(obj["detail"] as? String == "actual=cmux/678 space=3")
    }
}
