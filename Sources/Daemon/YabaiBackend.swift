// Sources/Daemon/YabaiBackend.swift
import Foundation

final class YabaiBackend: WindowBackend {
    private let yabaiPath: String
    private let queue = DispatchQueue(label: "appfocus.yabai", attributes: .concurrent)

    /// Hard ceiling on how long a single `yabai` invocation may run. Without
    /// this, a yabai call that never exits leaks its child process forever —
    /// this is what let ~2553 stuck `yabai -m query` processes pile up in
    /// production over a few days of uptime.
    private static let processTimeout: TimeInterval = 3.0
    private static let killEscalationDelay: TimeInterval = 1.0

    init(yabaiPath: String) {
        self.yabaiPath = yabaiPath
    }

    func queryAllWindows(completion: @escaping ([WindowInfo]) -> Void) {
        // yabai has no --app filter; query all windows and filter client-side
        runYabai(["-m", "query", "--windows"]) { data in
            guard let data = data else {
                completion([])
                return
            }
            let json: [[String: Any]]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    Log.debug("queryAllWindows: unexpected JSON structure")
                    completion([])
                    return
                }
                json = parsed
            } catch {
                Log.debug("queryAllWindows: JSON parse failed: \(error)")
                completion([])
                return
            }
            let windows = json.compactMap { WindowInfo.from(yabaiDict: $0) }
                .filter { !$0.isMinimized && $0.isStandardWindow }
            completion(windows)
        }
    }

    func focusedWindow(completion: @escaping (WindowInfo?) -> Void) {
        runYabai(["-m", "query", "--windows", "--window"]) { data in
            guard let data = data else {
                completion(nil)
                return
            }
            let dict: [String: Any]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Log.debug("focusedWindow: unexpected JSON structure")
                    completion(nil)
                    return
                }
                dict = parsed
            } catch {
                Log.debug("focusedWindow: JSON parse failed: \(error)")
                completion(nil)
                return
            }
            completion(WindowInfo.from(yabaiDict: dict))
        }
    }

    func focusWindow(id: Int, completion: @escaping (Bool) -> Void) {
        runYabai(["-m", "window", "--focus", String(id)]) { data in
            completion(data != nil)
        }
    }

    func focusSpace(index: Int, completion: @escaping (Bool) -> Void) {
        runYabai(["-m", "space", "--focus", String(index)]) { data in
            completion(data != nil)
        }
    }

    private func runYabai(_ args: [String], completion: @escaping (Data?) -> Void) {
        queue.async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: self.yabaiPath)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            // Both the termination handler and the timeout below can race
            // to complete — this ensures exactly one of them wins.
            let finishLock = NSLock()
            var finished = false
            let finish: (Data?) -> Void = { data in
                finishLock.lock()
                let shouldRun = !finished
                finished = true
                finishLock.unlock()
                guard shouldRun else { return }
                completion(data)
            }

            do {
                try process.run()
            } catch {
                Log.error("yabai exec failed: \(error)")
                finish(nil)
                return
            }

            // Drain the pipe CONCURRENTLY with the running process. Reading only
            // after the process exits (the old terminationHandler approach)
            // deadlocks on any output larger than the ~16KB OS pipe buffer:
            // yabai blocks on write, never exits, the timeout below kills it,
            // and the query returns nil — surfacing as "running but no windows"
            // for every app once the desktop has enough windows (a full
            // `--windows` dump is ~20KB). Draining on a background queue lets
            // yabai finish writing and exit.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    finish(data)
                } else {
                    Log.debug("yabai \(args.joined(separator: " ")) exited \(process.terminationStatus)")
                    finish(nil)
                }
            }

            self.queue.asyncAfter(deadline: .now() + Self.processTimeout) {
                guard process.isRunning else { return }
                Log.debug("yabai \(args.joined(separator: " ")) timed out after \(Self.processTimeout)s, terminating")
                process.terminate()

                self.queue.asyncAfter(deadline: .now() + Self.killEscalationDelay) {
                    if process.isRunning {
                        Log.debug("yabai \(args.joined(separator: " ")) ignored SIGTERM, sending SIGKILL")
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                finish(nil)
            }
        }
    }
}
