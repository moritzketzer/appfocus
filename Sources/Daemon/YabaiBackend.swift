// Sources/Daemon/YabaiBackend.swift
import Foundation

final class YabaiBackend: WindowBackend {
    private let yabaiPath: String
    private let queue = DispatchQueue(label: "appfocus.yabai", attributes: .concurrent)

    /// Hard ceiling on how long a single `yabai` invocation may run. Without
    /// this, a yabai call that never exits leaks its child process forever —
    /// this is what let ~2553 stuck `yabai -m query` processes pile up in
    /// production over a few days of uptime. Instance-mutable for tests.
    var processTimeout: TimeInterval = 3.0
    /// Grace period between SIGTERM and SIGKILL for a timed-out invocation.
    /// Instance-mutable for tests.
    var killEscalationDelay: TimeInterval = 1.0

    init(yabaiPath: String) {
        self.yabaiPath = yabaiPath
    }

    func queryAllWindows(completion: @escaping ([WindowInfo]?) -> Void) {
        // yabai has no --app filter; query all windows and filter client-side
        runYabai(["-m", "query", "--windows"]) { data in
            guard let json = Self.decode(data, as: [[String: Any]].self,
                                         query: "queryAllWindows") else {
                completion(nil)   // failed/timed-out query, NOT "no windows"
                return
            }
            // Return the unfiltered snapshot: the WindowModel needs every
            // window (the focused one may be a sticky dialog the logic must
            // guard against). Consumers re-filter with isStandardWindow.
            let windows = json.compactMap { WindowInfo.from(yabaiDict: $0) }
            completion(windows)
        }
    }

    func focusedWindow(completion: @escaping (WindowInfo?) -> Void) {
        runYabai(["-m", "query", "--windows", "--window"]) { data in
            guard let dict = Self.decode(data, as: [String: Any].self,
                                         query: "focusedWindow") else {
                completion(nil)
                return
            }
            completion(WindowInfo.from(yabaiDict: dict))
        }
    }

    /// Decode one yabai query payload. `nil` covers a failed or timed-out
    /// query, an unexpected JSON structure, and a parse error alike — callers
    /// must never read it as "no windows".
    private static func decode<T>(_ data: Data?, as type: T.Type,
                                  query: String) -> T? {
        guard let data = data else { return nil }
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? T else {
                Log.debug("\(query): unexpected JSON structure")
                return nil
            }
            return parsed
        } catch {
            Log.debug("\(query): JSON parse failed: \(error)")
            return nil
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
        let enqueued = DispatchTime.now()
        // Read the mutable timeouts once, on the calling thread: the blocks
        // below run on background queues and must not race a test's setup.
        let timeout = processTimeout
        let killDelay = killEscalationDelay
        queue.async {
            let started = DispatchTime.now()
            let pipe = Pipe()
            let process = self.makeProcess(args: args, pipe: pipe)

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
                // Per-call queue-wait + run time (debug only). yabai is the
                // flaky dependency; these timings are how a hang is diagnosed.
                let now = DispatchTime.now()
                let waitMs = Double(started.uptimeNanoseconds - enqueued.uptimeNanoseconds) / 1_000_000
                let runMs = Double(now.uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                Log.debug(String(format: "yabai %@ -> wait=%.0fms run=%.0fms %@",
                                 args.joined(separator: " "), waitMs, runMs,
                                 data == nil ? "FAIL/nil" : "ok(\(data!.count)B)"))
                completion(data)
            }

            do {
                try process.run()
            } catch {
                Log.error("yabai exec failed: \(error)")
                finish(nil)
                return
            }

            self.startDrain(process: process, pipe: pipe, args: args,
                            finish: finish)

            self.scheduleTimeout(process: process, args: args,
                                 timeout: timeout, killDelay: killDelay,
                                 finish: finish)
        }
    }

    /// The child process for one invocation: stdout into `pipe`, stderr
    /// discarded. Runs on `queue`.
    private func makeProcess(args: [String], pipe: Pipe) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: yabaiPath)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Read the invocation's whole stdout on a background queue and complete
    /// through `finish`. Started from `queue`, runs off it.
    private func startDrain(process: Process, pipe: Pipe, args: [String],
                            finish: @escaping (Data?) -> Void) {
        // Drain the pipe CONCURRENTLY with the running process. Reading only
        // after the process exits (the old terminationHandler approach)
        // deadlocks on any output larger than the ~16KB OS pipe buffer:
        // yabai blocks on write, never exits, the timeout in
        // `scheduleTimeout` kills it, and the query returns nil — surfacing
        // as "running but no windows" for every app once the desktop has
        // enough windows (a full `--windows` dump is ~20KB). Draining on a
        // background queue lets yabai finish writing and exit.
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
    }

    /// Arm the hard ceiling: SIGTERM at `timeout`, SIGKILL `killDelay` later
    /// if the child ignores it, and complete the invocation as failed. Runs
    /// on `queue`, and schedules both escalations onto it.
    private func scheduleTimeout(process: Process, args: [String],
                                 timeout: TimeInterval,
                                 killDelay: TimeInterval,
                                 finish: @escaping (Data?) -> Void) {
        queue.asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            Log.debug("yabai \(args.joined(separator: " ")) timed out after \(timeout)s, terminating")
            process.terminate()

            self.queue.asyncAfter(deadline: .now() + killDelay) {
                if process.isRunning {
                    Log.debug("yabai \(args.joined(separator: " ")) ignored SIGTERM, sending SIGKILL")
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            finish(nil)
        }
    }
}
