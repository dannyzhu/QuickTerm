# Program Status (OSC 7501) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** QuickTerm reads OSC 7501 program-status reports from every pane and shows them in the pane's band with agent-style alarms, for agents and for any other program, without weakening hooks.

**Architecture:** Engine patch 0005 parses OSC 7501 (limits enforced, the query answered), forwards each valid report and each OSC 133 prompt-start to the app as apprt actions, and exposes the pty's foreground process group. In the app, a per-pane `ProgramStatusStore` keeps the records (replace, clear by id subtree, cap, drop on a changed foreground group or a prompt); a mapper turns the winning record into the existing `AgentStatus`/notice vocabulary with a new evidence kind, under the hook-first and never-resolve-a-hook-alarm rules; the band and `quickterm state` show it.

**Tech Stack:** Zig 0.15.2 (libghostty 1.3.1 + patches), Swift 6 / AppKit / SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-06-program-status-osc7501-design.md`

## Global Constraints

- Engine stays at Ghostty 1.3.1 + patches 0001–0004; patch `patches/ghostty/0005-osc-7501-program-status.patch` applies after them in filename order, idempotently, in `scripts/build-ghosttykit.sh`; the native build must pass (universal before a release).
- Protocol limits (spec decision 2), all enforced, a report breaking any is discarded whole: sequence ≤ 4096 bytes; key ≤ 16 bytes; `msg` ≤ 2732 encoded / 2048 decoded bytes; `title` ≤ 256 / 192; `app` ≤ 32 and `[A-Za-z0-9_.+-]{1,32}`; `id` ≤ 128 bytes, ≤ 8 segments of `[A-Za-z0-9_.+-]{1,32}`; values `[A-Za-z0-9_.,+/=-]*`; keys `[a-z]+`; invalid base64; decoded `msg`/`title` with U+0000–U+001F, U+007F or U+0080–U+009F.
- States `idle working done blocked error clear`; any other `state` → report ignored. Kinds (with blocked) `permission question auth`; other → absent. `progress` integer 0–100.
- Query `ESC]7501;?ST` → reply exactly `ESC]7501;?ESC\` (no lists). The reply contains nothing from any report.
- Records per pane: 64, least recently updated dropped past the cap. `RIS` clears all.
- Precedence: hook > programStatus > notification (OSC 9/777) > process. A program-status report may raise an alarm; it never resolves one a hook raised.
- Hook-first window = from the agent's first hook-evidenced status until it is released (not a recency window).
- done/error from program status = `info` notices (no Dock badge, resolve on focus); blocked = `needsUser` alarm; typing quiets (not resolves) a program-status alarm; a repeat of the same (state, kind, id) raises nothing.
- Rate limits: ≤ 1 `info` banner per pane per 10 s from program status (suppressed banner dropped, notice still posted); a program-status `needsUser` within 1 s of the same (pane, source)'s previous one or last resolve is posted silently (no banner or sound, still marked and badged, `notice.*` events coalesced to ≤ 1 pair per second), hook alarms never limited; band redraws ≤ 4 per second.
- Config `[agents] program-status = true` (bool, default on; off = QuickTerm ignores every report; the engine still answers the query). Documented in both READMEs (`testEveryKeyIsDocumented`).
- Wire: generic notices' source `program:<app>` (`program` when no `app`); `quickterm state` per-pane `programs` array; `agents list` unchanged; `agent.state.changed` with `evidence: "program-status"`. English.
- Privacy: no command line, environment or path of any non-agent process is read; the foreground process group is a number only.
- English-first; new UI strings in `Resources/en.lproj/ProgramStatus.strings` and `Resources/zh-Hans.lproj/ProgramStatus.strings` (new table: add to both, re-run `xcodegen generate`).
- Test runner: `xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -derivedDataPath build/dd test -only-testing:QuickTermTests/<Class>` (sandbox off, never wrapped in `timeout`). On "test runner hung before establishing connection" stop, report BLOCKED; the controller runs the tests and the full suite.

## Review Focus

1. **A crafted `state=done` printed while a hook-raised approval is live** (e.g. `cat` of a file in the same pane). Expected: the approval stays; the band may show the program's record as a separate line only if it outranks; nothing resolves. → Task 4 test `testReportNeverResolvesAHookAlarm`.
2. **A chatty program** (progress 1→100 in 100 ms steps). Expected: band redraws coalesced, no banner per step (working posts no notice at all), registry work O(1) per report. → Task 4 test `testProgressStepsPostNoNotice`; Task 5 test `testBandRedrawsAreCoalesced`.
3. **Malformed or hostile bytes** (8 KB sequence, base64 decoding to ESC, bidi override U+202E in `title`, 9-deep id, `state=` empty, interleaved with normal output). Expected: discarded whole, no crash, surrounding output intact; a bidi override is stripped at display. → Task 1 engine tests for each; Task 5 test `testTitleIsSanitisedForDisplay`.
4. **A program that exits without clearing** (Codex killed mid-turn, `cargo` Ctrl+C) and **a report typed at the prompt**. Expected: the first drops working/blocked/idle when the foreground group changes; the second stays until the next command. → Task 3 tests `testRecordDropsWhenTheForegroundGroupChanges`, `testReportTypedAtThePromptSurvivesTheHeartbeat`.
5. **Two programs in one pane** (Claude hook-tracked working, a `cargo` record blocked; or two `id`s from one program). Expected: the band shows the most urgent one; each alarm belongs to its own record; clearing one id leaves the other. → Task 3 test `testClearRemovesTheSubtreeOnly`; Task 4 test `testBlockedRecordOutranksAHookAgentThatIsWorking`.

---

### Task 1: Engine patch 0005 — parse OSC 7501, answer the query, forward reports and prompt start, expose the foreground group

**Files:**
- Create: `vendor/ghostty/src/terminal/osc/parsers/program_status.zig` (port of v1.4.0's file adapted to 1.3.1's `Parser` capture API: 1.3.1 uses `writeToAllocating()` where 1.4.0 uses `captureTrailing(.allocating)`)
- Modify: `vendor/ghostty/src/terminal/osc/parsers.zig`, `vendor/ghostty/src/terminal/osc.zig` (states `@"75"`, `@"750"`, `@"7501"` after `@"7"`; `Command.program_status`), `vendor/ghostty/src/terminal/stream.zig` (dispatch), `vendor/ghostty/src/termio/stream_handler.zig` (query reply via `messageWriter`; report → `apprt.surface.Message.program_status`; `.prompt_start` → `apprt.surface.Message.prompt_start`; `fullReset` → `apprt.surface.Message.program_status_reset`), `vendor/ghostty/src/apprt/surface.zig`, `vendor/ghostty/src/Surface.zig` (message → apprt action), `vendor/ghostty/src/apprt/action.zig`, `vendor/ghostty/include/ghostty.h`, `vendor/ghostty/src/apprt/embedded.zig` (foreground group function), `vendor/ghostty/src/termio/Exec.zig` (read-only accessor for the pty master fd if needed)
- Create: `patches/ghostty/0005-osc-7501-program-status.patch` (`git -C vendor/ghostty diff` of exactly those files)
- Test: Zig tests in `program_status.zig` (run through the `test-lib-vt` target, as patch 0003's tests were)

**Interfaces:**
- Produces (C, `ghostty.h`):
  - `GHOSTTY_ACTION_PROGRAM_STATUS` with `typedef struct { const char* state; const char* kind; int32_t progress; const char* id; const char* app; const char* title; const char* msg; } ghostty_action_program_status_s;` — strings NUL-terminated, empty string when absent; `progress` −1 when absent; `title`/`msg` already base64-decoded UTF-8; valid only for the duration of the callback.
  - `GHOSTTY_ACTION_PROMPT_START` (no payload) for OSC 133 `A`.
  - `GHOSTTY_ACTION_PROGRAM_STATUS_RESET` (no payload) on a full reset (`RIS`, `stream_handler.fullReset`), so the app drops the pane's records (spec decision 3).
  - `int32_t ghostty_surface_foreground_pgid(ghostty_surface_t);` — `tcgetpgrp` on the surface's pty master; −1 when unavailable.
- The engine validates every limit in Global Constraints and never delivers a report that fails one.

- [ ] **Step 1: Write the parser tests** — accepted report with every key; `state=clear`; unknown state ignored; malformed pair skipped; repeated key last-wins; ST and BEL; each limit (4097-byte sequence, 17-byte key, 2733-byte msg, 2049-byte decoded msg, 257/193 title, 33-byte app, bad app chars, 9-deep id, 33-byte segment, 129-byte id); invalid base64; decoded control char in `msg` and `title` (ESC, U+0085); `progress=101` and `progress=-1` treated as absent; `kind` outside the set treated as absent; the query `?` recognised.
- [ ] **Step 2: Run them to see them fail** — `cd vendor/ghostty && QUICKTERM_SDK=../../.tools/sdk-arm64fix-MacOSX26.5.sdk PATH=../../.tools/bin:$PATH ../../.tools/zig-0.15.2/zig build test-lib-vt -Dtest-filter=program_status` (the full `zig build test` does not link on this machine).
- [ ] **Step 3: Implement** the parser, the osc.zig states and Command, stream dispatch, the stream-handler query reply and the two forwarded messages, the apprt actions, the C structs and the foreground-group function.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Write the patch and verify the apply order** in a scratch worktree on v1.3.1: 0001→0005 each `git apply --check` then apply; `--reverse --check` on the working tree for all five.
- [ ] **Step 6: Rebuild** `GHOSTTYKIT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-ghosttykit.sh` (log shows 0005 applied) and the Debug app; `nm` lists `_ghostty_surface_foreground_pgid`.
- [ ] **Step 7: Commit** the patch file — `feat(engine): patch 0005 parses OSC 7501 program status and forwards it to the app`.

### Task 2: App side of the actions — decode, sanitise, route to the pane

**Files:**
- Create: `Sources/ProgramStatus/ProgramStatusReport.swift`
- Modify: `Sources/GhosttyEmbed/Ghostty.App.swift` (two action cases → the pane), `Sources/GhosttyEmbed/Surface View/SurfaceView_AppKit.swift` (`var foregroundProcessGroup: Int32?` wrapping `ghostty_surface_foreground_pgid`)
- Test: `Tests/ProgramStatusReportTests.swift`

**Interfaces:**
- Consumes: Task 1's two actions and C function.
- Produces:
  - `struct ProgramStatusReport: Equatable { enum State: String { case idle, working, done, blocked, error, clear }; enum Kind: String { case permission, question, auth }; var state: State; var kind: Kind?; var progress: Int?; var id: [String]; var app: String?; var title: String?; var message: String? }`
  - `static func from(_ c: ghostty_action_program_status_s) -> ProgramStatusReport?` — nil on an unknown state (defence in depth); `id` split on `/`, empty = root.
  - `static func displayText(_ s: String) -> String` — removes Unicode format characters (category Cf: bidi overrides, zero-width, isolates) and clamps with the band's existing title clamp.
  - Routing: `ProgramStatusStore.shared.receive(_ report:, pane: UUID, foregroundGroup: Int32?)`, `ProgramStatusStore.shared.promptStarted(pane: UUID)` and `ProgramStatusStore.shared.reset(pane: UUID)` (defined in Task 3); when `settings.programStatus` is off, nothing is routed.

- [ ] **Step 1: Write the tests** — `testDecodesEveryField`, `testEmptyStringsAreAbsent`, `testProgressMinusOneIsAbsent`, `testIdSplitsIntoSegments`, `testDisplayTextStripsBidiAndZeroWidth` (U+202E, U+200B, U+2066 removed; Chinese and emoji kept), `testConfigOffRoutesNothing`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the report type, the two action handlers (main thread), the foreground-group accessor and the `[agents] program-status` key (`ConfigSchema` ZH/EN pair, `ConfigStore.Settings.programStatus`, both READMEs).
- [ ] **Step 4: Run them and `ConfigSchemaTests`, `ConfigStoreTests`.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(status): decode OSC 7501 reports in the app ([agents] program-status)`.

