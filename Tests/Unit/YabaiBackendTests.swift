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

/// True if any `hanging-yabai.sh` fixture instance is still alive.
private func isFixtureProcessStillRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "hanging-yabai.sh"]
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

@Suite("YabaiBackend")
struct YabaiBackendTests {

    @Test("focusedWindow completes instead of hanging forever when yabai never exits")
    func focusedWindowTimesOutOnHungProcess() {
        let backend = YabaiBackend(yabaiPath: hangingYabaiPath)
        let sem = DispatchSemaphore(value: 0)

        backend.focusedWindow { _ in
            sem.signal()
        }

        // A regression here means the completion never fires and this
        // wait times out: the underlying process leaked exactly like the
        // 2553 stuck `yabai -m query` processes found piling up in prod.
        let outcome = sem.wait(timeout: .now() + 5)
        #expect(outcome == .success, "focusedWindow must time out and complete, not hang forever")
    }

    @Test("hung yabai process is killed, not left running, after the timeout fires")
    func hungProcessIsKilledAfterTimeout() {
        let backend = YabaiBackend(yabaiPath: hangingYabaiPath)
        let sem = DispatchSemaphore(value: 0)

        backend.focusedWindow { _ in
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + 5)
        // Give the kill signal a moment to land, then confirm no orphaned
        // instance of the fixture script is still running — this is the
        // exact leak that piled up ~2553 stuck `yabai` processes in prod.
        usleep(300_000)
        #expect(!isFixtureProcessStillRunning(), "hung yabai child process should be killed, not orphaned")
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
            count = windows.count
            sem.signal()
        }

        let outcome = sem.wait(timeout: .now() + 5)
        #expect(outcome == .success, "queryAllWindows must complete, not deadlock on large output")
        #expect(count == 60, "all 60 windows must be parsed; a deadlock kills the query and yields 0")
    }
}
