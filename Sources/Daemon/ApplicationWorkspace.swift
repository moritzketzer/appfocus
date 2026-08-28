import AppKit
import Foundation

struct ApplicationIdentity: Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
}

protocol ApplicationWorkspace {
    var frontmostApplication: ApplicationIdentity? { get }
    func applicationURL(bundleIdentifier: String) -> URL?
    func openApplication(
        at url: URL,
        activates: Bool,
        completion: @escaping (Result<ApplicationIdentity, Error>) -> Void
    )
    @discardableResult
    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject
}

private final class WorkspaceActivationObservation: NSObject {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        if let token {
            center.removeObserver(token)
        }
    }
}

final class SystemApplicationWorkspace: ApplicationWorkspace {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    var frontmostApplication: ApplicationIdentity? {
        workspace.frontmostApplication.map(Self.identity)
    }

    func applicationURL(bundleIdentifier: String) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(
        at url: URL,
        activates: Bool,
        completion: @escaping (Result<ApplicationIdentity, Error>) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        workspace.openApplication(at: url, configuration: configuration) { app, error in
            if let error {
                completion(.failure(error))
            } else if let app {
                completion(.success(Self.identity(app)))
            } else {
                completion(.failure(NSError(
                    domain: "appfocus.workspace",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "NSWorkspace returned no application for \(url.path)"])))
            }
        }
    }

    @discardableResult
    func observeActivations(
        _ handler: @escaping (ApplicationIdentity) -> Void
    ) -> AnyObject {
        let center = workspace.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: nil
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            handler(Self.identity(app))
        }
        return WorkspaceActivationObservation(center: center, token: token)
    }

    private static func identity(_ app: NSRunningApplication) -> ApplicationIdentity {
        ApplicationIdentity(bundleIdentifier: app.bundleIdentifier,
                            localizedName: app.localizedName)
    }
}
