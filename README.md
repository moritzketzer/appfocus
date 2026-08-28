# ⌨️ appfocus

[![Tests](https://github.com/moritzketzer/appfocus/actions/workflows/test.yml/badge.svg)](https://github.com/moritzketzer/appfocus/actions/workflows/test.yml)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Keyboard-driven app switcher for macOS** — jump to any app, MRU-toggle between windows, cycle a window ring, all from the home row.

> 🎯 **TL;DR:** appfocus is a lightweight daemon that sits between your keyboard remapper and your window manager, giving you instant app switching, MRU toggle, and window cycling — all from the home row.

---

## Table of Contents

- [What Makes This Special](#what-makes-this-special)
- [Architecture](#architecture)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [kanata Integration](#kanata-integration)
- [Running as a Service](#running-as-a-service)
- [How It Works](#how-it-works)
- [Tests](#tests)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements](#acknowledgements)

---

## What Makes This Special

- ⚡ **Native app switching** — Cross-app jumps activate a stable bundle identifier through AppKit. Same-app window selection stays with yabai.
- 🔄 **MRU toggle** — Double-tap to bounce between your two most recent windows of the same app
- 🎯 **Window ring cycling** — Navigate next/prev through all windows of the current app
- ⌨️ **kanata native** — Direct TCP integration with kanata's push-msg, no shell scripts, sub-ms latency
- 🧩 **Modular backends** — yabai is the only backend today, but the `WindowBackend` protocol makes it straightforward to add alternatives (AeroSpace, pure Accessibility API, etc.)
- 🪶 **No third-party runtime dependencies** — Pure Swift with AppKit and the configured window backend

---

## Architecture

```
┌── Command Sources ──┐                  ┌──── Backends ─────────┐
│                      │                  │                        │
│  ⌨️  kanata (TCP)    │───┐              │  🪟 yabai              │
│                      │   ├─▶ appfocusd ─┤     query & focus      │
│  💻 CLI (socket)     │───┘      │       │                        │
│                      │          │       │  🍎 AppKit              │
└──────────────────────┘          │       │     activate & verify   │
                                  │       │                        │
                            State Store   │  📜 osascript           │
                            (per-app      │     reopen              │
                             MRU + ring)  └────────────────────────┘
```

---

## Features

- Jump by app name while activating configured targets by bundle identifier
- Explicit name-based compatibility path for apps without a bundle identifier
- MRU toggle between two most recent windows of the same app
- Ring-based window cycling (next/prev) within an app
- kanata integration via TCP push-msg
- App name aliases (e.g., `"Code"` → `"Visual Studio Code"`)
- Per-app reopen strategies (`reopen`, `makeWindow`, `makeDocument`)
- Focus polling for accurate MRU tracking
- Unix socket CLI for scripting

---

## Requirements

- macOS 14+
- Xcode Command Line Tools (Swift compiler)
- [yabai](https://github.com/koekeishiya/yabai) window manager

---

## Installation

### From source

```bash
make && make install
```

Installs `appfocusd` and `appfocus` to `/usr/local/bin`.

### With Nix

```bash
nix build github:moritzketzer/appfocus
```

---

## Configuration

All fields are optional — defaults are sensible out of the box.

Create `~/.config/appfocus/config.json`:

```json
{
  "backend": "yabai",
  "yabai_path": "/usr/local/bin/yabai",
  "aliases": {
    "Code": "Visual Studio Code"
  },
  "bundle_identifiers": {
    "Safari": "com.apple.Safari",
    "Visual Studio Code": "com.microsoft.VSCode"
  },
  "reopen_strategies": {
    "Finder": "makeWindow",
    "Safari": "makeDocument",
    "*": "reopen"
  },
  "poll_interval_ms": 2000,
  "kanata_enabled": true,
  "kanata_port": 7070
}
```

| Field | Default | Description |
|---|---|---|
| `backend` | `"yabai"` | Window backend to use |
| `yabai_path` | `"/usr/local/bin/yabai"` | Path to the yabai binary |
| `aliases` | `{}` | Map short names to full app names |
| `bundle_identifiers` | `{}` | Map canonical app names to stable macOS bundle identifiers |
| `reopen_strategies` | `{"*": "reopen"}` | Per-app strategy when no windows exist (`reopen`, `makeWindow`, `makeDocument`) |
| `poll_interval_ms` | `2000` | How often to poll focused window for MRU tracking |
| `kanata_enabled` | `true` | Whether to listen for kanata TCP push-msg |
| `kanata_port` | `7070` | TCP port to listen on for kanata messages |

---

## Usage

```bash
appfocus jump Safari      # focus Safari (or launch it)
appfocus next             # cycle to next window of current app
appfocus prev             # cycle to previous window
appfocus status           # show daemon status as JSON
```

---

## kanata Integration

<details>
<summary>Show kanata config example</summary>

Add to your `.kbd` config:

```
(deftemplate app-open (appname)
  (push-msg (concat "jump " $appname))
)

(defalias
  wnx (push-msg "next")   ;; cycle forward
  wpr (push-msg "prev")   ;; cycle backward
  saf (t! app-open "Safari")
  kit (t! app-open "kitty")
  vsc (t! app-open "Visual Studio Code")
)
```

kanata sends a JSON `{"MessagePush":{"message":"jump Safari"}}` over TCP to appfocusd on the configured port (default `7070`). The `concat` form in `deftemplate` produces an array format which appfocus also handles.

No shell scripts, no subprocesses — the command travels from keypress to window focus in sub-millisecond time.

</details>

---

## Running as a Service

<details>
<summary>Show launchd plist</summary>

Save to `~/Library/LaunchAgents/local.appfocus.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.appfocus</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/appfocusd</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
```

Then load it:

```bash
launchctl load ~/Library/LaunchAgents/local.appfocus.plist
```

</details>

---

## How It Works

appfocusd exposes two command sources: a Unix socket for CLI use (`appfocus jump`, `appfocus next`, etc.) and a TCP listener for kanata's push-msg protocol. Both feed the same `ActivationLogic`.

For `jump <app>`, appfocusd first resolves aliases and checks the frontmost application. A configured cross-app target activates through `NSWorkspace` by bundle identifier without querying yabai. An app absent from `bundle_identifiers` uses `/usr/bin/open -a` through the explicit `legacy-name` compatibility path.

If the target application is already frontmost, appfocusd keeps window navigation in yabai. It selects the best window from the in-memory model, performs the existing MRU toggle, or cycles the ring. A fresh yabai query runs only when the frontmost app has no eligible window in the model. An Accessibility-less window then uses native activation; a truly windowless app runs its configured reopen strategy.

Per-app state (`lastFocusedId`, `prevFocusedId`, and the window ring order) is persisted as JSON files in `~/.local/state/appfocus/`. A background poll (configurable interval, default 2 s) keeps MRU data fresh when focus changes outside appfocus.

The outcome verifier matches application jobs against activation notifications and `NSWorkspace.frontmostApplication`; these checks make no yabai calls. Window jobs retain the delayed yabai snapshot that verifies the focused window and refreshes the model. Telemetry names the native paths `native-bundle`, `native-axless`, and `legacy-name`.

The command protocol is newline-delimited text over the Unix socket (`jump <app>`, `next`, `prev`, `status`). kanata uses a JSON `MessagePush` envelope over TCP. appfocusd unwraps it and routes to the same handler. `ApplicationWorkspace` isolates AppKit operations, while `WindowBackend` isolates yabai calls.

---

## Tests

180 unit tests cover native activation, verification, job isolation, window navigation, command parsing, state persistence, and configuration.

```bash
make test
```

---

## Contributing

Contributions welcome! Please open an issue first to discuss what you'd like to change.

---

## License

[MIT](LICENSE)

---

## Acknowledgements

- [yabai](https://github.com/koekeishiya/yabai) by koekeishiya
- [kanata](https://github.com/jtroo/kanata) by jtroo
