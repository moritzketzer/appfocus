# Changelog

## 0.1.0 (2026-03-22)

Initial release.

- Daemon (`appfocusd`) with Unix socket and kanata TCP command sources
- CLI (`appfocus`) for jump, next, prev, status commands
- MRU toggle between two most recent windows
- Ring-based window cycling (next/prev)
- App launching (if not running) and reopening (if no windows)
- App name aliases and per-app reopen strategies
- Focus polling for accurate MRU state
- 72 unit tests
