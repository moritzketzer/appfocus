// Tests/Unit/SocketCommandSourceTests.swift
import Foundation
import Testing

// `sockaddr_un.sun_path` holds ~104 bytes and the process temp directory can
// eat most of that on its own, so these tests bind under /tmp and remove the
// directory they made.
private func makeSocketDir() throws -> String {
    var template = Array("/tmp/appfocus-sockXXXXXX".utf8CString)
    let made = template.withUnsafeMutableBufferPointer { buf in
        mkdtemp(buf.baseAddress!) != nil
    }
    try #require(made, "mkdtemp under /tmp failed: \(String(cString: strerror(errno)))")
    let bytes = template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func removeSocketDir(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
}

private func makeSource(
    path: String,
    commandHandler: @escaping (Command) -> Void = { _ in },
    statusHandler: @escaping (Int32) -> Void = { _ in }
) -> SocketCommandSource {
    SocketCommandSource(path: path,
                        commandHandler: commandHandler,
                        statusHandler: statusHandler)
}

/// Write one wire line through a real client connection, like the CLI does.
private func sendLine(_ line: String, to path: String) -> Bool {
    let fd = SocketPath.connectUnix(path: path)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let bytes = Array(line.utf8)
    return bytes.withUnsafeBufferPointer { buf in
        write(fd, buf.baseAddress, buf.count) == buf.count
    }
}

@Suite("SocketCommandSource")
struct SocketCommandSourceTests {

    @Test func startBindsAndDeliversACommand() throws {
        let dir = try makeSocketDir()
        defer { removeSocketDir(dir) }
        let path = dir + "/d.sock"
        let delivered = DispatchSemaphore(value: 0)
        var seen: Command?

        let source = makeSource(path: path, commandHandler: { cmd in
            seen = cmd
            delivered.signal()
        })
        try source.start()
        defer { source.stop() }

        #expect(sendLine("jump Safari\n", to: path))
        // Generous budget: the accept and the read run on separate queues, so
        // the wait length must not be the thing under test.
        #expect(delivered.wait(timeout: .now() + 10) == .success)
        #expect(seen == .jump(appName: "Safari"))
    }

    @Test func statusRoutesToTheStatusHandler() throws {
        let dir = try makeSocketDir()
        defer { removeSocketDir(dir) }
        let path = dir + "/d.sock"
        let asked = DispatchSemaphore(value: 0)

        let source = makeSource(
            path: path,
            commandHandler: { cmd in
                Issue.record("status must not reach the command handler, got \(cmd)")
            },
            statusHandler: { _ in asked.signal() })
        try source.start()
        defer { source.stop() }

        #expect(sendLine("status\n", to: path))
        #expect(asked.wait(timeout: .now() + 10) == .success)
    }

    // A crashed daemon leaves its socket file behind with nobody listening.
    // Refusing to start on that file would need a manual `rm` after every
    // crash, so an unconnectable socket is removed and rebound.
    @Test func staleSocketFileIsReplaced() throws {
        let dir = try makeSocketDir()
        defer { removeSocketDir(dir) }
        let path = dir + "/d.sock"
        let orphan = SocketPath.bindUnix(path: path)
        #expect(orphan >= 0)
        close(orphan)
        #expect(FileManager.default.fileExists(atPath: path))

        let delivered = DispatchSemaphore(value: 0)
        let source = makeSource(path: path,
                                commandHandler: { _ in delivered.signal() })
        try source.start()
        defer { source.stop() }

        #expect(sendLine("next\n", to: path))
        #expect(delivered.wait(timeout: .now() + 10) == .success)
    }

    // A LIVE socket is the opposite case: a second daemon must not steal the
    // path from the one that is still serving it.
    @Test func secondInstanceOnALiveSocketRefusesToStart() throws {
        let dir = try makeSocketDir()
        defer { removeSocketDir(dir) }
        let path = dir + "/d.sock"
        let first = makeSource(path: path)
        try first.start()
        defer { first.stop() }

        let second = makeSource(path: path)
        do {
            try second.start()
            second.stop()
            Issue.record("Expected alreadyRunning against a live socket")
        } catch AppFocusError.alreadyRunning {
            // expected
        } catch {
            Issue.record("Expected alreadyRunning, got \(error)")
        }
    }
}
