// Sources/Daemon/main.swift
import Foundation

// Parse environment
Log.debugEnabled = ProcessInfo.processInfo.environment["APPFOCUS_LOG"] == "debug"

let startTime = Date()
Log.info("appfocusd starting")

// Load config
let config = AppFocusConfig.load()

// Create components
let backend = YabaiBackend(yabaiPath: config.yabaiPath)
let launcher = DefaultAppLauncher()
let store = StateStore()
let processChecker = WorkspaceProcessChecker(config: config)
let logic = ActivationLogic(config: config, backend: backend,
                             launcher: launcher, store: store,
                             processChecker: processChecker)
let poller = FocusPoller(backend: backend, store: store, config: config)

// Ensure state directory exists
try? FileManager.default.createDirectory(
    atPath: SocketPath.stateDir, withIntermediateDirectories: true)

// Shared command handler
let handleCommand: (Command) -> Void = { cmd in
    switch cmd {
    case .jump(let appName): logic.jump(appName: appName)
    case .next: logic.cycle(direction: .next)
    case .prev: logic.cycle(direction: .prev)
    case .status: break // unreachable from commandHandler — dispatched to statusHandler, needed for exhaustive switch
    }
}

// Status handler (socket-only)
let handleStatus: (Int32) -> Void = { clientFd in
    let uptime = Int(Date().timeIntervalSince(startTime))
    var lastFocused: [String: Any] = [:]
    if let app = store.globalLastFocusedApp,
       let state = store.stateIfCached(for: app) {
        lastFocused = [
            "app": app,
            "window_id": state.lastFocusedId ?? 0,
            "space": state.lastFocusedSpace ?? 0,
        ]
    }
    let status: [String: Any] = [
        "uptime_s": uptime,
        "backend": config.backend,
        "tracked_apps": store.trackedAppCount,
        "last_focused": lastFocused.isEmpty ? NSNull() : lastFocused,
        "pending_activation": NSNull(),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: status),
       let json = String(data: data, encoding: .utf8) {
        let bytes = Array(json.utf8)
        _ = write(clientFd, bytes, bytes.count)
    }
}

// Start Unix socket source (for CLI)
let socketSource = SocketCommandSource(
    path: SocketPath.socketPath,
    commandHandler: handleCommand,
    statusHandler: handleStatus)

do {
    try socketSource.start()
} catch {
    Log.error("Failed to start: \(error)")
    exit(1)
}

// Start kanata TCP source (optional)
var kanataSource: KanataCommandSource? = nil
if config.kanataEnabled {
    let source = KanataCommandSource(port: config.kanataPort,
                                      commandHandler: handleCommand)
    try? source.start()
    kanataSource = source
    Log.info("Kanata TCP client enabled (port \(config.kanataPort))")
} else {
    Log.info("Kanata TCP client disabled")
}

// Start focus poller
poller.start()

// Handle SIGTERM/SIGINT for clean shutdown
let sigSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { sig in
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig)
    src.setEventHandler {
        Log.info("Received signal \(sig), shutting down")
        socketSource.stop()
        kanataSource?.stop()
        poller.stop()
        exit(0)
    }
    src.resume()
    return src
}

Log.info("appfocusd ready")

// Keep main thread alive
dispatchMain()
