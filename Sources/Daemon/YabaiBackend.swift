// Sources/Daemon/YabaiBackend.swift
import Foundation

final class YabaiBackend: WindowBackend {
    private let yabaiPath: String
    private let queue = DispatchQueue(label: "appfocus.yabai", attributes: .concurrent)

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

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    completion(pipe.fileHandleForReading.readDataToEndOfFile())
                } else {
                    Log.debug("yabai \(args.joined(separator: " ")) exited \(proc.terminationStatus)")
                    completion(nil)
                }
            }

            do {
                try process.run()
            } catch {
                Log.error("yabai exec failed: \(error)")
                completion(nil)
            }
        }
    }
}
