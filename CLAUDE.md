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
    OutcomeVerifier.swift    — AppKit or yabai outcome classification + telemetry sink
    WindowModel.swift        — In-memory window snapshot + focused id; commands read this, not yabai
    StateStore.swift         — Per-app persistent state: MRU IDs, ring order, JSON on disk
    FocusPoller.swift        — Background timer: full window snapshot into WindowModel + MRU recording
    ApplicationWorkspace.swift — AppKit app identity, activation, and notification boundary
    AppLauncher.swift        — Bundle activation, name compatibility, and reopen results
    Config.swift             — JSON config from ~/.config/appfocus/config.json
    Log.swift                — Stderr logger (APPFOCUS_LOG=debug for verbose)
Tests/
  Unit/
    Mocks.swift              — Window, launcher, verifier, and ApplicationWorkspace mocks
    ActivationLogicTests.swift
    StateStoreTests.swift
    ConfigTests.swift
    KanataParsingTests.swift
    CommandProtocolTests.swift
    ReconcileRingTests.swift
    TestRunner.swift          — @main entry point for Swift Testing
```

## Architecture

Protocol-based design with four injected boundaries:

- **CommandSource** protocol — how commands arrive (kanata TCP, Unix socket CLI)
- **WindowBackend** protocol — how windows are queried and focused (yabai)
- **ApplicationWorkspace** protocol — frontmost identity, bundle URL resolution, AppKit activation, and activation notifications
- **AppLauncher** protocol — result-bearing activation and reopen operations

Flow: CommandSource → ActivationLogic → ApplicationWorkspace (route) → AppLauncher (cross-app act) or WindowModel + WindowBackend (same-app act) → StateStore

**Native/window split:** cross-app jumps read the frontmost application and
activate through AppKit before touching the window model. These application
jobs make zero `WindowBackend` calls. Same-app jumps and cycles read the
in-memory WindowModel and act through yabai. FocusPoller rebuilds the model
from one full `queryAllWindows` snapshot per tick (default 2 s, first tick
immediate). The sole command-time query confirms that a frontmost app has no
eligible windows before reopening it. A stale empty model therefore cannot
open a duplicate Finder or Safari window.

ActivationLogic is the core brain. It handles:
- **jump**: focus app's best window (MRU), launch if not running, reopen if no windows
- **MRU toggle**: double-jump same app switches to previous window
- **cycle**: ring-based next/prev within an app's windows
- **application domain**: native activation bypasses the yabai breaker, queue cap, and retry; a separate 3 s deadline records `native-timeout`
- **window domain**: same-app navigation retains the 3 s yabai watchdog, one-second backoff, queue cap, and one-shot focus retry
- **cancellation tokens**: different application targets remain last-write-wins; repeated commands for one target queue in order
- **AX-less fallback**: a running app whose only windows lack yabai AX
  references (ChatGPT lazy-AX state) gets native activation without a Space
  focus or launch polling

Native macOS APIs complement yabai: `NSWorkspace` activates and verifies configured bundle identifiers, `/usr/bin/open -a` supports unmapped names, and `osascript` runs reopen strategies.

## Telemetry & Benchmark (the deploy gate)

Every command produces one JSONL record in
`~/.local/state/appfocus/telemetry.jsonl` (5 MB rotation to `.1`):
intended target, path taken (`hot|confirm|native-bundle|legacy-name|native-axless|reopen|retry|noop`),
phase timings (`decide`/`act`/`total`/`verify` ms), and a VERIFIED on-screen
outcome. Application targets use AppKit activation notifications plus the
frontmost application and make zero yabai calls. Window targets run one
coalesced `queryAllWindows` about 350 ms after completion and classify
`ok` / `ok-app` / `invisible` /
`wrong-window` / `failed` / `noop`, plus `superseded`/`dropped-*`/`timeout`
recorded at their sites and `unverified-burst` for coalesced-away presses.
The verification dump also feeds the WindowModel (fenced). Activation paths
include `native-bundle`, `legacy-name`, `native-axless`, and `reopen`.

- `appfocus stats [--since 2h]` — success rate, outcome counts, p50/p95
  latency by path and same/cross-Space, last 10 failures with forensics.
  Taxonomy notes: cycle traces carry no app, so a cycle landing on a
  sibling window classifies strictly (`wrong-window`, never `ok-app`);
  a watchdog-cleared backlog is labeled `dropped-cap` with detail
  "backlog dropped by watchdog".
- `bench/appfocus-bench.sh [--dry-run]` — end-to-end benchmark through the
  real socket, asserting VISIBLE focus via yabai polling. Moves real focus
  for ~60-90 s: run attended. Exit nonzero on threshold violation.

**Definition of works** (both instruments): ≥99% of decided presses end
`ok`/`ok-app`/`noop`; p95 press-to-visible ≤300 ms same-Space / ≤750 ms
cross-Space; zero dead presses in normal operation. Switching changes are
not "verified" until the benchmark passes — unit tests alone don't count.

## Config

`~/.config/appfocus/config.json` — all fields optional:

| Field | Default | Purpose |
|-------|---------|---------|
| backend | "yabai" | Window backend |
| yabai_path | "/etc/profiles/per-user/moritz/bin/yabai" | Path to yabai binary |
| aliases | {} | App name aliases (e.g. "Code" → "Visual Studio Code") |
| bundle_identifiers | {} | Canonical app name → stable macOS bundle identifier |
| reopen_strategies | {"*": "reopen"} | Per-app: reopen, makeWindow, makeDocument |
| kanata_enabled | true | Enable kanata TCP source |
| kanata_port | 7070 | TCP port for kanata push-msg |
| poll_interval_ms | 2000 | WindowModel snapshot poll interval |

## Testing

Uses Swift Testing framework (not XCTest). The suite currently runs 182 tests in 14 suites. Mocks in `Tests/Unit/Mocks.swift` implement `WindowBackend`, `AppLauncher`, `ApplicationWorkspace`, and `OutcomeVerifying` with configurable results and call tracking.

Run a specific test: not supported — `make test` runs all tests.
