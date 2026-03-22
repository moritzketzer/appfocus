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
        var incompleteMessage = ""

        while running {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 {
                Log.info("kanata: connection closed")
                close(fd)
                fd = -1
                return
            }

            let chunk = incompleteMessage + (String(bytes: buffer[0..<n], encoding: .utf8) ?? "")
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)

            // Last element may be incomplete — save as incompleteMessage
            incompleteMessage = String(lines.last ?? "")
            let completeLines = lines.dropLast()

            for line in completeLines {
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