### Task 3: `ProgramStatusStore` — per-pane records

**Files:**
- Create: `Sources/ProgramStatus/ProgramStatusStore.swift`
- Modify: `Sources/Agents/ProcessScanner.swift` (heartbeat also calls `ProgramStatusStore.shared.checkForeground()`)
- Test: `Tests/ProgramStatusStoreTests.swift`

**Interfaces:**
- Consumes: Task 2's `ProgramStatusReport`.
- Produces: `@MainActor final class ProgramStatusStore` — `static let shared`; `struct Record: Equatable { var report: ProgramStatusReport; var foregroundGroup: Int32?; var updatedAt: Date }`; `func receive(_:pane:foregroundGroup:)`; `func promptStarted(pane:)`; `func checkForeground(current: (UUID) -> Int32?)`; `func records(pane: UUID) -> [Record]`; `func paneClosed(_:)`; `func reset(pane:)` (RIS); `var onChange: ((UUID) -> Void)?`; `static let cap = 64`; injectable clock.

- [ ] **Step 1: Write the tests** — `testReportReplacesItsRecord`, `testClearRemovesTheSubtreeOnly` (`a/b` cleared keeps `a/c` and `x`), `testClearWithoutIdRemovesAll`, `testCapDropsTheLeastRecentlyUpdated` (65th), `testRecordDropsWhenTheForegroundGroupChanges` (working/blocked/idle drop; done/error stay), `testReportTypedAtThePromptSurvivesTheHeartbeat` (report arrives with group = shell's; heartbeat with the same group keeps it), `testPromptStartDropsWorkingBlockedIdle`, `testResetClearsAll`, `testPaneClosedForgetsThePane`, `testOnChangeFiresOncePerChange`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the store and the heartbeat hook.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(status): ProgramStatusStore keeps per-pane OSC 7501 records`.

### Task 4: Mapping, precedence and alarms

**Files:**
- Create: `Sources/ProgramStatus/ProgramStatusMapper.swift`
- Modify: `Sources/Agents/AgentStatus.swift` (`AgentDetail.auth`), `Sources/Agents/PaneSignal.swift` (`case programStatus(ProgramStatusStore.Record)`), `Sources/Notices/Notice.swift` (`NoticeEvidence.programStatus`, raw value `program-status`), `Sources/Agents/AgentRegistry.swift`, `Sources/Agents/AgentStateReducer.swift`, `Sources/Notices/NoticeCenter.swift` (`quietOrResolve(pane:)` under `.clearInterruptingSinks` treats `.programStatus` like hook/report evidence: quiet, not resolve), `Sources/Notices/Sinks/SystemNotificationSink.swift` (the per-pane 10 s limit on `info` banners whose evidence is `.programStatus`), `Resources/*/ProgramStatus.strings` (state/kind labels, "Program")
- Test: `Tests/ProgramStatusMapperTests.swift`, additions in `Tests/AgentRegistryTests.swift`, `Tests/NoticeCenterTests.swift`

**Interfaces:**
- Consumes: Task 3's store and `onChange`.
- Produces: `enum ProgramStatusMapper { static func owner(of: ProgramStatusReport, rules: [String: AgentRules]) -> String? /* rule id by app == id or app ∈ process */; static func state(of: ProgramStatusReport) -> (AgentState, AgentDetail?); static func winner(agent: AgentStatus?, records: [ProgramStatusStore.Record]) -> Winner }` with `enum Winner { case agent(AgentStatus); case program(ProgramStatusStore.Record) }`, ordering blocked > error > working > done > idle, ties by most recent.

- [ ] **Step 1: Write the tests** — the full mapping table (spec decision 9, incl. blocked+auth → `.auth`, blocked with no kind → `.input`); `testOwnerByAppIdAndByProcessName` (`codex` → codex; `claude` process name → claude-code; `cargo` → nil); `testHookFirstKeepsTheHookState` (hook status working + record done → state stays working, progress and message added); `testReportNeverResolvesAHookAlarm`; `testReportResolvesItsOwnAlarm`; `testDoneAndErrorAreInfo`; `testRepeatDoesNotReRaise`; `testDifferentKindSupersedes`; `testTypingQuietsAProgramStatusAlarm`; `testBlockedRecordOutranksAHookAgentThatIsWorking`; `testProgressStepsPostNoNotice`; `testInfoBannerRateLimitPerPane` (second done within 10 s posts the notice but no banner; a blocked within 10 s still banners); `testGenericSourceSpelling` (`program:cargo`, `program`).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the mapper, the new detail and evidence, the registry/reducer wiring for agent-owned records, the side path for generic records (notices posted with source `program:<app>`), the quiet rule and the rate limit.
- [ ] **Step 4: Run them plus `AgentRegistryTests`, `AgentStateReducerTests`, `NoticeCenterTests`, `ControlAgentEventTests`.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(status): program status raises agent-style alarms, hooks first`.

### Task 5: The band and the control plane

**Files:**
- Modify: `Sources/Splits/PaneAgentStrip.swift` (draw the winner; label `title` → `app` → "Program"; progress `NN%`; coalesce redraws to ≤ 4/s), `Sources/Control/ControlStateEncoder.swift`, `Sources/Control/Wire/ControlStatePayload.swift` (per-pane `programs`), `Sources/Control/ControlEventBus.swift` (`agent.state.changed` with `evidence: "program-status"`), `docs/agents/quickterm-cli.md` (the new `programs` field), both READMEs (a short "Program status" paragraph, line-parallel)
- Test: additions in `Tests/PaneAgentStripTests.swift`, `Tests/ControlStateTests.swift`, `Tests/ControlEventTests.swift`

**Interfaces:**
- Consumes: Task 4's `ProgramStatusMapper.winner`, Task 2's `displayText`.

- [ ] **Step 1: Write the tests** — `testBandShowsGenericProgram` (`cargo · working · 40%`), `testBandPrefersTitleOverApp`, `testBandShowsMessageAfterColon`, `testTitleIsSanitisedForDisplay`, `testBandRedrawsAreCoalesced`, `testStateCarriesProgramsPerPane` (fields per Global Constraints; `title`/`msg` only where agent messages are exposed), `testAgentsListUnchanged`, `testStateChangedEventEvidence`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the band, the wire fields, the event and the docs.
- [ ] **Step 4: Run them plus `LocalizationTests`, `ConfigSchemaTests`.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(status): the band and quickterm state show program status`.

### Task 6: End-to-end check

- [ ] **Step 1: Full suite** (controller). Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 2: Hand the Debug build to the owner** with the spec's manual checks: Codex without a hook shows working, approval and done; `printf '\e]7501;state=working:app=cargo:progress=40\e\\'` shows `cargo · working · 40%` and survives until the next command; a crafted `state=done` while a hook approval is up leaves the approval; `program-status = false` shows nothing.
