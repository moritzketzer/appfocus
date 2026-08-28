import Foundation
import Testing

private struct CommandCall: Equatable {
    let executablePath: String
    let arguments: [String]

    init(_ executablePath: String, _ arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

private struct LauncherTestError: LocalizedError {
    var errorDescription: String? { "test open failure" }
}

private final class RecordingCommandRunner {
    var calls: [CommandCall] = []
    let result: Result<Int32, Error>

    init(exitStatus: Int32 = 0) {
        result = .success(exitStatus)
    }

    init(error: Error) {
        result = .failure(error)
    }

    func run(
        executablePath: String,
        arguments: [String],
        completion: @escaping (Result<Int32, Error>) -> Void
    ) {
        calls.append(CommandCall(executablePath, arguments))
        completion(result)
    }
}

@Suite("AppLauncher")
struct AppLauncherTests {

    @Test func configuredBundleUsesNativeActivation() {
        let workspace = MockApplicationWorkspace()
        let url = URL(fileURLWithPath: "/Applications/Passwords.app")
        workspace.urls["com.apple.Passwords"] = url
        workspace.openResult = .success(ApplicationIdentity(
            bundleIdentifier: "com.apple.Passwords", localizedName: "Passwords"))
        let runner = RecordingCommandRunner()
        let launcher = DefaultAppLauncher(workspace: workspace,
                                          runCommand: runner.run)

        var result: ApplicationActionResult?
        launcher.activate(appName: "Passwords",
                          bundleIdentifier: "com.apple.Passwords") {
            result = $0
        }

        #expect(workspace.opened.map(\.url) == [url])
        #expect(workspace.opened.map(\.activates) == [true])
        #expect(runner.calls.isEmpty)
        #expect(result?.path == .nativeBundle)
        #expect(result?.success == true)
        #expect(result?.bundleIdentifier == "com.apple.Passwords")
    }

    @Test func unknownConfiguredBundleFailsWithoutNameFallback() {
        let workspace = MockApplicationWorkspace()
        let runner = RecordingCommandRunner()
        let launcher = DefaultAppLauncher(workspace: workspace,
                                          runCommand: runner.run)

        var result: ApplicationActionResult?
        launcher.activate(appName: "Missing", bundleIdentifier: "invalid.bundle") {
            result = $0
        }

        #expect(result?.success == false)
        #expect(result?.path == .nativeBundle)
        #expect(result?.bundleIdentifier == "invalid.bundle")
        #expect(runner.calls.isEmpty)
    }

    @Test func nativeOpenErrorFailsWithoutNameFallback() {
        let workspace = MockApplicationWorkspace()
        workspace.urls["com.apple.Passwords"] = URL(
            fileURLWithPath: "/Applications/Passwords.app")
        workspace.openResult = .failure(LauncherTestError())
        let runner = RecordingCommandRunner()
        let launcher = DefaultAppLauncher(workspace: workspace,
                                          runCommand: runner.run)

        var result: ApplicationActionResult?
        launcher.activate(appName: "Passwords",
                          bundleIdentifier: "com.apple.Passwords") {
            result = $0
        }

        #expect(result?.success == false)
        #expect(result?.detail?.contains("test open failure") == true)
        #expect(runner.calls.isEmpty)
    }

    @Test func missingBundleUsesExplicitLegacyNamePath() {
        let workspace = MockApplicationWorkspace()
        let runner = RecordingCommandRunner(exitStatus: 0)
        let launcher = DefaultAppLauncher(workspace: workspace,
                                          runCommand: runner.run)

        var result: ApplicationActionResult?
        launcher.activate(appName: "Generic App", bundleIdentifier: nil) {
            result = $0
        }

        #expect(runner.calls == [CommandCall(
            "/usr/bin/open", ["-a", "Generic App"])])
        #expect(result?.path == .legacyName)
        #expect(result?.success == true)
    }

    @Test func reopenReportsCommandFailure() {
        let workspace = MockApplicationWorkspace()
        let runner = RecordingCommandRunner(exitStatus: 7)
        let launcher = DefaultAppLauncher(workspace: workspace,
                                          runCommand: runner.run)

        var result: ApplicationActionResult?
        launcher.reopen(appName: "Safari", strategy: .makeDocument) {
            result = $0
        }

        #expect(runner.calls == [CommandCall(
            "/usr/bin/osascript",
            ["-e", "tell application \"Safari\" to make new document"])])
        #expect(result?.path == .reopen)
        #expect(result?.success == false)
        #expect(result?.detail?.contains("exit 7") == true)
    }
}
