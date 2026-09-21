import AppKit
import Testing

private final class StubRunningApplication: NSRunningApplication, @unchecked Sendable {
    var identifier: String? = "org.zotero.zotero"
    var url: URL? = URL(fileURLWithPath: "/Applications/Nix Apps/Zotero.app")
    var exited = false

    override var bundleIdentifier: String? { identifier }
    override var bundleURL: URL? { url }
    override var isTerminated: Bool { exited }
    override var localizedName: String? { "Zotero" }
}

private final class StubSystemWorkspace: NSWorkspace {
    var applications: [NSRunningApplication] = []
    var frontmost: NSRunningApplication?
    var installedURL: URL? = URL(fileURLWithPath: "/nix/store/old-zotero/Applications/Zotero.app")
    var resolvedIdentifiers: [String] = []
    var openedURLs: [URL] = []
    var activationOptions: [Bool] = []

    override var runningApplications: [NSRunningApplication] { applications }
    override var frontmostApplication: NSRunningApplication? { frontmost }

    override func urlForApplication(withBundleIdentifier identifier: String) -> URL? {
        resolvedIdentifiers.append(identifier)
        return installedURL
    }

    override func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: (@Sendable (NSRunningApplication?, Error?) -> Void)? = nil
    ) {
        openedURLs.append(applicationURL)
        activationOptions.append(configuration.activates)
        completionHandler?(applications.first, nil)
    }
}

@Suite("ApplicationWorkspace")
struct ApplicationWorkspaceTests {
    @Test(arguments: [true, false])
    func runningBundleWinsOverInstalledResolution(installed: Bool) {
        let app = StubRunningApplication()
        let system = StubSystemWorkspace()
        system.applications = [app]
        if !installed { system.installedURL = nil }
        let workspace = SystemApplicationWorkspace(workspace: system)

        #expect(workspace.applicationURL(bundleIdentifier: "org.zotero.zotero") == app.url)
        #expect(system.resolvedIdentifiers.isEmpty)
    }

    @Test func launcherOpensLiveBundleWithActivation() {
        let app = StubRunningApplication()
        let system = StubSystemWorkspace()
        system.applications = [app]
        let launcher = DefaultAppLauncher(workspace: SystemApplicationWorkspace(workspace: system))
        var result: ApplicationActionResult?

        launcher.activate(appName: "Zotero", bundleIdentifier: "org.zotero.zotero") {
            result = $0
        }

        #expect(system.openedURLs == [app.url!])
        #expect(system.activationOptions == [true])
        #expect(system.resolvedIdentifiers.isEmpty)
        #expect(result?.success == true)
    }

    @Test func coldLookupIgnoresTerminatedUnrelatedAndUnbundledProcesses() {
        let terminated = StubRunningApplication()
        terminated.exited = true
        let unrelated = StubRunningApplication()
        unrelated.identifier = "org.zotero.zotero.other"
        let unbundled = StubRunningApplication()
        unbundled.url = nil
        let system = StubSystemWorkspace()
        system.applications = [terminated, unrelated, unbundled]
        system.frontmost = terminated
        let workspace = SystemApplicationWorkspace(workspace: system)

        #expect(workspace.applicationURL(bundleIdentifier: "org.zotero.zotero") == system.installedURL)
        #expect(system.resolvedIdentifiers == ["org.zotero.zotero"])
    }

    @Test func nextRequestSeesRestartedApplication() {
        let original = StubRunningApplication()
        let replacement = StubRunningApplication()
        replacement.url = URL(fileURLWithPath: "/Applications/Updated/Zotero.app")
        let system = StubSystemWorkspace()
        system.applications = [original]
        let workspace = SystemApplicationWorkspace(workspace: system)
        #expect(workspace.applicationURL(bundleIdentifier: "org.zotero.zotero") == original.url)

        original.exited = true
        system.applications = [original, replacement]
        #expect(workspace.applicationURL(bundleIdentifier: "org.zotero.zotero") == replacement.url)
        #expect(system.resolvedIdentifiers.isEmpty)
    }

    @Test func frontmostMatchingProcessWins() {
        let first = StubRunningApplication()
        let frontmost = StubRunningApplication()
        frontmost.url = URL(fileURLWithPath: "/Applications/Other/Zotero.app")
        let system = StubSystemWorkspace()
        system.applications = [first, frontmost]
        system.frontmost = frontmost
        let workspace = SystemApplicationWorkspace(workspace: system)

        #expect(workspace.applicationURL(bundleIdentifier: "org.zotero.zotero") == frontmost.url)
        #expect(system.resolvedIdentifiers.isEmpty)
    }

    @Test func firstLiveBundleWinsWhenFrontmostIsUnrelated() {
        let first = StubRunningApplication()
        let second = StubRunningApplication()
        second.url = URL(fileURLWithPath: "/Applications/Other/Zotero.app")
        let frontmost = StubRunningApplication()
        frontmost.identifier = "other.app"
        let system = StubSystemWorkspace()
        system.applications = [frontmost, first, second]
        system.frontmost = frontmost
        let workspace = SystemApplicationWorkspace(workspace: system)

        #expect(workspace.applicationURL(bundleIdentifier: "org.zotero.zotero") == first.url)
        #expect(system.resolvedIdentifiers.isEmpty)
    }
}
