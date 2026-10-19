// Sources/Daemon/KanataCommandSource.swift
import Foundation

final class KanataCommandSource: CommandSource {
    private let host: String
    private let port: Int
    private let commandHandler: (Command) -> Void
    private let queue = DispatchQueue(label: "appfocus.kanata")
    private var fd: Int32 = -1
    private var running = false
    private var currentRetryInterval: Double = 2.0
    private static let maxBackoff: Double = 30.0

    init(host: String = "127.0.0.1", port: Int, commandHandler: @escaping (Command) -> Void) {
        self.host = host
        self.port = port
        self.commandHandler = commandHandler
    }

    func start() throws {
        running = true
        queue.async { self.connectLoop() }
    }

    func stop() {
        running = false
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    // MARK: - Message parsing (static for testability)

    static func parseMessage(_ line: String) -> Command? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let push = json["MessagePush"] as? [String: Any]
        else { return nil }

        // push-msg sends message as a string for literals, or as a
        // single-element array when the argument came from concat/template.
        let message: String
        if let str = push["message"] as? String {
            message = str
        } else if let arr = push["message"] as? [String], let first = arr.first {
            message = first
        } else {
            return nil
        }
        return Command.parse(message)
    }

    /// Assemble one socket read into newline-complete messages plus the tail
    /// to carry into the next read. `incomplete` is the previous read's tail.
    /// Both stay at BYTE level: a read boundary can fall inside a multi-byte
    /// UTF-8 character, which a String tail cannot hold — decoding the chunk
    /// as one unit dropped that whole read (the press). Each complete line is
    /// decoded on its own, so undecodable bytes cost exactly their own line.
    static func assembleLines(
        chunkBytes: ArraySlice<UInt8>, incomplete: [UInt8]
    ) -> (complete: [String], incomplete: [UInt8]) {
        let stream = incomplete + chunkBytes
        let lines = stream.split(separator: 0x0A, omittingEmptySubsequences: false)

        var complete: [String] = []
        for line in lines.dropLast() {
            guard let decoded = String(bytes: line, encoding: .utf8) else {
                Log.debug("kanata: dropped \(line.count)-byte line, not valid UTF-8")
                continue
            }
            complete.append(decoded)
        }

        // Last element may be incomplete — save as incompleteMessage
        return (complete, lines.last.map(Array.init) ?? [])
    }

    // MARK: - Connection

    private func connectLoop() {
        while running {
            if tryConnect() {
                currentRetryInterval = 2.0
                readMessages()
            }
            guard running else { return }
            Log.info("kanata: reconnecting in \(Int(currentRetryInterval))s")
            Thread.sleep(forTimeInterval: currentRetryInterval)
            currentRetryInterval = min(currentRetryInterval * 2, Self.maxBackoff)
        }
    }

    private func tryConnect() -> Bool {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            close(fd)
            fd = -1
            Log.debug("kanata: connect to \(host):\(port) failed")
            return false
        }

        Log.info("kanata: connected to \(host):\(port)")
        return true
    }

    private func readMessages() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var incompleteMessage: [UInt8] = []

        while running {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 {
                Log.info("kanata: connection closed")
                close(fd)
                fd = -1
                return
            }

            let assembled = Self.assembleLines(chunkBytes: buffer[0..<n],
                                               incomplete: incompleteMessage)
            incompleteMessage = assembled.incomplete

            for line in assembled.complete {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let cmd = Self.parseMessage(trimmed) {
                    Log.debug("kanata: received \(cmd)")
                    commandHandler(cmd)
                }
            }
        }
    }
}
