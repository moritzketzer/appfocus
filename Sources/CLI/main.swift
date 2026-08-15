// Sources/CLI/main.swift
import Foundation

// Parse command line args into a Command
let args = Array(CommandLine.arguments.dropFirst())

guard !args.isEmpty else {
    FileHandle.standardError.write(
        Data("Usage: appfocus <jump APP|next|prev|status|stats [--since 2h]>\n".utf8))
    exit(1)
}

// `stats` is entirely client-side: aggregate the daemon's telemetry JSONL.
if args[0] == "stats" {
    var since: Date?
    if let idx = args.firstIndex(of: "--since"), idx + 1 < args.count {
        guard let interval = TelemetryStats.parseSince(args[idx + 1]) else {
            FileHandle.standardError.write(
                Data("Invalid --since (use e.g. 30m, 2h, 1d)\n".utf8))
            exit(1)
        }
        since = Date().addingTimeInterval(-interval)
    }
    let sink = SocketPath.stateDir + "/telemetry.jsonl"
    var lines: [String] = []
    for path in [sink + ".1", sink] {
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            lines.append(contentsOf: content.split(separator: "\n").map(String.init))
        }
    }
    print(TelemetryStats.aggregate(lines: lines, since: since))
    exit(0)
}

let line = args.joined(separator: " ")
guard let cmd = Command.parse(line) else {
    FileHandle.standardError.write(
        Data("Unknown command: \(line)\n".utf8))
    exit(1)
}

// Connect to daemon socket
let fd = SocketPath.connectUnix(path: SocketPath.socketPath)
guard fd >= 0 else {
    FileHandle.standardError.write(
        Data("Cannot connect to appfocusd (is it running?)\n".utf8))
    exit(1)
}

// Send command
let msg = cmd.serialize()
let bytes = Array(msg.utf8)
_ = write(fd, bytes, bytes.count)

// For status: read response until EOF
if case .status = cmd {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        data.append(contentsOf: buffer[0..<n])
    }
    if let response = String(data: data, encoding: .utf8) {
        print(response)
    }
}

close(fd)
