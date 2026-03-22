# appfocus

Keyboard-driven macOS app switcher daemon + CLI.

## Build

Requires Xcode toolchain (`/usr/bin/swiftc`). No Swift Package Manager — raw swiftc via Makefile.

```
make all       # Build appfocusd (daemon) + appfocus (CLI)
make test      # Build and run unit tests
make clean     # Remove .build/
```

## Project Structure

```
Sources/
  Common/
    CommandProtocol.swift    — Command enum (jump/next/prev/status) + wire format parsing
    SocketPath.swift         — Unix socket path + sockaddr_un helpers
  CLI/
    main.swift               — CLI client: connects to daemon socket, sends command
  Daemon/
    main.swift               — Entry point: wires backends, sources, state, starts run loop
    WindowBackend.swift      — Protocol: queryAllWindows, focusedWindow, focusWindow, focusSpace
    YabaiBackend.swift       — Yabai implementation: shells out to yabai CLI, parses JSON
    CommandSource.swift      — Protocol: start/stop for command input sources
    KanataCommandSource.swift — TCP server: parses kanata push-msg JSON envelopes
    SocketCommandSource.swift — Unix socket server: accepts CLI connections
    ActivationLogic.swift    — Core brain: jump (MRU toggle, launch, reopen), cycle (ring-based)
    StateStore.swift         — Per-app persistent state: MRU IDs, ring order, JSON on disk
    FocusPoller.swift        — Background timer: polls focused window, records to StateStore
    AppLauncher.swift        — Launch (open -a) and reopen (osascript) with per-app strategies
    ProcessChecker.swift     — NSWorkspace.shared.runningApplications lookup
    Config.swift             — JSON config from ~/.config/appfocus/config.json
    Log.swift                — Stderr logger (APPFOCUS_LOG=debug for verbose)
Tests/
  Unit/
    Mocks.swift              — MockBackend, MockLauncher, MockProcessChecker
    ActivationLogicTests.swift
    StateStoreTests.swift
    ConfigTests.swift
    KanataParsingTests.swift
    CommandProtocolTests.swift
    ReconcileRingTests.swift
    TestRunner.swift          — @main entry point for Swift Testing
```

## Architecture

Protocol-based design with two extension points:

- **CommandSource** protocol — how commands arrive (kanata TCP, Unix socket CLI)
- **WindowBackend** protocol — how windows are queried and focused (yabai)

Flow: CommandSource → ActivationLogic → WindowBackend + AppLauncher + StateStore

ActivationLogic is the core brain. It handles:
- **jump**: focus app's best window (MRU), launch if not running, reopen if no windows
- **MRU toggle**: double-jump same app switches to previous window
- **cycle**: ring-based next/prev within an app's windows
- **cancellation tokens**: last-write-wins for overlapping async commands

Native macOS APIs complement yabai: `open -a` for launching, osascript for reopening, NSWorkspace for process detection.

## Config

`~/.config/appfocus/config.json` — all fields optional:

| Field | Default | Purpose |
|-------|---------|---------|
| backend | "yabai" | Window backend |
| yabai_path | "/etc/profiles/per-user/moritz/bin/yabai" | Path to yabai binary |
| aliases | {} | App name aliases (e.g. "Code" → "Visual Studio Code") |
| reopen_strategies | {"*": "reopen"} | Per-app: reopen, makeWindow, makeDocument |
| kanata_enabled | true | Enable kanata TCP source |
| kanata_port | 7070 | TCP port for kanata push-msg |
| poll_interval_ms | 1000 | FocusPoller interval |

## Testing

Uses Swift Testing framework (not XCTest). Mocks in `Tests/Unit/Mocks.swift` implement all three protocols (WindowBackend, AppLauncher, ProcessChecker) with configurable return values and call tracking.

Run a specific test: not supported — `make test` runs all tests.
