import Foundation

enum ApplicationActionPath: String, Equatable {
    case nativeBundle = "native-bundle"
    case legacyName = "legacy-name"
    case reopen
}

struct ApplicationActionResult: Equatable {
    let success: Bool
    let path: ApplicationActionPath
    let bundleIdentifier: String?
    let detail: String?
}

typealias ApplicationCommandRunner = (
    _ executablePath: String,
    _ arguments: [String],
    _ completion: @escaping (Result<Int32, Error>) -> Void
) -> Void

protocol AppLauncher {
    func activate(
        appName: String,
        bundleIdentifier: String?,
        completion: @escaping (ApplicationActionResult) -> Void
    )
    func reopen(
        appName: String,
        strategy: ReopenStrategy,
        completion: @escaping (ApplicationActionResult) -> Void
    )

    // Temporary compatibility surface while ActivationLogic migrates to the
    // result-bearing operations in this change.
    func launch(appName: String, completion: @escaping (Bool) -> Void)
    func activate(appName: String, completion: @escaping () -> Void)
    func reopen(appName: String, strategy: ReopenStrategy,
                completion: @escaping () -> Void)
}

final class DefaultAppLauncher: AppLauncher {
    private let workspace: ApplicationWorkspace
    private let runCommand: ApplicationCommandRunner

    init(
        workspace: ApplicationWorkspace = SystemApplicationWorkspace(),
        runCommand: @escaping ApplicationCommandRunner = DefaultAppLauncher.runProcess
    ) {
        self.workspace = workspace
        self.runCommand = runCommand
    }

    func activate(
        appName: String,
        bundleIdentifier: String?,
        completion: @escaping (ApplicationActionResult) -> Void
    ) {
        guard let bundleIdentifier else {
            runCommand("/usr/bin/open", ["-a", appName]) { result in
                switch result {
                case .success(let status):
                    let success = status == 0
                    if success {
                        Log.info("Activated \(appName) by name")
                    } else {
                        Log.error("open -a \(appName) failed (exit \(status))")
                    }
                    completion(ApplicationActionResult(
                        success: success,
                        path: .legacyName,
                        bundleIdentifier: nil,
                        detail: success ? nil : "open -a failed (exit \(status))"))
                case .failure(let error):
                    Log.error("open -a \(appName) failed: \(error)")
                    completion(ApplicationActionResult(
                        success: false,
                        path: .legacyName,
                        bundleIdentifier: nil,
                        detail: error.localizedDescription))
                }
            }
            return
        }

        guard let url = workspace.applicationURL(
            bundleIdentifier: bundleIdentifier) else {
            let detail = "No application URL for bundle \(bundleIdentifier)"
            Log.error("activate: \(detail)")
            completion(ApplicationActionResult(
                success: false,
                path: .nativeBundle,
                bundleIdentifier: bundleIdentifier,
                detail: detail))
            return
        }

        workspace.openApplication(at: url, activates: true) { result in
            switch result {
            case .success:
                Log.info("Activated \(appName) (\(bundleIdentifier))")
                completion(ApplicationActionResult(
                    success: true,
                    path: .nativeBundle,
                    bundleIdentifier: bundleIdentifier,
                    detail: nil))
            case .failure(let error):
                Log.error("activate: \(bundleIdentifier) failed: \(error)")
                completion(ApplicationActionResult(
                    success: false,
                    path: .nativeBundle,
                    bundleIdentifier: bundleIdentifier,
                    detail: error.localizedDescription))
            }
        }
    }

    func reopen(
        appName: String,
        strategy: ReopenStrategy,
        completion: @escaping (ApplicationActionResult) -> Void
    ) {
        let script: String
        switch strategy {
        case .reopen:
            script = "tell application \"\(appName)\" to reopen"
        case .makeWindow:
            script = "tell application \"Finder\" to make new Finder window"
        case .makeDocument:
            script = "tell application \"\(appName)\" to make new document"
        }

        runCommand("/usr/bin/osascript", ["-e", script]) { result in
            switch result {
            case .success(let status):
                let success = status == 0
                if !success {
                    Log.error("osascript reopen failed for \(appName) (exit \(status))")
                }
                completion(ApplicationActionResult(
                    success: success,
                    path: .reopen,
                    bundleIdentifier: nil,
                    detail: success ? nil : "osascript failed (exit \(status))"))
            case .failure(let error):
                Log.error("osascript reopen failed for \(appName): \(error)")
                completion(ApplicationActionResult(
                    success: false,
                    path: .reopen,
                    bundleIdentifier: nil,
                    detail: error.localizedDescription))
            }
        }
    }

    func launch(appName: String, completion: @escaping (Bool) -> Void) {
        activate(appName: appName, bundleIdentifier: nil) {
            completion($0.success)
        }
    }

    func activate(appName: String, completion: @escaping () -> Void) {
        activate(appName: appName, bundleIdentifier: nil) { _ in completion() }
    }

    func reopen(appName: String, strategy: ReopenStrategy,
                completion: @escaping () -> Void) {
        reopen(appName: appName, strategy: strategy) {
            (_: ApplicationActionResult) in completion()
        }
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        completion: @escaping (Result<Int32, Error>) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { completion(.success($0.terminationStatus)) }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }
}
