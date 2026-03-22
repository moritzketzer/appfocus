// Sources/Daemon/SocketCommandSource.swift
import Foundation

final class SocketCommandSource: CommandSource {
    private let path: String
    private var listenFd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "appfocus.socket")
    private let commandHandler: (Command) -> Void
    private let statusHandler: (Int32) -> Void

    init(path: String,
         commandHandler: @escaping (Command) -> Void,
         statusHandler: @escaping (Int32) -> Void) {
        self.path = path
        self.commandHandler = commandHandler
        self.statusHandler = statusHandler
    }

    func start() throws {
        // Clean up stale socket
        try cleanupStaleSocket()

        // Create, bind, and listen on Unix domain socket
        listenFd = SocketPath.bindUnix(path: path)
        guard listenFd >= 0 else {
            throw AppFocusError.socketBind
        }

        // Set up GCD dispatch source for accepting connections
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.listenFd, fd >= 0 { close(fd) }
            unlink(self?.path ?? "")
        }
        src.resume()
        source = src

        Log.info("Listening on \(path)")
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func acceptConnection() {
        let clientFd = accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }

        // Read command from client (non-blocking, on concurrent queue)
        DispatchQueue.global().async { [self] in
            defer { close(clientFd) }

            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = read(clientFd, &buffer, buffer.count)
            guard n > 0 else { return }

            let line = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
            guard let cmd = Command.parse(line) else {
                Log.error("Invalid command: \(line.trimmingCharacters(in: .newlines))")
                return
            }

            switch cmd {
            case .status:
                self.statusHandler(clientFd)
            default:
                self.commandHandler(cmd)
            }
        }
    }

    private func cleanupStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let testFd = SocketPath.connectUnix(path: path)
        if testFd >= 0 {
            close(testFd)
            throw AppFocusError.alreadyRunning
        }
        Log.info("Removing stale socket at \(path)")
        unlink(path)
    }
}

enum AppFocusError: Error, CustomStringConvertible {
    case socketBind
    case alreadyRunning

    var description: String {
        switch self {
        case .socketBind: return "Failed to bind Unix socket"
        case .alreadyRunning: return "Another appfocusd is already running"
        }
    }
}
