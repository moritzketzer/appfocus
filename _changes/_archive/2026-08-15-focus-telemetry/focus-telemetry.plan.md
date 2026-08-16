# Focus Telemetry Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Outcome telemetry (per-command trace → verified on-screen outcome → JSONL + `appfocus stats`) and an end-to-end benchmark harness, changing no switching behavior.

**Architecture:** `CommandTrace` (final class, mutable ref threaded through the existing chain by capture — spec shows a struct; the reference form is the workable Swift shape, reconciled at as-built). `OutcomeVerifier` on its own serial queue: coalesced ~350 ms post-completion `queryAllWindows`, outcome classification, fenced model feed, JSONL sink with 5 MB rotation. `ActivationLogic` only assigns trace fields at existing sites and calls a `OutcomeVerifying` protocol (mockable). `stats` is client-side JSONL aggregation in the CLI. `bench/appfocus-bench.sh` drives the real socket and polls yabai for visible focus.

**Tech Stack:** Swift/Makefile/Swift Testing; bash+jq for the bench. `make test` runs everything.

**Worktree:** `.worktrees/focus-telemetry`, branch `change/focus-telemetry`.

---

### Task 1: `is-visible` on WindowInfo
- [ ] TDD: parse test in WindowModelTests (`"is-visible": true` → `isVisible`); default false when absent. Add `isVisible` field + init param (default false) + parse in `from(yabaiDict:)`. Suite green. Commit `feat: ✨ parse is-visible into WindowInfo`.

### Task 2: CommandTrace + JSONL encoding
- [ ] New `Sources/Daemon/CommandTrace.swift`: final class with the spec's fields (`command`, `app`, `path`, `targetWindowId`, `targetSpace`, `crossedSpace`, `receivedAt`, `decidedAt`, `actionedAt`, `outcome`, `detail`) plus `jsonLine(at: Date)` producing one JSONL line with ms phase durations (`decide` = received→decided, `act` = decided→actioned, `total` = received→actioned, `verify` filled by the verifier). Tests: field encoding, duration math, nil phases omitted. Commit `feat: ✨ CommandTrace`.

### Task 3: OutcomeVerifier
- [ ] New `Sources/Daemon/OutcomeVerifier.swift`:
  - `protocol OutcomeVerifying { func recordImmediate(_:); func verify(_:) }`
  - `verify`: pre-set `failed` outcomes write immediately (no query). Else coalesce: replacing a pending trace finalizes it `unverified-burst`; single timer (own queue, 0.35 s, instance-var delay for tests); on fire `queryAllWindows` → nil ⇒ `unverified-queryfail`; else `model.replaceSnapshot(dump, queryStartedAt: start)` + classify:
    - target id set: focused==target → `ok` if `isVisible` else `invisible`; focused same app → `ok-app`; else `wrong-window` (+detail actual app/id/space).
    - no target id: focused app == trace.app → `ok-app`; else `wrong-window`.
  - Sink: append to `SocketPath.stateDir + "/telemetry.jsonl"`; >5 MB at write ⇒ rename to `.1` first. Write failures log once, never throw.
  - Tests (`Tests/Unit/OutcomeVerifierTests.swift`): classification matrix from synthetic dumps, coalescing (3 rapid verifies → 2 `unverified-burst` + 1 verified; condition-polled, no fixed sleeps), queryfail, rotation (tmp dir, small threshold via test hook), fenced model feed. Commit `feat: ✨ OutcomeVerifier`.

### Task 4: ActivationLogic trace enrichment
- [ ] `ActivationLogic.init` gains `verifier: OutcomeVerifying`. `PumpJob` carries its trace; `runningTrace` tracked beside `runningApp`. Sites (assignments + verifier calls only, no control-flow change):
  - `jump`/`cycle` create the trace (command, app, receivedAt).
  - submit: breaker drop ⇒ `dropped-backoff` recordImmediate; cap drop ⇒ evicted job's trace `dropped-cap`; SUPERSEDE ⇒ in-flight + all pending traces `superseded`.
  - watchdogFire ⇒ `timeout`.
  - performJump/confirm/launch/reopen/fallback/cycle set `path`; focusWindow sets `targetWindowId/targetSpace/crossedSpace/decidedAt`, completion sets `actionedAt` (+`failed` on false); noop branches set `noop` (single-window MRU, short ring) or `failed` + detail "no focused window in model" (cycle with empty model); AX-less fallback sets `path: "fallback"`, `decidedAt`, `actionedAt` after activate.
  - finish: completed trace → `verify()`; pre-classified (`noop`/`failed`-no-action) → `recordImmediate`.
  - Retry path tags `path: "retry"`.
  - `main.swift` wires a real OutcomeVerifier; Harness gets a `MockOutcomeVerifier` capturing records (append-only arrays).
  - Tests: one record per press across paths — hot ok-flow reaches verify with target set; confirm path tagged; drop/supersede/timeout sites produce immediate records (reuse existing deterministic setups: breaker test, cap test, watchdog test); noop tagged. Full suite green — existing tests updated ONLY for the new init param via Harness.
  - Commit `feat: ✨ per-command outcome traces`.

### Task 5: `appfocus stats`
- [ ] Pure aggregation in `Sources/Common/TelemetryStats.swift`: `aggregate(lines: [String], since: Date?) -> String` — counts by outcome, success rate over decided (`ok`+`ok-app`+`noop` / decided where decided excludes `superseded`/`dropped-*`/`unverified-*`), p50/p95 `total` split by path and by `crossedSpace`, last 10 non-ok with detail. CLI: `appfocus stats [--since 2h|30m|1d]` reads `telemetry.jsonl(.1)` client-side. Makefile: ensure Common compiles into CLI (it does — check target; adjust if CLI target lacks the new file's needs). Tests: fixture JSONL → exact aggregation output invariants (rate, percentiles, filtering). Commit `feat: ✨ appfocus stats`.

### Task 6: Benchmark harness
- [ ] `bench/appfocus-bench.sh` per spec: target auto-discovery (two standard-window apps on different Spaces + Space-1 target when present; args override), initial-focus save/restore, scenarios 1-6, 50 ms polling to 2 s, per-scenario report + p50/p95, telemetry cross-check (compares its trial window against `telemetry.jsonl` outcomes), threshold exit code. `bash -n` + shellcheck (nix store binary) clean; a `--dry-run` mode that only does discovery + prints the plan (validated in CI-less repo by running `--dry-run` live, harmless). Commit `feat: ✨ e2e benchmark harness`.

### Task 7: Docs
- [ ] CLAUDE.md: telemetry/stats/bench section (file locations, outcome taxonomy pointer, "definition of works" thresholds, bench warning). Commit `docs: 📝 …`.

### Task 8: Review, integrate, deploy, baseline
- [ ] Independent whole-change review (fresh reviewer); fix/dispose; closure verification for Critical/Important.
- [ ] `make test` ×2 green; archive fold (completed+archived+`git mv`); `git wt-finish focus-telemetry`; ff primary.
- [ ] nix-config worktree: overlay bump (+ gotchas note that telemetry/bench exist and are the required deploy gate for switching changes); wt-finish; ff; `just switch`.
- [ ] Live: use switcher briefly, `appfocus stats` sanity.
- [ ] **ASK MORITZ**, then run `bench/appfocus-bench.sh` attended → record baseline numbers in the archived spec (as-built addendum via follow-up commit or before archive).
