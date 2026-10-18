# Method-Decomposition Refactor — Plan

Status: plan-only (no spec: behavior-preserving refactor, no design decisions
that change observable behavior). Reviewer: Fable session. Executor: Opus
subagent. Baseline: origin/main @ 8045139, `make test` green (192 tests,
15 suites, ~10 s).

## Diagnosis (Fowler smell audit, prioritized)

1. **Large Class / Divergent Change — HIGH** — `ActivationLogic.swift` (938
   lines) mixes three change axes: (a) the serialized command pump
   (submit/queue/supersede, watchdog, backoff, cap, one-shot retry),
   (b) jump/cycle decision logic (MRU, ring, confirm, reopen, AX-less),
   (c) the focus action chain. Prescription: Extract Class `CommandPump`
   (Phase 2).
2. **Long Method — HIGH** — `submit` (~78 lines), `focusWindow` (~75),
   `watchdogFire` (~64), `jump` (~49), `mruToggleOrCycle` (~47), `finish`
   (~45); `OutcomeVerifier.fire` (~48) and `classify` (~47). Prescription:
   Extract Method (Phase 1).
3. **Duplicated Code — MEDIUM** — the advance-to-next-or-idle pump block
   appears 3× (`applicationDeadlineFire`, `watchdogFire`, `finish`); the
   `trace.update { failed + detail }; done()` exit appears ~6×;
   `AppLauncher` builds near-identical `ApplicationActionResult` completions
   3×; `YabaiBackend` duplicates JSON-decode boilerplate in two queries;
   `WindowInfo.from` repeats the `Int == 1 || Bool == true` flag parse 5×;
   `isStandardWindow`/`isAXlessCandidate` share their overlay-exclusion core.
   Prescription: Extract Method / shared helpers (Phase 1).
4. **Primitive Obsession — MEDIUM** — `CommandTrace.path`/`outcome` are
   stringly typed on the producer side; `ApplicationActionPath` is a
   half-finished enum migration (its rawValues feed the same `path` field as
   bare literals like "hot"/"confirm"). Prescription: producer-side enums
   with rawValues that keep the JSONL wire format byte-identical (Phase 3).
5. **Long Parameter List — LOW, consciously rejected** — the jump chain
   threads (appName, windows, focused, trace, token, done) through ~7
   methods. Introduce Parameter Object / Method Object was considered and
   rejected: the threading is uniform and explicit, and storing the async
   `done` continuation in a context object would blur completion ownership
   that the current style keeps obvious. Revisit only if Phase 2 leaves the
   chain hard to read.

Not touched: `KanataCommandSource` (blocking connect loop works on its
dedicated queue), `SocketCommandSource`, `main.swift` (composition root),
`StateStore`, `WindowModel`, `FocusPoller`, `TelemetryStats`, CLI, bench.

## Phases

### Phase 1 — mechanical decomposition + dedup (low risk)

ActivationLogic:
- Extract the 3× duplicated pump-advance block into one helper (e.g.
  `advanceToNextOrIdle() -> (UInt64, PumpJob)?`), documented as
  critical-section-only.
- Decompose `submit` branch bodies into named helpers (backoff drop,
  supersede, enqueue-with-cap, start) that run inside `withPumpTransition`.
- Decompose `watchdogFire` (pending partition, retry arming) and `finish`.
- Decompose `focusWindow` (space-crossing labeling, the space-switch +
  window-focus action steps) and `jump` (frontmost match, the two submit
  closures as named methods).
- Decompose `mruToggleOrCycle` (MRU switch vs cycle fallback).
- Add a small failure-exit helper for the repeated failed-trace pattern.

Other files:
- `AppLauncher`: extract result-building/logging helpers for the three
  completion shapes.
- `YabaiBackend`: extract a decode helper shared by `queryAllWindows` and
  `focusedWindow`.
- `Types.swift`: extract a `boolFlag` parse helper; share the
  overlay-exclusion core between `isStandardWindow` and `isAXlessCandidate`.
- `OutcomeVerifier`: split `fire()` into application/window halves; flatten
  `classify()` into per-target-kind helpers.

### Phase 2 — Extract Class `CommandPump` (structural)

New `Sources/Daemon/CommandPump.swift` owning: `activationQueue`,
`jobStartLock`, `currentToken`, `running*`/`pending`, `hungUntil`,
`inFlightTarget`, `pendingRetry`, deadlines/backoff/`maxPending`, the
verifier reference for trace recording, and `JobDomain`/`PumpJob`/
`RetryTarget`. Public surface: `submit(...)`, `isActive(_:)`,
`armRetryTarget(_:token:)`, the test hooks, and the tunable deadline vars.

Retry seam: the pump consumes `pendingRetry` and calls an injected
`retryRunner: (RetryTarget) -> Void` closure **while holding the same
jobStartLock transition** (the closure re-enters `submit`; the lock is
recursive — this preserves the consume+submit atomicity comment verbatim).
ActivationLogic builds the retry trace and replays the focus action, as
today.

ActivationLogic keeps its entire public + test-visible API
(`jump`/`cycle`, `commandDeadline`, `applicationDeadline`, `hungBackoff`,
`maxPending`, `fireWatchdogNowForTesting`, `isIdleForTesting`) and
delegates to the pump, so `Tests/Unit/ActivationLogicTests.swift` keeps
passing unmodified.

Rules: move code verbatim (same locks, same ordering, same comments —
including the verify-inside-critical-section ordering note in `finish`).
Extract Method (Phase 1) happens BEFORE the move so Phase 2 moves whole
methods.

### Phase 3 — producer-side trace enums (type safety, bounded)

`TracePath` and `TraceOutcome` enums (rawValues identical to today's
strings) used by `CommandTrace`, `ActivationLogic`, `OutcomeVerifier`;
`ApplicationActionPath` folded in or mapped. `jsonLine()` output stays
byte-identical. `TelemetryStats` stays string-based (it parses arbitrary
JSONL — a wire-format consumer). Tests asserting outcome strings keep
passing via rawValues; mechanical test edits only where a type changes.

## Execution contract

- Behavior-preserving only; every changed line traces to this plan.
- Preserve the why-comments (race histories, dated live defects) verbatim;
  relocate them with their code. Never summarize them away.
- No lock-discipline changes. Helpers that must run inside a critical
  section carry the existing "Runs on `queue`"-style doc comment idiom.
- `make test` after every atomic step; red → revert the step, try smaller.
- Commit per cohesive unit, signed, matching repo style
  (`refactor(appfocus): ♻️ …`, `test(appfocus): ✅ …`,
  `docs(appfocus): 📝 …`). Retry on flaky Secretive signing.
- Update CLAUDE.md's Project Structure listing for new files at the end.
- Unit tests green ≠ deployed-verified: the live benchmark
  (`bench/appfocus-bench.sh`, attended) and the nix-config overlay bump
  remain post-merge gates owned by Moritz.
