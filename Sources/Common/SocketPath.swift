// Sources/Common/SocketPath.swift
import Foundation

enum SocketPath {
    static var stateDir: String {
        let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? NSHomeDirectory() + "/.local/state"
        return xdg + "/appfocus"
    }

    static var socketPath: String {
        return stateDir + "/appfocusd.sock"
    }

    /// Create a sockaddr_un from a path string.
    static func makeUnixAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }
        return addr
    }

    /// Connect to a Unix domain socket. Returns fd on success, -1 on failure.
    static func connectUnix(path: String) -> Int32 {
        guard var addr = makeUnixAddress(path: path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// Bind a Unix domain socket. Returns listening fd on success, -1 on failure.
    static func bindUnix(path: String, backlog: Int32 = 5) -> Int32 {
        guard var addr = makeUnixAddress(path: path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return -1
        }
        guard listen(fd, backlog) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }
}
