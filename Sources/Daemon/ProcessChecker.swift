// Sources/Daemon/ProcessChecker.swift
import AppKit
import Foundation

protocol ProcessChecker {
    func isAppRunning(name: String) -> Bool
}

final class WorkspaceProcessChecker: ProcessChecker {
    private let config: AppFocusConfig

    init(config: AppFocusConfig) {
        self.config = config
    }

    func isAppRunning(name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            config.resolveAlias($0.localizedName ?? "") == name
            || $0.localizedName == name
        }
    }
}
