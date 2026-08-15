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
    TelemetryStats.swift     — Pure aggregation behind `appfocus stats`
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
    CommandTrace.swift       — Per-command telemetry record + JSONL encoding
    OutcomeVerifier.swift    — Verified on-screen outcome classification + telemetry sink
    WindowModel.swift        — In-memory window snapshot + focused id; commands read this, not yabai
    StateStore.swift         — Per-app persistent state: MRU IDs, ring order, JSON on disk
    FocusPoller.swift        — Background timer: full window snapshot into WindowModel + MRU recording
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

Flow: CommandSource → ActivationLogic → WindowModel (read) + WindowBackend (act) + AppLauncher + StateStore

**Read/act split:** commands never query yabai on the hot path. FocusPoller
rebuilds the in-memory WindowModel from one full `queryAllWindows` snapshot
per tick (default 2 s, first tick immediate); jump/cycle read the model and
issue only focus actions. Completed focus actions update the model
optimistically so serialized bursts compound. The single deliberate live
query left is the confirm on the "no windows for a running app" branch (a
stale empty read there would reopen a duplicate window). Staleness bound:
one poll interval; a vanished target fails cleanly and self-heals at the
next poll.

ActivationLogic is the core brain. It handles:
- **jump**: focus app's best window (MRU), launch if not running, reopen if no windows
- **MRU toggle**: double-jump same app switches to previous window
- **cycle**: ring-based next/prev within an app's windows
- **cancellation tokens**: last-write-wins for overlapping async commands
- **watchdog + one-shot retry**: a command stuck >3s is force-dropped (pump
  never wedges); if its focus target was already resolved, the focus action
  replays once after the backoff unless a newer command supersedes it
- **AX-less fallback**: a running app whose only windows lack yabai AX
  references (ChatGPT lazy-AX state) gets focusSpace + native activation
  instead of a useless reopen

Native macOS APIs complement yabai: `open -a` for launching, osascript for reopening, NSWorkspace for process detection.

## Telemetry & Benchmark (the deploy gate)

Every command produces one JSONL record in
`~/.local/state/appfocus/telemetry.jsonl` (5 MB rotation to `.1`):
intended target, path taken (`hot|confirm|launch|reopen|fallback|retry|noop`),
phase timings (`decide`/`act`/`total`/`verify` ms), and a VERIFIED on-screen
outcome — `OutcomeVerifier` runs one coalesced `queryAllWindows` ~350 ms
after completion and classifies `ok` / `ok-app` / `invisible` /
`wrong-window` / `failed` / `noop`, plus `superseded`/`dropped-*`/`timeout`
recorded at their sites and `unverified-burst` for coalesced-away presses.
The verification dump also feeds the WindowModel (fenced).

- `appfocus stats [--since 2h]` — success rate, outcome counts, p50/p95
  latency by path and same/cross-Space, last 10 failures with forensics.
- `bench/appfocus-bench.sh [--dry-run]` — end-to-end benchmark through the
  real socket, asserting VISIBLE focus via yabai polling. Moves real focus
  for ~60-90 s: run attended. Exit nonzero on threshold violation.

**Definition of works** (both instruments): ≥99% of decided presses end
`ok`/`ok-app`/`noop`; p95 press-to-visible ≤300 ms same-Space / ≤700 ms
cross-Space; zero dead presses in normal operation. Switching changes are
not "verified" until the benchmark passes — unit tests alone don't count.

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
| poll_interval_ms | 2000 | WindowModel snapshot poll interval |

## Testing

Uses Swift Testing framework (not XCTest). Mocks in `Tests/Unit/Mocks.swift` implement all three protocols (WindowBackend, AppLauncher, ProcessChecker) with configurable return values and call tracking.

Run a specific test: not supported — `make test` runs all tests.
