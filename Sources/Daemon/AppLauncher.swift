// Sources/Daemon/AppLauncher.swift
import AppKit
import Foundation

protocol AppLauncher {
    func launch(appName: String, completion: @escaping (Bool) -> Void)
    func reopen(appName: String, strategy: ReopenStrategy, completion: @escaping () -> Void)
}

final class DefaultAppLauncher: AppLauncher {
    private let queue = DispatchQueue(label: "appfocus.launcher")

    func launch(appName: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", appName]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { proc in
                let ok = proc.terminationStatus == 0
                if ok { Log.info("Launched \(appName)") }
                else { Log.error("open -a \(appName) failed (exit \(proc.terminationStatus))") }
                completion(ok)
            }

            do {
                try process.run()
            } catch {
                Log.error("open -a failed: \(error)")
                completion(false)
            }
        }
    }

    func reopen(appName: String, strategy: ReopenStrategy, completion: @escaping () -> Void) {
        let script: String
        switch strategy {
        case .reopen:
            script = "tell application \"\(appName)\" to reopen"
        case .makeWindow:
            // Finder-specific: create a new Finder window
            script = "tell application \"Finder\" to make new Finder window"
        case .makeDocument:
            script = "tell application \"\(appName)\" to make new document"
        }

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { _ in
                completion()
            }

            do {
                try process.run()
            } catch {
                Log.error("osascript reopen failed for \(appName): \(error)")
                completion()
            }
        }
    }
}
