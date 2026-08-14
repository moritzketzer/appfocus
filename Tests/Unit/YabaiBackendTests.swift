// Tests/Unit/YabaiBackendTests.swift
import Foundation
import Testing

private let hangingYabaiPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../Fixtures/hanging-yabai.sh")
    .standardizedFileURL.path

private let largeYabaiPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../Fixtures/large-yabai.sh")
    .standardizedFileURL.path

/// True if a fixture instance spawned from THIS checkout is still alive.
/// Matching on the absolute fixture path (not the bare script name) keeps
/// orphans from another checkout/worktree from contaminating this run.
private func isFixtureProcessStillRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", hangingYabaiPath]
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Kill fixture orphans left by a previous crashed/killed test run. Without
/// this, one bad run poisons every later run: the stale process satisfies
/// pgrep forever and the kill-escalation test can never pass again.
private func reapStaleFixtureProcesses() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-f", hangingYabaiPath]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

/// Poll until the fixture process disappears or the deadline passes.
/// SIGTERM lands at processTimeout and SIGKILL escalates 1s later; under
/// parallel-suite load those timers drift, so a single fixed-delay check
/// is a race, not a verification.
private func waitForFixtureProcessToDie(within seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !isFixtureProcessStillRunning() { return true }
        usleep(200_000)
    }
    return !isFixtureProcessStillRunning()
}

// Serialized: both hang tests spawn the same fixture script and verify its
// death via pgrep, so running them concurrently makes each test see the
// other's still-alive fixture. The 10s completion budget leaves headroom
// over the backend's 3s process timeout: the fuzz test floods GCD with
// watchdog timers, and with only 2s slack the timeout timer intermittently
// fired after the old 5s test deadline (observed 2026-08-14).
@Suite("YabaiBackend", .serialized)
struct YabaiBackendTests {

    @Test("focusedWindow completes instead of hanging forever when yabai never exits")
    func focusedWindowTimesOutOnHungProcess() {
        reapStaleFixtureProcesses()
        let backend = YabaiBackend(yabaiPath: hangingYabaiPath)
        let sem = DispatchSemaphore(value: 0)

        backend.focusedWindow { _ in
            sem.signal()
        }

        // A regression here means the completion never fires and this
        // wait times out: the underlying process leaked exactly like the
        // 2553 stuck `yabai -m query` processes found piling up in prod.
        let outcome = sem.wait(timeout: .now() + 10)
        #expect(outcome == .success, "focusedWindow must time out and complete, not hang forever")
        _ = waitForFixtureProcessToDie(within: 5)
    }

    @Test("hung yabai process is killed, not left running, after the timeout fires")
    func hungProcessIsKilledAfterTimeout() {
        reapStaleFixtureProcesses()
        let backend = YabaiBackend(yabaiPath: hangingYabaiPath)
        let sem = DispatchSemaphore(value: 0)

        backend.focusedWindow { _ in
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 10)
        // The completion fires at the process timeout, BEFORE the kill
        // lands: SIGTERM is sent at that instant and SIGKILL escalates 1s
        // later. Poll instead of asserting at a fixed delay — this is the
        // exact leak that piled up ~2553 stuck `yabai` processes in prod.
        #expect(waitForFixtureProcessToDie(within: 5),
                "hung yabai child process should be killed, not orphaned")
    }

    @Test("queryAllWindows returns every window when output exceeds the OS pipe buffer")
    func queryAllWindowsDoesNotDeadlockOnLargeOutput() {
        // The large fixture emits ~20KB of JSON, past the ~16KB pipe buffer.
        // A reader that drains only after the process exits deadlocks: yabai
        // blocks on write, never exits, the timeout kills it, and the query
        // returns [] — the "running but no windows" bug for every app once the
        // desktop has enough windows. This asserts the pipe is drained
        // concurrently so all windows come back.
        let backend = YabaiBackend(yabaiPath: largeYabaiPath)
        let sem = DispatchSemaphore(value: 0)
        var count = -1

        backend.queryAllWindows { windows in
            count = windows?.count ?? -2   // -2 = query reported failure
            sem.signal()
        }

        let outcome = sem.wait(timeout: .now() + 10)
        #expect(outcome == .success, "queryAllWindows must complete, not deadlock on large output")
        #expect(count == 60, "all 60 windows must be parsed; a deadlock kills the query and yields 0")
    }
}
