// Sources/CLI/main.swift
import Foundation

// Parse command line args into a Command
let args = Array(CommandLine.arguments.dropFirst())

guard !args.isEmpty else {
    FileHandle.standardError.write(
        Data("Usage: appfocus <jump APP|next|prev|status>\n".utf8))
    exit(1)
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
