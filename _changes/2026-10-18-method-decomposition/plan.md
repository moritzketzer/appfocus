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

### Phase 4 — second decomposition pass (2026-10-19)

Requested follow-up round. Targets are the files round 1 deliberately left
out, plus post-round-1 residuals whose bodies still mix distinct concerns.
The semantic-distance rule governs; line counts are only the search signal.

4.1 `Common/TelemetryStats.swift` — `aggregate` (~80 lines with nested funcs)
does parsing/filtering, outcome counting, success rate, latency sections,
and the failure tail in one body. Promote the nested `percentiles` /
`latencyLine` helpers to private static methods and extract
`parseRecords(lines:since:)`, the outcome-count step, the latency section,
and the failures section as named helpers. The formatted output string must
stay byte-identical (TelemetryStatsTests drive it with fixture lines).

4.2 `Daemon/YabaiBackend.swift` — `runYabai` (~70 lines) mixes process
setup, the finish-once latch, the concurrent drain, and timeout/kill
escalation. Extract process construction, the drain start, and the
timeout/kill scheduling into private helpers that receive the shared
`finish` closure. The latch (`finishLock`/`finished`) stays one per
invocation; every helper runs on the same queue it runs on today; the
per-call timing log stays inside the finish closure; bodies move verbatim.

4.3 `Daemon/OutcomeVerifier.swift` — `classifyApplication` (~45 code lines)
mixes notification-identity freshness resolution, the no-identity guard,
the matched finalization, the deadline wait, and the wrong-window
finalization: extract the identity resolution and the three trace
finalizations as named helpers (deadline-wait control flow stays in the
main method). In `verify()`, extract the pending-replacement + timer-arming
block. Keep every "Runs on `queue`" comment.

4.4 `Daemon/ActivationLogic.swift` residuals:
- Dedup: the `snapshot.focusedId.flatMap { … }` focused-window resolution
  appears in `performJump` and `performCycle` → one private helper taking
  the snapshot.
- `performJump`: extract the pre-jump MRU recording block.
- `confirmNoWindows`: extract the AX-less candidate filter.
- `handleNoWindows`: extract the two action branches (native AX-less
  activation; reopen).
- `cycleWithKnownState`: extract the ring reconciliation (store update +
  read-back) and the pure next-ring-id step computation (static, like
  `preserveRingOrder`).

4.5 `Daemon/KanataCommandSource.swift` — extract the chunk/line assembly
from `readMessages` into a pure static helper
(`assembleLines(chunkBytes:incomplete:) -> (complete: [String], incomplete: String)`
or equivalent) with IDENTICAL semantics, including the current
`String(bytes:encoding:) ?? ""` fallback — the UTF-8 chunk-boundary defect
stays report-only; this only creates its testable seam. Add one focused
unit test next to the existing kanata parsing tests (multi-line chunk,
incomplete tail carried forward).

Phase 4 non-goals, considered and excluded: `CommandPump` and `runJob`
(independently reviewed this week; bodies are cohesive transitions — reopening
freshly reviewed concurrency code for line counts violates the
semantic-distance rule), `CommandTrace.jsonLine` (a serialization table),
`Types.swift` memberwise init (boilerplate), `AppLauncher.activate` (two
clear branches), `CLI/main.swift` (top-level script), and every report-only
finding from the round-1 review (Kanata byte-level decode, StateStore flush
ordering, stop() close race, Log EPIPE).

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
