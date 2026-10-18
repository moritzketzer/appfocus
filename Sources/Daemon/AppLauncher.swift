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
                completion(Self.legacyNameResult(result, appName: appName))
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
            completion(Self.nativeBundleResult(
                result, appName: appName,
                bundleIdentifier: bundleIdentifier))
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
            completion(Self.reopenResult(result, appName: appName))
        }
    }

    /// The `open -a` completion shape.
    private static func legacyNameResult(
        _ result: Result<Int32, Error>,
        appName: String
    ) -> ApplicationActionResult {
        switch result {
        case .success(let status):
            if status == 0 {
                Log.info("Activated \(appName) by name")
            } else {
                Log.error("open -a \(appName) failed (exit \(status))")
            }
            return exitStatusResult(status, path: .legacyName,
                                    tool: "open -a")
        case .failure(let error):
            Log.error("open -a \(appName) failed: \(error)")
            return errorResult(error, path: .legacyName)
        }
    }

    /// The native bundle-identifier completion shape.
    private static func nativeBundleResult(
        _ result: Result<ApplicationIdentity, Error>,
        appName: String,
        bundleIdentifier: String
    ) -> ApplicationActionResult {
        switch result {
        case .success:
            Log.info("Activated \(appName) (\(bundleIdentifier))")
            return ApplicationActionResult(
                success: true,
                path: .nativeBundle,
                bundleIdentifier: bundleIdentifier,
                detail: nil)
        case .failure(let error):
            Log.error("activate: \(bundleIdentifier) failed: \(error)")
            return errorResult(error, path: .nativeBundle,
                               bundleIdentifier: bundleIdentifier)
        }
    }

    /// The `osascript` reopen completion shape.
    private static func reopenResult(
        _ result: Result<Int32, Error>,
        appName: String
    ) -> ApplicationActionResult {
        switch result {
        case .success(let status):
            if status != 0 {
                Log.error("osascript reopen failed for \(appName) (exit \(status))")
            }
            return exitStatusResult(status, path: .reopen,
                                    tool: "osascript")
        case .failure(let error):
            Log.error("osascript reopen failed for \(appName): \(error)")
            return errorResult(error, path: .reopen)
        }
    }

    /// A process-backed activation: exit 0 is success, any other status
    /// carries `tool` and the status as the detail.
    private static func exitStatusResult(
        _ status: Int32,
        path: ApplicationActionPath,
        tool: String
    ) -> ApplicationActionResult {
        let success = status == 0
        return ApplicationActionResult(
            success: success,
            path: path,
            bundleIdentifier: nil,
            detail: success ? nil : "\(tool) failed (exit \(status))")
    }

    /// A spawn or AppKit failure: no exit status, the error describes itself.
    private static func errorResult(
        _ error: Error,
        path: ApplicationActionPath,
        bundleIdentifier: String? = nil
    ) -> ApplicationActionResult {
        ApplicationActionResult(
            success: false,
            path: path,
            bundleIdentifier: bundleIdentifier,
            detail: error.localizedDescription)
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
