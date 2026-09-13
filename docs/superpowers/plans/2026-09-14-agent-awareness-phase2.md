# Agent awareness, Phase 2: hooks, the agent registry and the info strip — implementation plan

> Builds on the spec `docs/superpowers/specs/2026-09-13-agent-awareness.md` (§2.1 facts, §3 architecture,
> §10 the Phase 1 contract) and on **what Phase 1 actually landed** in `Sources/Notices/`, `Sources/Control/`
> and `GhosttyNoticeProducer` in `Sources/GhosttyEmbed/Ghostty.App.swift`. The third review lens
> (architecture and boundaries) never reached the spec's editor; its six findings are folded in here — each
> decision below says which one it answers and, where the finding is not followed, why.
>
> This is the document an implementer executes. Every design decision is taken here; if something is not
> written down, the Phase 1 contract (§10) and the existing code's conventions decide, in that order. English
> throughout (CLI, wire, comments); UI strings in both catalogs.

## 0. Invariants (hold these in every package)

- The existing suite stays green at every commit, `scripts/check-localization.py` passes, and
  `xcodegen generate` is re-run after any file is added (a file not in the project is silently not built;
  a `.strings` table or a `.toml` not in the project is silently not bundled).
- **One command table** (`ControlCommandTable`) generates CLI parsing, `--help`, `describe`, the safety
  classes and the MCP map. `MCPToolMapTests.testEveryCommandIsEitherExposedOrExplicitlyExcluded` and
  `testEveryCommandGroupIsCovered` must stay green: every new command is either in a tool or in
  `MCPToolMap.excluded`, and every new group has at least one exposed command.
- **The hook never blocks an agent**: `quickterm agent-event` and the installed script exit 0 with empty
  stdout and stderr whatever happens. Exit 2 (`ControlExit.notRunning`) is a verdict to every agent (§2.1).
- **A forger may add a notice; it may never remove one.** Resolution as `stateChanged` needs the posting
  lineage; nothing here weakens `NoticeOrigin.permits`.
- **The scan reads only QuickTerm's descendants**, only processes whose executable name a rule file lists,
  keeps pid + name + pane marker, and discards the argument buffer in the same call.
- **No event carries pane output.** `ControlEventTests.testNoEventEverCarriesPaneOutput` keeps its closed
  field list; Phase 2 appends fields and one type to that list, nothing else.
- Everything that draws reads state through `@Published`/`objectWillChange` on the object that owns it: the
  strip observes **its pane**, never the registry and never the centre.
- All JSON through `JSONEncoder` / `JSONSerialization`; nothing hand-assembled.

## 1. Phase 1 follow-ups

Judged against the code as it is, not against the finding as written.

### 1.1 Pane-move staleness — **change it** (core)

`Notice.screen` / `Notice.workspace` are taken from the locator at post time and read back in three
places: `NoticeCenter.recomputeCounts()` (the pill count and the Dock total), `NoticeScope.admits` in
`ControlNoticeCommands.noticesList` (`-t 1:2` filtering), and `ControlStateEncoder.noticeRecord` /
`ControlPlaneSink.emit` (the wire). Phase 1 documented the limitation; Phase 2 makes approval notices live for
minutes, and `pane move -t t7 --to 1:3` by the very agent arranging the work is routine, so the pill will
count on the wrong workspace in practice.

Change (all in `Sources/Notices/NoticeCenter.swift` and the three readers):

- `NoticeCenter` gains `func location(of notice: Notice) -> NoticeLocation` =
  `locator.locate(notice.pane)?.location ?? notice.location` — where the pane **is now** when it still
  exists, where it was posted when it is gone (a history entry outliving its pane).
- `recomputeCounts()` keys on `location(of:)`; `runActivityPass()` ends with
  `if recomputeCounts() { dispatch(.countsChanged(counts)) }` — the pass already runs on every
  `$layouts` / `$floatings` change (contract §10.4 call sites), so a move is picked up in the same turn.
- `NoticeScope.admits`, `ControlStateEncoder.noticeRecord` and `ControlPlaneSink.emit` read
  `NoticeCenter.shared.location(of:)` instead of the stored pair. The stored fields stay (doc comment:
  "at post time; `NoticeCenter.location(of:)` is the current one") because a history entry needs them.
- Tests (`NoticeCenterTests`): move a pane's stub entry to another workspace, run the pass, assert
  `counts` moved and `.countsChanged` was dispatched once; `ControlNoticeTests`: `-t 1:2` finds the notice
  after a move, `notices list` records report the new workspace.

### 1.2 The engine tap — **extend `GhosttyNoticeProducer`; no publisher** (core API, package E wiring)

The finding wanted a `PaneSignals` publisher so Phase 2 would not reopen `Ghostty.App.swift`. Against the
code: the three engine taps are already funnelled through one `@MainActor enum` with static closure seams
that the tests replace, and the only engine signal Phase 2 adds — `childExited` — is **already** a
`NotificationCenter` post (`Ghostty.Notification.ghosttyChildExited`, object = the surface view) that the
registry can observe without touching the engine switch at all. A Combine publisher would add a
subscription lifecycle and a second dispatch hop for exactly one consumer.

So `PaneSignal` exists as the registry's **input vocabulary** (§2.5), and the producer grows two seams:

```swift
// GhosttyNoticeProducer (Sources/GhosttyEmbed/Ghostty.App.swift)
/// The agent registry's ear on the engine. `consumed` = a rule matched and the registry owns this
/// signal; the producer then posts no `.terminal` notice of its own.
static var observe: (UUID, EngineSignal) -> EngineSignalOutcome = { AgentRegistry.shared.observeEngine(pane: $0, $1) }
/// True while the pane's status has evidence `.hook` or `.report` (spec §3.2): the engine's OSC
/// notifications and commandFinished still feed the registry but post no notice of their own.
static var mutes: (UUID) -> Bool = { AgentRegistry.shared.mutesEngineNotices(pane: $0) }
```

`desktopNotification` becomes: `let outcome = observe(pane, .notification(title, body))`; post the
`.terminal` info notice only when `outcome == .ignored && !mutes(pane)`. `commandFinished` becomes:
`_ = observe(pane, .commandFinished)` (a scan trigger, never consumed); post only when `!mutes(pane)` and
the duration rule allows. `bell` is unchanged (a bell is not an agent signal). `resetForTesting()` restores
both seams to `{ _, _ in .ignored }` / `{ _ in false }` so `NoticeSourcesTests` keep running without a
registry. The "name the childExited producer" half of the finding: the registry observes
`ghosttyChildExited` itself (§2.5); the engine gains no new callback.

### 1.3 The event side channel — **leave it; add a producer token** (core)

`ControlEventBus.emit(_:redactable:)` bypasses the snapshot diff. Is the `flush()`-first ordering safe? Yes:
`emit` is reached only from `NoticeCenter.dispatch` on the main actor (producers hop in with
`assumeIsolated`, commands run on the main thread, the activity pass is `DispatchQueue.main.async`), and
`flush()` → `rescan()` → `Snapshot.capture` reads registry state only, then `notify()` hands batches to
followers whose `deliver` goes `queue.async` onto the io queue — no path re-enters the centre or the bus.
Causality holds in both orders of the two coalesced passes: if the activity pass runs before the bus's own
scan, the `flush()` inside `emit` produces `pane.closed` ahead of `notice.resolved`. The thing the finding
feared — several call sites drifting and double-reporting — cannot happen while there is one producer per
event type that has already coalesced its own state, which is exactly what the centre is and what the
registry will be (transitions only, §2.5).

Change: `emit` gains a parameter that makes the rule structural:

```swift
/// The two things allowed to skip the snapshot diff. Adding a case here is a design decision, not a
/// convenience: a direct producer must be the sole owner of its event type and must have coalesced
/// its own duplicates before calling.
enum DirectProducer { case noticeCenter, agentRegistry }
func emit(_ event: ControlEvent, redactable: Bool, producer: DirectProducer)
```

`ControlPlaneSink` passes `.noticeCenter`; the registry passes `.agentRegistry`. No snapshot section for
notices or agent state is added (nothing would subtract it). `ControlEventTests.testNoEventEverCarriesPaneOutput`
is extended with `agent.state.changed` and the new fields (§2.9).

### 1.4 `agentStateLeftNeedsUser` cannot report `origin_mismatch` — **change it** (core)

`resolveAll(.stateChanged)` silently skips notices whose stored origin refuses the caller and returns only
the number resolved, so `agent-event` could not tell "nothing was live" from "a cross-pane attempt was
refused". Change the return type (the only Phase 1 caller is `testAgentStateLeftNeedsUserResolvesOnlyTheAlarms`):

```swift
struct StateChangeOutcome: Equatable { var resolved: Int; var refused: [UUID] }
@discardableResult
func agentStateLeftNeedsUser(pane: UUID, origin: NoticeOrigin?) -> StateChangeOutcome
```

`refused` lists the live `needsUser` notices of the pane whose `origin.permits(origin) == false`. The
runner (§2.2 step 8) logs each refusal and answers `origin_mismatch` when `refused` is non-empty and
`resolved == 0`.

Also appended to `NoticeResolution` (a wire value, so **appended**, never reordered):
`case agentGone = "agent-gone"` — used only by the registry when presence is lost (§2.4, §2.7). It is not
origin-gated: the registry is in-process and the process really is gone; on the wire it tells an agent
"the prompt went away because the program did", which `state-changed` would misstate.

### 1.5 Views observing `NoticeCenter.shared` — **leave it; bound it with tests** (core)

`PaneChrome` (one per mounted pane) and `StatusBarView` (one per screen) each hold
`@ObservedObject private var notices = NoticeCenter.shared`, so every mutation of `@Published live`
re-evaluates every mounted frame's `body`. Rate: `live` mutates on a non-duplicate post, a supersession
and a resolution — never on a duplicate post, and (by §2.5) **never on a tool-tier hook event**: the
registry posts on a transition into `blocked`/`error` and resolves on the way out, and a `working:tool` →
`working:tool` change touches the pane's own `agentStatus`, not the centre. So the redraw rate is
O(prompts + long commands + OSC notifications), and each redraw costs one `PaneFrame` overlay evaluation
per mounted pane (SwiftUI diffs the result). That is acceptable and stays acceptable with
`hook-detail = tools` as long as the strip observes the pane, not the centre (§2.11).

Bound, not measured (a measurement on one machine proves nothing on the next):

- `AgentRegistryTests.testToolHooksNeverTouchTheCentre`: feed 200 alternating `PreToolUse` /
  `PostToolUse` signals; assert the centre's `objectWillChange` fired 0 times and `live` is unchanged.
- `AgentRegistryTests.testStatusRedrawsOnlyItsPane`: two panes; change one pane's status 50 times; assert
  the other `PaneView.objectWillChange` fired 0 times and the centre 0 times.
- `NoticeCenterTests.testDuplicatePostNeverPublishes` (extends the existing duplicate case): count
  `objectWillChange` across 100 duplicate posts = 0.

### 1.6 Two more things the code surfaced

- **`Notice.quietedAt`** — needed by the Q1 default (§2.8); a centre change, so it lands in core.
- **`GhosttyNoticeProducer.commandFinished` is a scan trigger** (spec §3.1) — wired through the new
  `observe` seam (1.2); the producer file is otherwise untouched.

## 2. Design decisions taken

### 2.1 The `report` command class (answers the blocking finding)

`agent-event` is not a mutation of anything the user owns and must never be refused for reasons that apply
to mutations. Today, as class `mutate`, it would be: refused as `disabled` in `[control] mode = "readonly"`,
refused as `busy` while any QuickTerm dialog is up (a `PermissionRequest` landing then is lost for good — the
hook exits 0 by design and never retries), charged to the origin bucket the agent's own `quickterm` commands
share, charged to the per-connection bucket by `ControlServer.isMutation`, and routed through `commit()`
with a flash, a change list and an undo slot it must not have.

**`ControlCommandClass` gains `case report`** (appended; `CaseIterable` order is not on the wire):

```swift
/// A status report from a program inside a pane about that pane (agent-event). It changes nothing of
/// the user's: no consent, no flash, no undo, no activity-log entry, allowed in readonly mode and while
/// a dialog is up; its own rate limit keyed by the proven pane; `seq` moves only when the report
/// changed something (through the event bus, never through settleMutation).
case report
var requiresConsent: Bool { self == .destructive || self == .sensitive }      // unchanged
var isMutation: Bool { self != .read && self != .report }
```

Consequences, each of which an implementer must verify by reading the gate rather than assuming:

- `ControlServer.isMutation(_:)` reads `spec.cls.isMutation` → a report never touches the per-connection
  bucket.
- `ControlCommandRunner.handle`: the `readonly`, `modalBusyProbe() || consent.isPrompting`, origin-bucket
  and consent gates all key on `cls.isMutation` / `cls.requiresConsent` → a report passes them. The
  `config.isListening` gate still applies (`mode = "off"` → `disabled`, which the CLI swallows).
- `honorsMutationFlags` is false → `--dry-run` / `--fail-if-noop` are refused with `bad_request` as
  for any read; correct.
- A new gate, placed right after the `interactive` gate: for `cls == .report`, prove the pane (§2.2 steps
  1–3) and admit through the report bucket (§2.2 step 4). Both before any parsing of the payload, so a
  forged or runaway caller costs one HMAC and one bucket check.
- `ControlRateLimiter` gains a second ledger:

  ```swift
  /// Reports: one bucket per proven pane, sized for `hook-detail = tools` (Claude Code runs tools in
  /// parallel; a burst of a dozen hooks inside one second is normal) and a global ceiling so ten panes
  /// cannot starve the main thread.
  static let reportLimit = Limit(capacity: 60, perSecond: 20)
  static let reportGlobalLimit = Limit(capacity: 240, perSecond: 60)
  mutating func admitReport(pane: UUID, now: Date = Date()) -> Verdict     // scopes "pane" / "global"
  ```

  Separate from `admit(origin:)` by construction: the agent's own `quickterm pane new` loop and its hooks
  never share a bucket. `reset()` clears both ledgers.
- `describe` (`ControlDescribe.make`) gains a `ClassDoc` for `report` with the sentence above; `MCPTool`
  annotations need no change (`agent-event` is excluded from MCP, §2.9).
- Activity log: **nothing** on success. A refusal (token mismatch, `origin_mismatch`, rate limit) goes
  through the existing `logRefusal`, which names the peer — that is the record the lineage rule promises.

The herdr shim (Phase 3) is a translator into this same class; nothing in Phase 2 pre-builds it.

### 2.2 `quickterm agent-event --agent <id>`

**Command spec** (top-level, no group; appended to `ControlCommandTable.commands` after `notices ack`):

```swift
ControlCommandSpec(
    "agent-event",
    summary: "Report an agent lifecycle event about the caller's own pane (run by the hook script QuickTerm installs; reads the hook's JSON on stdin)",
    cls: .report, idempotent: true, acceptsTarget: false,
    args: [
        ControlArgSpec("agent", .string, help: "the agent rule id (claude-code | codex | gemini, or a user rule file's id)", required: true),
        ControlArgSpec("event", .string, help: "the reduced hook payload as one JSON object (the CLI builds it from stdin; passing it by hand is for tests)"),
    ],
    examples: ["quickterm agent-event --agent claude-code < payload.json   # what the hook script runs; never exits non-zero"],
    outputSample: nil)
```

**The CLI side** (`CLI/AgentEvent.swift`, one branch in `CLI/main.swift` at the top of `run(_:)`, before the
socket connect, after argument parsing):

1. Read stdin with `FileHandle.standardInput.read(upToCount: AgentEventPayload.maxStdinBytes)` — **8192
   bytes, then stop reading**; a payload cut at the cap is parsed anyway (if the JSON is now invalid the
   event is dropped).
2. `AgentEventPayload.reduce(_:)` (Wire, §2.2 "whitelist") → nil means drop.
3. Connect **without** `--start` semantics (a hook must never launch the app); send
   `ControlRequest(cmd: "agent-event", args: ["agent": .string(id), "event": .string(reducedJSON)])` with
   the ordinary `token` / `origin` from the environment (`send(_:over:)` already builds these).
4. Read the reply, discard it, `exit(0)`. **Every failure on this path — not running, protocol mismatch,
   refused, rate limited, socket error — is `exit(0)` with nothing written.** No `fail()`, no `emit()`.
   Argument-parse errors before this branch keep the parser's usual output (only a human typing by hand
   reaches them; the script always passes a valid `--agent`).

**The whitelist** — `struct AgentEventPayload: Codable, Equatable` in `Sources/Control/Wire/AgentEventPayload.swift`
(compiled into both targets):

```swift
var hookEventName: String            // "hook_event_name"      required
var notificationType: String?        // "notification_type"
var sessionID: String?               // "session_id"
var toolName: String?                // "tool_name"
var errorType: String?               // "error_type"
var message: String?                 // "message"              clamped
var toolInput: [String: String]?     // "tool_input"           reduced (see below)
var details: [String: String]?       // "details"              reduced (Gemini's ToolPermission)

static let maxStdinBytes = 8192
static let maxFieldLength = TitleRules.maxLength          // 200
static let maxObjectKeys = 8
static func reduce(_ data: Data) -> AgentEventPayload?
```

Reduction rules (the CLI applies them; the server applies them **again** to whatever it receives, so a
hand-built `--event` cannot smuggle more): string fields are `TitleRules.fromTypedInput` (printable, trimmed,
cut to 200); `tool_input` / `details`: if an object, keep only its **string-valued top-level keys**, each
clamped to 200, at most 8 keys in the object's key order; if a string, `["text": clamped]`; anything else →
nil. Nothing else crosses: no `transcript_path`, no `cwd`, no nested bodies, no full file contents. The server
additionally refuses an `event` argument over 8192 bytes with `bad_request`. The CodingKeys are the snake
case names above, so a rule file's field path (§2.3) reads the same spelling the agent uses.

**Attribution and the server side** (`Sources/Control/Commands/ControlAgentEventCommands.swift`, entered from
`execute()` by `case "agent-event"` before the noun-verb default), in this order:

1. `request.origin?.pane` parses as a UUID **and** `request.origin?.paneToken` is present — else
   `bad_request` "agent-event needs QUICKTERM_PANE and QUICKTERM_PANE_TOKEN in the environment (run it from
   a hook inside a QuickTerm pane)". `-t` is not accepted (`acceptsTarget: false`); the pane is the proven
   origin, never a target.
2. `ControlEnvironment.constantTimeEquals(paneToken, ControlEnvironment.paneToken(for: paneID))` — else
   `logRefusal(..., code: .badRequest, message: "pane token mismatch")` and `bad_request`. This is the same
   test as `writesIntoOwnPane`, minus the resolver: there is no target to resolve.
3. The pane is addressable (`ControlResolver.addressablePanes(in:)`) — else `not_found`.
4. `rateLimiter.admitReport(pane:)` — `.limited` → `logRefusal(code: .rateLimited)` and `rate_limited`
   with `retryAfterMs` (the CLI ignores it; the hint is for a human).
5. `args["agent"]` names a loaded rule (`AgentRegistry.shared.rules[id]`) — else `bad_request` with
   `candidates` = loaded ids. `args["event"]` ≤ 8192 bytes and decodes to `AgentEventPayload` — else
   `bad_request`. Re-reduce it (the same static function).
6. `let lineage = ControlLineage.root(of: peer.pid)`;
   `let origin = NoticeOrigin(lineageRoot: lineage, sessionID: payload.sessionID)`.
7. `let outcome = AgentRegistry.shared.apply(.hook(agent: id, payload: payload), pane: paneID, origin: origin)`
   (§2.5 — the registry runs the reducer, writes the pane, posts/resolves notices, emits the event).
8. For every id in `outcome.refused`: `logRefusal(request.cmd, ..., code: .originMismatch,
   message: "cross-pane resolve refused for notice <id>")`. If `outcome.refused` is non-empty and
   `outcome.resolved == 0` → fail with `origin_mismatch` ("this event may not resolve the alarm on pane
   <handle>: it was posted by a different process lineage or session"). Otherwise succeed.
9. Response data: `ControlAgentEventPayload { schema = "quickterm.agent-event/1", pane: handle, agent,
   state, detail?, changed: Bool, noticeID: String?, resolved: Int }`. **No `settleMutation()`**: `seq` in
   the response is whatever the bus holds, which moved iff the registry emitted `agent.state.changed`.

**`ControlLineage`** (`Sources/Control/ControlLineage.swift`, app target):

```swift
enum ControlLineage {
    /// `pbi_ppid` from `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)`; nil when the pid is gone or unreadable.
    static func parent(of pid: pid_t) -> pid_t?
    /// The direct child of `ancestor` (default: this process) that `pid` descends from, walking parents
    /// at most `maxDepth` (32) steps. nil = the chain never reaches `ancestor` (the hook was reparented
    /// to launchd because its agent already exited, or the caller is unrelated to QuickTerm).
    static func root(of pid: pid_t, under ancestor: pid_t = getpid(), maxDepth: Int = 32) -> pid_t?
}
```

The root is the pane's shell process (the surface's spawned child), so `lineageRoot` identifies the pane by
process tree — something a process in another pane cannot fake by reading environment variables. A nil root
(reparented `SessionEnd` from an `async` hook whose agent has exited) fails `permits` against a stored
lineage; presence loss then resolves the alarm as `.agentGone` (§2.7), so nothing is stuck.

**Error code**: `ControlErrorCode` appends `case originMismatch = "origin_mismatch"`, `exit: .denied`,
`summary: "A state-changed resolution from a process lineage or session other than the one that posted the alarm: refused, logged, the alarm stays. A forger may add a notice and never remove one."`.
`describe` picks it up from `allCases`.

### 2.3 `AgentRules`: TOML rule files and the field-path vocabulary (answers finding 2)

**Why one Swift reducer and data-only rules**: precedence (hook > report > notification > process), the
hook-recency window and the presence rule are cross-source, time-dependent and identical for every agent;
they live once, in `AgentStateReducer` (§2.4). A rule file says only what is agent-specific: process names,
which event maps to which state, which payload field sub-keys an event, where message / tool / summary /
session / error come from, and what its installer writes.

**Parser** — `Sources/Agents/AgentRulesTOML.swift`, a dedicated scanner (the config parser `ConfigTOML.scan`
is a flat section/key/value scanner with no arrays, no quoted keys and no dotted tables; extending it for
this would widen a parser that every config load runs). Accepted grammar, and nothing more:

- comments `#` to end of line (outside strings), blank lines;
- table headers `[a]`, `[a.b]`, `[a.b.c]` — segments `[A-Za-z0-9_-]+`, depth ≤ 3;
- `key = value` — key bare `[A-Za-z0-9_-]+` or a double-quoted string; value a double-quoted string
  (escapes `\"`, `\\`, `\n` only) or a one-line array of double-quoted strings `["a", "b"]`;
- anything else → `AgentRulesError.syntax(line: Int, text: String)`; the file is rejected whole.

Result: `[tablePath: [key: Value]]` with `Value = .string | .strings`.

**Field paths**: `$` followed by one or two `.segment`s (`[A-Za-z0-9_]+`), evaluated against the reduced
payload's JSON form. One-segment paths may name `hook_event_name`, `notification_type`, `session_id`,
`tool_name`, `error_type`, `message`; two-segment paths may only start with `tool_input` or `details`.
Anything else fails at load. Paths only — no expressions, no defaults, no regex. Where a value may come from
several places, the key takes an **array** of paths and the first non-empty wins.

**State tags**: `"idle" | "working:thinking" | "working:tool" | "blocked:approval" | "blocked:input" |
"blocked:choice" | "done" | "error" | "unknown" | "released"`. The detail's coarse state is fixed
(thinking/tool → working; approval/input/choice → blocked); a tag whose detail does not belong to its state,
or a state that carries a detail it must not, fails at load. `released` means "this agent's status is
removed from the pane".

**Schema** (`struct AgentRules: Equatable`, `Sources/Agents/AgentRules.swift`):

| Table / key | Type | Meaning |
|---|---|---|
| `id` | string, `[a-z0-9-]+`, equals the file stem | rule id; `NoticeSource.agent(id)`, `--agent`, `agents list` |
| `name` | string | display name |
| `process` | strings | executable basenames the scan matches (`proc_pidpath`) |
| `[fields] session / message / tool / error` | path or array of paths | where the payload keeps each |
| `[fields] summary` | path or array of paths | the sensitive one-liner for the notice body and the strip |
| `[hooks] <Event>` | state tag | plain event → state |
| `[hooks.<Event>] field` + `[hooks.<Event>.values] <value>` | path; state tags | event keyed by a payload field |
| `[notifications] "<prefix>"` | state tag | OSC fallback; matched by `hasPrefix` on the title, or on the body when the title is empty; in file order, first match wins |
| `[install] shape` | `"claude" \| "codex" \| "gemini"` | which JSON shape the installer writes (§2.6) |
| `[install] config` | string | the user-level config file, `~` expanded at use |
| `[install] lifecycle` | strings | events written at `hook-detail = "lifecycle"` |
| `[install] tools` | strings | events added at `hook-detail = "tools"` |

Unknown tables or keys fail at load (typos must not silently disable an event). Every event named under
`[install]` must be mapped under `[hooks]`. `[install]` may be absent (a user rule file for an agent with
no hooks: identity from the scan only; `hooks status` reports "no installer").

**Loading** (`AgentRulesLoader`): the bundled `Resources/agents/<id>.toml` files first (looked up with
`Bundle.main.url(forResource:withExtension:subdirectory: "agents")` and, if nil, without the subdirectory;
the test `testBundledRuleFilesLoad` asserts all three load), then `~/.config/quickterm/agents/*.toml`: a
user file whose `id` matches a bundled one **replaces** it whole; a new id adds an agent. Loaded once at
launch; a bad file is logged (OSLog, `AgentRules` category) and skipped; `agents list` shows the loaded ids.
`[agents] enabled` (§2.10) filters which loaded rules are active.

**The three bundled files** (facts from spec §2.1; the parts marked *recorded* are to be confirmed by
package A's recorded payloads and adjusted in the rule file only):

`Resources/agents/claude-code.toml`
```toml
id = "claude-code"
name = "Claude Code"
process = ["claude"]

[fields]
session = "$.session_id"
message = "$.message"
tool    = "$.tool_name"
summary = ["$.tool_input.command", "$.tool_input.file_path", "$.tool_input.pattern", "$.tool_input.url", "$.message"]
error   = "$.error_type"

[hooks]
SessionStart      = "idle"
UserPromptSubmit  = "working:thinking"
PreToolUse        = "working:tool"
PostToolUse       = "working:thinking"
PermissionRequest = "blocked:approval"
Stop              = "done"
StopFailure       = "error"
SessionEnd        = "released"

[hooks.Notification]
field = "$.notification_type"

[hooks.Notification.values]
permission_prompt  = "blocked:approval"
idle_prompt        = "idle"
agent_needs_input  = "blocked:input"
elicitation_dialog = "blocked:choice"

[notifications]
"Claude needs your permission"     = "blocked:approval"
"Claude is waiting for your input" = "idle"
"Claude Code task complete"        = "done"

[install]
shape     = "claude"
config    = "~/.claude/settings.json"
lifecycle = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "StopFailure"]
tools     = ["PreToolUse", "PostToolUse"]
```

`Resources/agents/codex.toml`
```toml
id = "codex"
name = "Codex"
process = ["codex"]

[fields]
session = "$.session_id"
message = "$.message"
tool    = "$.tool_name"
summary = ["$.tool_input.command", "$.message"]

[hooks]
SessionStart      = "idle"
UserPromptSubmit  = "working:thinking"
PreToolUse        = "working:tool"
PostToolUse       = "working:thinking"
PermissionRequest = "blocked:approval"
Stop              = "done"
Interrupt         = "idle"
SessionEnd        = "released"

# [notifications] is deliberately empty: Codex's OSC wording is not in the spec and is not guessed.
# Record it from a real session (package A's smoke) and add the prefixes here — a rule-file change.

[install]
shape     = "codex"
config    = "~/.codex/hooks.json"
lifecycle = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt"]
tools     = ["PreToolUse", "PostToolUse"]
```

`Resources/agents/gemini.toml`
```toml
id = "gemini"
name = "Gemini CLI"
process = ["gemini"]

[fields]
session = "$.session_id"
message = "$.message"
tool    = "$.tool_name"
summary = ["$.details.command", "$.details.text", "$.message"]

[hooks]
SessionStart = "idle"
BeforeAgent  = "working:thinking"
AfterAgent   = "done"
BeforeTool   = "working:tool"
AfterTool    = "working:thinking"
SessionEnd   = "released"

[hooks.Notification]
field = "$.notification_type"

[hooks.Notification.values]
ToolPermission = "blocked:approval"

# [notifications] empty for the same reason as Codex (Gemini's OSC 9 wording is not in the spec).

[install]
shape     = "gemini"
config    = "~/.gemini/settings.json"
lifecycle = ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "Notification"]
tools     = ["BeforeTool", "AfterTool"]
```

Known limitation, stated in the README: an agent that runs as an interpreter (`node …/gemini.js`) is not found
by the scan (its executable basename is `node`); its identity comes from `SessionStart`, its release from
`SessionEnd`. A `via`/argv rule is Phase 4 if it turns out to matter.

### 2.4 `AgentStateReducer` — the one place precedence lives

```swift
enum PaneSignal: Equatable {
    case hook(agent: String, payload: AgentEventPayload)
    case report(source: String, agent: String, state: AgentState, message: String?)   // Phase 3 feeds it; reduced now
    case notification(title: String, body: String)
    case processes(Set<pid_t>)          // agent pids seen for this pane in the latest scan (by rule)
    case childExited
}

struct AgentStatus: Equatable {
    let agent: String                  // rule id
    let name: String
    var state: AgentState              // idle | working | blocked | done | error | unknown
    var detail: AgentDetail?           // thinking | tool | approval | input | choice
    var tool: String?                  // a tool name: payload-free
    var message: String?               // the agent's words / the summary: sensitive
    var since: Date                    // when (state, detail) last changed
    var evidence: NoticeEvidence       // .hook | .report | .notification | .process
    var sessionID: String?
    var lastHookAt: Date?              // hook or report
    var seenByScan: Bool               // the scan has found this agent's process at least once
    var needsUser: Bool { state == .blocked || state == .error }
}

struct AgentReduction: Equatable {
    var status: AgentStatus?           // nil = released
    var kind: Kind
    enum Kind { case none, evidenceUpgrade, changed, released }
}

enum AgentStateReducer {
    static let hookRecency: TimeInterval = 5
    static func reduce(_ signal: PaneSignal, rules: AgentRules, current: AgentStatus?, now: Date) -> AgentReduction
}
```

Rules, in the order the function checks them:

1. **`.hook` / `.report` are authoritative.** Map the event through `rules.hooks` (a keyed event reads
   `field` from the payload and looks the value up in `values`; unmapped event or unmapped value → `.none`,
   but `lastHookAt = now` is still recorded on the current status, because a hook *was* heard).
   `released` → `.released`, `status = nil`. Otherwise build the new status: `tool`, `message` (summary
   first, then message), `sessionID`, `evidence = .hook`, `lastHookAt = now`, `seenByScan` carried over;
   `since = now` only if `(state, detail)` changed, else carried over. `kind = .changed` when
   `(state, detail, tool)` changed; `.evidenceUpgrade` when `(state, detail)` are equal to a current
   status whose evidence is `.notification` or `.process`; `.none` when nothing changed.
2. **`.notification` may set a state only when no hook has been heard recently**:
   `current?.lastHookAt == nil || now.timeIntervalSince(lastHookAt) > hookRecency`. Then match
   `rules.notifications` (prefix on title, or on body when the title is empty). No match → `.none`. Match
   → `evidence = .notification`, `message = body` (sensitive), `tool = nil`; `kind` as in rule 1.
3. **`.processes` is presence only.** Non-empty and `current == nil` → `unknown` with
   `evidence = .process, seenByScan = true, since = now` (`.changed`). Non-empty and `current != nil` →
   set `seenByScan = true` (`.none`). Empty and `current?.seenByScan == true` → `.released`. Empty and
   `seenByScan == false` → `.none` (an agent the scan never saw — the interpreter case — is released only
   by its `SessionEnd` hook or the pane closing).
4. **`.childExited`** → `.released` when a status exists, else `.none`.

Nothing else can contradict a hook: a notification older than the recency window that maps to a *different*
state than a fresh hook is ignored by rule 2; a process seen or unseen never changes a state that a hook set
(rule 3 only creates `unknown` or releases).

The **evidence upgrade** is what prevents one prompt becoming two alarms when the OSC text arrives a few
milliseconds *before* the `PermissionRequest` hook: the registry then updates the strip (tool name, hook
evidence) and **does not repost** the notice — the live one keeps its title (without the tool name) and is
resolved by the same rules. In the common order (hook first) the OSC is ignored by rule 2.

### 2.5 `AgentRegistry` — what it owns

`@MainActor final class AgentRegistry` in `Sources/Agents/AgentRegistry.swift`, `static let shared`, and an
`init(rules:center:bus:locator:clock:)` for tests (`bus: ControlEventBus? = nil` → `.shared`, the same
nonisolated-default-argument note as `ControlPlaneSink`).

State: `rules: [String: AgentRules]`, `statuses: [UUID: AgentStatus]`, `noticeIDs: [UUID: UUID]` (the live
`needsUser` notice this registry posted per pane), `presence: [UUID: Set<pid_t>]`, `settings: AgentSettings`,
`policy: AgentPolicy` (§2.8), `consent: ControlConsent?` (set by `AppSession`).

API:

```swift
struct AgentApplyOutcome: Equatable { var status: AgentStatus?; var changed: Bool; var noticePosted: UUID?; var resolved: Int; var refused: [UUID] }
func apply(_ signal: PaneSignal, pane: UUID, origin: NoticeOrigin?) -> AgentApplyOutcome
enum EngineSignal { case notification(title: String, body: String), commandFinished }
enum EngineSignalOutcome { case consumed, ignored }
func observeEngine(pane: UUID, _ signal: EngineSignal) -> EngineSignalOutcome
func mutesEngineNotices(pane: UUID) -> Bool          // status?.evidence is .hook or .report
func status(pane: UUID) -> AgentStatus?
func paneClosed(_ pane: UUID)                        // called from the centre's paneClosed path (see below)
func reloadRulesForTesting(_ rules: [AgentRules]); func resetForTesting()
```

`apply` does, in order: pick the rules for the signal's agent (for `.notification` and `.processes` the
registry tries every enabled rule set and takes the first that yields a non-`.none` reduction; a
`.hook` names its rules); `reduce`; then:

- `.none` → return.
- `.evidenceUpgrade` → write the status to the pane; emit nothing; post nothing.
- `.changed` / `.released` →
  1. `pane.setAgentStatus(status)` — `PaneView` gains `private(set) var agentStatus: AgentStatus?` and
     `func setAgentStatus(_:)` that sends `objectWillChange` first, exactly like `focusDidChange`. Written
     only by the registry.
  2. Emit `agent.state.changed` (§2.9) through `bus.emit(_, redactable: message != nil, producer: .agentRegistry)`,
     with `flush()` semantics unchanged. Not emitted on message-only changes (by construction of `kind`).
  3. Transition **into** `needsUser` (before: not needsUser or nil; after: needsUser) → post
     `NoticeRequest(source: .agent(id), pane:, urgency: .needsUser, evidence: status.evidence,
     title: composedTitle, body: status.message, bodySensitive: true, origin: origin)` where `origin` is
     the one handed in (hooks carry lineage + session; notifications carry nil). Remember `noticeIDs[pane]`.
     Titles (both catalogs, `Notices.strings`): `notice.agent.approval` "%1$@ · Awaiting approval · %2$@" /
     `notice.agent.approval.no-tool`; `notice.agent.input` "%1$@ · Waiting for your input";
     `notice.agent.choice` "%1$@ · Waiting for your choice"; `notice.agent.error` "%1$@ · Failed · %2$@"
     (error type) / `notice.agent.error.no-type`. Never a command line in a title.
  4. Transition **out of** `needsUser` → for a hook/report signal:
     `center.agentStateLeftNeedsUser(pane:, origin:)` → `resolved` / `refused` into the outcome. For a
     notification signal: the same call with `origin: nil` (a notification-evidenced notice stored no
     origin, so it resolves; a hook-evidenced one refuses, correctly — an OSC "task complete" cannot silence
     a hook's alarm). For `.processes` loss or `.childExited`:
     `center.resolveAll(pane:, .agentGone, urgency: .needsUser)` (§1.4).
  5. `state == .done` and `settings.done` (`[notifications] done`) → post
     `NoticeRequest(source: .agent(id), urgency: .info, evidence: .composed, title: L("notice.agent.done", name),
     bodySensitive: false)`. The system sink already presents only when the pane is inactive; `info` never
     counts toward the badge (owner decision 9).
  6. Under policy `.resolveFullyAndRearm` (§2.8): arm/cancel the re-arm timer.
  7. Trigger a scan (`ProcessScanner.shared.requestScan()`) on every hook signal.

`observeEngine`: `.notification` → `apply(.notification(...), origin: nil)`; returns `.consumed` iff the
reduction was not `.none`. `.commandFinished` → `requestScan()`, returns `.ignored`.

`childExited`: the registry installs one `NotificationCenter` observer for
`Ghostty.Notification.ghosttyChildExited` in `attach()` (called from `AppDelegate.ensureNoticeInterfaceInstalled`,
right after the centre is attached); the object is the `PaneView`, its `id` is the pane.

`paneClosed`: the registry drops `statuses[pane]` through two existing roads, and the centre learns nothing
about the registry. (1) In `attach()` the registry registers itself as a `NoticeSink` with id
`"agent-registry"` (always enabled: `NoticeSettings.isEnabled(sinkID:)` answers true for an id it does not
list) and, on `.resolved(notice, _, _)` with `resolution == .paneClosed`, drops that pane. (2) When a scan
result arrives, every pane in `statuses` that `locator.locate` no longer finds is dropped, whether or not the
scan mentioned it. A pane that closed while its agent was `working`, held no notice and no scan ran (the app
inactive) keeps a stale entry until the next scan; nothing reads it meanwhile — `agents list` and `state`
walk addressable panes and look statuses up by id — and the heartbeat clears it the moment the app is active.

The **auto-install ask** (`[agents] auto-install-hooks`): when `apply(.processes)` creates an `unknown`
status for an agent whose `HookInstaller.status(id).installed == false` and whose rules have `[install]`,
and the agent was not asked this launch (`askedThisLaunch: Set<String>`): `ask` → `consent.evaluate` with
`cls: .mutate, scope: "hooks.install:<id>", cacheable: true, peerName: "QuickTerm", peerPID: getpid(),
summary: L("agents.install.ask", name, configPath)`; `.allow` → `HookInstaller.install(id)`; `always` →
install without asking; `never` → nothing. In the test host `AgentSettings.autoInstallHooks` is forced to
`"never"` by `AppSession` when `AppDelegate.isRunningTests`.

### 2.6 Hook installation (the script, the three shapes, the marker)

**Over the socket, one installer** (answers the needsOwner finding; recommendation in §3). `hooks install |
uninstall | status` are commands implemented in the app; the CLI, the menu and the auto-install ask all end
in `HookInstaller` and share one confirmation. `hooks install` from the CLI while the app cannot show the
sheet answers `confirmation_required` (exit 4) exactly as destructive commands do.

**Command specs** (group `hooks`, appended after `notices`):

- `hooks install <agent>` — `cls: .mutate, idempotent: true, acceptsTarget: false`; args:
  `ControlArgSpec("agent", .string, help: "claude-code | codex | gemini | all — any loaded rule id", required: true, positional: true)`
  (the table is static and rule files are loaded at runtime, so the value is validated in `runHooks`
  against the loaded ids plus `all`, `bad_request` with `candidates` otherwise) and
  `ControlArgSpec("config-dir", .string, help: "write into this directory instead of the agent's own (tests; a smoke pointing CLAUDE_CONFIG_DIR at a scratch directory)")`. Runs
  through `commit(_:apply:)` with `changes = [ControlChange("hooks.<id>", from: "absent" | "lifecycle" |
  "tools" | "mixed", to: settings.hookDetail)]` (empty when already exactly installed → the usual silent
  no-op / exit 7 under `--fail-if-noop`), `undoCommand: nil`, `target: nil`. Consent: the runner's
  `needsConsent` gains `|| (spec.name == "hooks.install" && config.promptsForDestructive)`; `pin()` gains
  `case "hooks.install": return nil`; `consentSummary` gains a `hooks.install` line
  `L("consent.summary.hooks-install", name, path)`; the grant scope is `"hooks.install:<id>"` so approving
  Claude Code's file is not approving Codex's. `all` asks once per agent whose file needs a change.
- `hooks uninstall <agent>` — `cls: .mutate`, same args, no consent (it removes only entries carrying our
  marker), `changes = [ControlChange("hooks.<id>", from: <detail>, to: "absent")]`.
- `hooks status [agent]` — `cls: .read`; payload:

  ```swift
  struct ControlHooksPayload: Codable, Equatable {
      var schema = "quickterm.hooks/1"
      var script: HookScriptStatus       // path, exists, isSymlink, bakedBinary, bakedBinaryExists, ok
      var agents: [HookAgentStatus]      // id, name, configPath, configExists, installed, entries, detail ("lifecycle"|"tools"|"mixed"|nil), issue
  }
  ```

**The script** — text is a Swift constant in `Sources/Agents/HookScript.swift`; written to
`~/.config/quickterm/hooks/quickterm-agent-state.sh`, mode `0755`, directory `0700`:

```sh
#!/bin/sh
# quickterm-hook-script v1
# Installed by QuickTerm. Reports the agent's lifecycle event to the QuickTerm pane it runs in.
# Outside QuickTerm (no socket in the environment) it does nothing and exits 0 immediately,
# so the same hook entry is harmless in Terminal.app, VS Code, tmux or CI.
# The CLI path is baked in on purpose. This script runs from a trusted, user-level hook entry;
# a path taken from the environment would let a project .envrc, `nix develop` or a Makefile
# choose which binary runs on every prompt. Never read QUICKTERM_BIN here.
QT_BIN='/Applications/QuickTerm.app/Contents/SharedSupport/quickterm'
[ -n "${QUICKTERM_SOCKET:-}" ] && [ -n "${QUICKTERM_PANE:-}" ] && [ -n "${QUICKTERM_PANE_TOKEN:-}" ] || exit 0
[ -x "$QT_BIN" ] || exit 0
"$QT_BIN" agent-event --agent "$1" </dev/stdin >/dev/null 2>&1
exit 0
```

Rules: `QT_BIN` is `Bundle.main.bundleURL/Contents/SharedSupport/quickterm` of the running app, single-quoted;
a bundle path containing `'` refuses to install (`bad_request`: "the app path contains a quote"). No `exec`.
The script path already existing as a **symlink** refuses to install. The command string written into an
agent's config is `'<script path>' <agent id>` (single-quoted: Claude Code runs it under `sh -c`, and a home
directory with a space breaks an unquoted path). On launch (`AppDelegate+Agents.swift`, after
`ensureNoticeInterfaceInstalled`), the script is rewritten **only** when it exists, carries the `v1` marker
line and its baked `QT_BIN` path no longer exists on disk — never merely because a different build is running;
skipped entirely when `ConfigStore.configURLOverride != nil` (a second copy) or `AppDelegate.isRunningTests`.

**The marker is the script path inside the command string.** An entry is ours iff its `command` contains
`/quickterm-agent-state.sh` (after unquoting). No extra JSON keys for Claude Code or Codex (an unknown key
may fail their settings validation); Gemini's hook objects carry `"name": "quickterm"` as well, because its
schema documents `name`. `hooks status` and `hooks uninstall` use only the marker, so a user who wrote the
entry by hand is treated as having installed it — which is true.

**Three shapes** (`HookConfigShape` value per `[install] shape`), all "array of matcher groups, each with a
`hooks` array", all written **without** a matcher (every tool, every notification):

| shape | file | entry | timeout |
|---|---|---|---|
| `claude` | `~/.claude/settings.json` → `hooks.<Event>[] { hooks: [ { type: "command", command, async: true, timeout: 5 } ] }` | `async: true` | seconds |
| `codex` | `~/.codex/hooks.json` → `hooks.<Event>[] { hooks: [ { type: "command", command, timeout: 5 } ] }` | no `async` | seconds |
| `gemini` | `~/.gemini/settings.json` → `hooks.<Event>[] { hooks: [ { name: "quickterm", type: "command", command, timeout: 5000 } ] }` | no `async` | milliseconds |

Package B's first task is to confirm the Codex key set against the installed Codex's documentation; a
difference changes only that one `HookConfigShape` value.

**The JSON editor** (`Sources/Agents/HookConfigEditor.swift`): read with `JSONSerialization`; the top level
must be an object (else `bad_request`, nothing written); a missing file is created as `{ "hooks": {…} }`; a
config **file** that is a symlink is followed (dotfiles repos symlink `settings.json`; an atomic rename onto
the link would replace the link with a file), the **script** symlink is refused (above). Install: for each
event of the tier, append `{ "hooks": [entry] }` to `hooks[event]` unless some group already holds an entry
with our marker (then replace that entry in place, so a `hook-detail` or path change updates rather than
duplicates). Uninstall: remove our entries from every group, drop empty groups, drop empty `hooks[event]`,
drop an empty `hooks`. Write with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` to a temp file
in the same directory, preserve the original mode, rename over. No backup file: `hooks uninstall` is the
revert. Never a project-level file: the path comes from the rule file (or `--config-dir`), never from `cwd`.

**`hook-detail` changes** (`AgentSettings` hot-reload): for every agent whose config currently holds our
entries, rewrite them to the new tier without asking (the user consented to that agent's hooks and edited the
key whose help says exactly this); each rewrite records `ControlActivityLog.Entry(command: "hooks.install",
peer: "QuickTerm", outcome: "applied", changes: [hooks.<id>: <old> → <new>])`.

**Menu**: `MainMenu` gains a submenu **QuickTerm ▸ Agent Hooks** with one item per loaded rule that has an
installer, titled `L("agents.menu.install", name)` / `L("agents.menu.uninstall", name)` by current status,
and a separator plus `L("agents.menu.status")` that shows `hooks status` as an `NSAlert` (informational).
The install item calls `HookInstaller.requestInstall(id, via: consent, peerName: "QuickTerm")` — the same
consent prompt the CLI gets. Menu titles are looked up when the menu opens (`menuNeedsUpdate`).

### 2.7 The process scan (descendants only)

`Sources/Agents/ProcessScanner.swift`, `final class ProcessScanner` with `static let shared`, a serial
background queue `dev.danny.quickterm.agents.scan`, and two injectable seams for tests:
`listChildren: (pid_t) -> [pid_t]` (default `proc_listchildpids`) and `readArguments: (pid_t) -> Data?`
(default `sysctl KERN_PROCARGS2`). Algorithm per scan:

1. Descendants of `getpid()`: `listChildren` recursively (depth ≤ 16, visited set).
2. For each pid: `proc_pidpath` basename; skip unless it is in the union of every enabled rule's `process`.
   **`readArguments` is never called for any other pid** (test: `testScanNeverReadsAPidOutsideTheDescendantsOrTheNameList`
   with a recording seam).
3. For a matching pid: read the buffer, parse `QUICKTERM_PANE=<uuid>` from the environment block, keep
   `(pid, name, paneID)`, drop the buffer before the next pid.
4. Post to the main actor: `AgentRegistry.shared.apply(.processes(pids), pane: paneID)` per pane that has
   or had presence (an empty set for a pane whose agents vanished).

Triggers: `requestScan()` coalesced to one scan per 250 ms; called by the registry on every hook signal,
by `observeEngine` on notifications and `commandFinished`, on `childExited`, and by a heartbeat every 5 s
while `NSApp.isActive` (`didBecomeActive` starts it, `didResignActive` stops it). Disabled in the test host
(the registry tests drive `apply(.processes)` directly; `ProcessScannerTests` drive one scan by hand).

The README states exactly this: only QuickTerm's own descendants, only processes named by a rule file, pid
and name and our marker kept, the buffer discarded, no unrelated process ever read.

### 2.8 Q1 policy — one switch, (b) by default

`Sources/Agents/AgentPolicy.swift`:

```swift
enum AgentPolicy {
    /// §9 Q1. (b) pending the owner: a keystroke in the pane withdraws the banner and clears the Dock
    /// badge for that pane; the pane mark, the workspace count and the strip stay until a hook or the
    /// process confirms. Notification-evidenced alarms resolve fully on the keystroke — no later signal
    /// will ever come for them.
    enum UserActed { case resolveFully, clearInterruptingSinks, resolveFullyAndRearm(seconds: TimeInterval) }
    static let userActed: UserActed = .clearInterruptingSinks
}
```

Mechanics (core lands the centre half; package E the sink half):

- `Notice` gains `var quietedAt: Date?` (wire: `quietedAt` on `ControlNoticeRecord`, absent when nil).
- `NoticeChange` gains `case quieted(Notice, PaneActivity?)`.
- `NoticeCounts` gains `var interrupting: Int` = panes with at least one live `needsUser` notice that is
  **not** quieted; `needsUser` (the map) is unchanged and still counts every live alarm.
- `NoticeCenter.userDidType(in:)`: under `.resolveFully` → `resolveAll(pane:, .userActed)` (Phase 1).
  Under `.clearInterruptingSinks` → for each live notice of the pane: `urgency == .needsUser &&
  (evidence == .hook || evidence == .report)` → set `quietedAt = now` (if nil) and dispatch `.quieted`;
  everything else → resolve `.userActed`; then `countsChanged` if `interrupting` moved. Under
  `.resolveFullyAndRearm` → as `.resolveFully`; the registry, on `.resolved(_, .userActed)` for a pane whose
  status is still `needsUser` with hook evidence, arms a 30 s timer that re-posts the same request (same
  origin) if no signal changed the status meanwhile; any `apply` for that pane cancels it.
- `DockBadgeSink` shows `counts.interrupting` (was `total`). `SystemNotificationSink` withdraws the pane's
  banner on `.quieted`. `PaneChrome`'s mark and the pill read `urgency(pane:)` / `counts.needsUser` as
  today — unchanged. `notices ack` resolves quieted notices too (`resolveAll` ignores `quietedAt`).
  `notices list --needs-user` keeps listing a quieted alarm (the human started, the prompt may still be
  pending); the record carries `quietedAt`.
- The policy is read through `NoticeCenter.userActedPolicy` (a stored var defaulting to
  `AgentPolicy.userActed`) so tests set all three.

### 2.9 Control-plane additions (answers finding 3's "ride the map")

- **Commands**: `agent-event` (§2.2); `hooks install | uninstall | status` (§2.6); `agents list` — group
  `agents`, `cls: .read, idempotent: true, acceptsTarget: true` (scopes like `notices list`), payload
  `ControlAgentsPayload { schema "quickterm.agents/1", agents: [ControlAgentListEntry] }` with
  `ControlAgentListEntry { pane, paneID, screen, screenID, workspace, agent: ControlAgentRecord }` and

  ```swift
  struct ControlAgentRecord: Codable, Equatable {
      var id: String; var name: String; var state: String; var detail: String?; var tool: String?
      var message: String?; var redacted: Bool?      // message follows ControlStateEncoder.exposesNoticeBody
      var evidence: String; var sessionID: String?; var since: String   // ISO8601 (ControlEvent.stamp)
      var needsUser: Bool?
  }
  ```

- **State**: `ControlStatePayload.PaneInfo` gains `agent: ControlAgentRecord?` (encoded only when present;
  fixtures stay byte-identical). `ControlStateEncoder.paneInfo` fills it from `AgentRegistry.shared.status(pane:)`.
- **Events**: `ControlEventType` appends `agentStateChanged = "agent.state.changed"` (summary: "an
  agent's state in a terminal pane changed (agent, state, detail, tool; message is the agent's own words
  and reads <redacted> without the token)"). `ControlEvent` gains `agent`, `state`, `detail`, `tool`,
  `evidence`, `message: String?`. `ControlEventBus.redact` clears `message` when present; the title/cwd
  clause is unchanged (agent events carry neither). `ControlEventTests.testNoEventEverCarriesPaneOutput`
  adds the six fields to the closed list and the type to the type list.
- **Errors**: `origin_mismatch` (§2.2).
- **MCP**: `MCPTool(name: "quickterm_agents", title: "See what each pane's agent is doing", summary: "Per
  pane: which agent, its state (idle / working / blocked / done / error), what it is waiting for and since
  when; and whether QuickTerm's hooks are installed for each agent. Ask this before interrupting the user
  or before assuming another pane is free.", commandNames: ["agents.list", "hooks.status"])`.
  `excluded` gains `"agent-event": "Run by the hook script from inside a pane; it reports about the caller's
  own pane and is meaningless from an MCP host"`, `"hooks.install": "Edits the user's other tools' config
  files; a human runs quickterm hooks install or uses the menu"`, `"hooks.uninstall": "same as hooks.install"`.
- **CLI rendering** (`CLI/Render.swift`): `agents list` → columns `PANE AGENT STATE DETAIL SINCE MESSAGE`;
  `hooks status` → the script line then one line per agent; install/uninstall use the mutation envelope
  renderer. `agent-event` renders nothing (it never reaches `emit`).
- **Docs**: `docs/agents/quickterm-cli.md` gains an "Agents" section (`agents list`, `hooks …`, the
  `agent.state.changed` event, the `agent` pane field, `origin_mismatch`); `docs/agents/AGENTS.quickterm.md`
  gains one paragraph ("`quickterm agents list` tells you what the other panes' agents are doing; a pane
  whose agent is `blocked` is waiting for the human"); both READMEs gain the `[agents]` block and the
  `done` line verbatim from `templateAssignment` (`ConfigSchemaTests.testEveryKeyIsDocumented`) and an
  "Agent hooks" paragraph stating what the installer writes and what the scan reads.

### 2.10 Configuration

`ConfigSection` gains `case agents` **between `control` and `notifications`** (`titleZH "Agent"`,
`titleEN "Agents"`; notes: ZH "识别 pane 里的 AI agent：钩子是精确信号，进程扫描只看 QuickTerm 自己的子进程。", EN
"Recognise the AI agent in each pane: its hooks are the exact signal; the process scan reads only QuickTerm's
own descendants."). Keys, in this order, all `hotReload: true`, each with `labelZH/labelEN/helpZH/helpEN`:

| key | kind | default | help (EN, one line; ZH mirrors it) |
|---|---|---|---|
| `detect` | bool | `true` | recognise agents in terminal panes (hooks, OSC fallback, process scan) |
| `enabled` | string | `"claude-code,codex,gemini"` | comma-separated rule ids to use (the registry has no list kind; a comma list is what the config parser reads) |
| `hook-detail` | enumeration `lifecycle \| tools`, strict | `"lifecycle"` | tools adds Pre/PostToolUse (one process per tool call) and rewrites installed hooks to match |
| `auto-install-hooks` | enumeration `ask \| always \| never`, strict | `"ask"` | the first time a pane runs an agent whose hooks are missing: ask once per agent, install silently, or never |
| `info-strip` | bool | `true` | the status line in the pane's top padding; never resizes the terminal |

`[notifications]` gains `done` (bool, `true`, after `command-finished`): "a finished turn posts an info
notice when the pane is not active; never counts toward the Dock badge". `herdr-compat` is **not** added in
Phase 2 (a key that changes nothing is a silent config line — spec §4).

`ConfigStore.Settings` gains `agentsDetect`, `agentsEnabled: String`, `agentsHookDetail`,
`agentsAutoInstallHooks`, `agentsInfoStrip`, `notificationsDone`, with `ConfigBindings.table` entries.
`struct AgentSettings: Equatable` (`Sources/Agents/AgentSettings.swift`) mirrors `NoticeSettings`:
`init()`, `init(_ settings: ConfigStore.Settings)`, `enabledIDs: [String]` (split on `,`, trimmed, empty
dropped). `AppSession.applyGlobalConfig` sets `AgentRegistry.shared.settings = AgentSettings(settings)` next
to the `NoticeSettings` line; `NoticeSettings` gains `done`.

### 2.11 The info strip

`Sources/Splits/PaneAgentStrip.swift`, a SwiftUI view added as one more `.overlay` in `PaneChrome.body`
(after the mark tooltip). Inputs: `surfaceView.agentStatus` (the pane is already `@ObservedObject` there),
`theme.panePadding`, `theme.alert`, `theme.accent`, `AgentRegistry.shared.settings.infoStrip` read live
(the same "read on redraw" pattern as `notices.settings.paneMark`). Drawn only when
`settings.infoStrip && theme.panePadding >= 14 && status != nil`; the terminal surface is never resized.

Layout: a single line, height `min(panePadding, 14)`, inset `(x: 8, y: 0)` inside the top padding, font
`.system(size: 10)`, `lineLimit(1)`, `truncationMode(.tail)`; text
`"\(glyph) \(name) · \(stateText)\(tool.map { " · \($0)" } ?? "")\(message.map { ": \($0)" } ?? "")"`
clamped through `TitleRules.fromTypedInput`; the elapsed time since `since` right-aligned
(`Duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))`, refreshed by a
`TimelineView(.periodic(from:, by: 1))` only while the strip is visible). State text keys (`Agents.strings`):
`agents.strip.thinking` "Thinking", `agents.strip.tool` "Running", `agents.strip.approval` "Awaiting
approval", `agents.strip.input` "Waiting for input", `agents.strip.choice` "Waiting for your choice",
`agents.strip.idle` "Idle", `agents.strip.done` "Finished", `agents.strip.error` "Failed",
`agents.strip.unknown` "Running". Colours: `working` → `Palette.inactiveTitle` with a four-frame glyph
cycle `◐ ◓ ◑ ◒` on a 0.25 s timer (only while working); `blocked` → `theme.alert`; `error` → `theme.alert`;
`done` → green (`theme.current.color("green") ?? .green`) fading to `inactiveTitle` over 3 s after
`since`; `idle` / `unknown` → `inactiveTitle`. Click: `.onTapGesture { controller.requestFocus(to: pane) }`
on the strip's own frame only; the rest of the chrome keeps `allowsHitTesting(false)`.

The strip observes the pane only. `AgentRegistryTests.testStatusRedrawsOnlyItsPane` (1.5) pins that.

### 2.12 Strings

New table `Agents.strings` in both `.lproj` folders (keys `agents.*`: strip texts, menu titles, the
auto-install ask, `consent.summary.hooks-install` lives in the existing consent table). Agent notice titles
(`notice.agent.*`) go into the existing `Notices.strings`. Both languages in the same change;
`scripts/check-localization.py` and `LocalizationTests` gate it.

## 3. Owner questions

Recorded, not decided; the plan is buildable whichever way each goes.

**Q1 — after focus + keystroke, a hook-evidenced approval: (a) resolves fully, (b) clears banner and badge
but keeps the pane mark, count and strip until a hook confirms, or (c) (a) plus a timed re-arm?**
Recommendation: **(b)**, as the editor recommended, implemented as `AgentPolicy.userActed = .clearInterruptingSinks`
(§2.8). One cost surfaced by the rule files that the spec did not state: under the default
`hook-detail = "lifecycle"` no hook fires between the user's approval and the end of the turn
(`PostToolUse` is in the `tools` tier), so under (b) the pane mark and the red strip stay up for the rest of
that turn — minutes, not seconds — and under (a) the strip is equally stale. The only exact remedy is
`hook-detail = "tools"`. Two ways to take it: accept the cost and document it, or move `PostToolUse` alone
into the lifecycle tier for Claude Code and Codex (one extra process per tool call, half of `tools`; a one-line
rule-file change). We recommend (b) plus documenting the cost; the tier question is yours.

**Q2 — hooks install: local (the CLI edits the files itself) or over the socket (one installer in the app,
one prompt shared by CLI, menu and auto-install)?** Recommendation: **socket** (§2.6). Cost: `quickterm hooks
install` needs the app running (exit 2 otherwise) and the confirmation appears in the app; benefit: no JSON
editors or rule files in the CLI target, one code path, one prompt, and `hooks status` stays a read. Take
local only if hooks must be installable with the app not running.

**Q3 — `[agents] enabled` as a comma-separated string.** The config registry has no list kind and the
parser reads no arrays; the plan uses `"claude-code,codex,gemini"`. The alternative is a `.stringList`
`ConfigKind` (parser, template renderer and future settings window all grow a case). Confirm the string.

**Q4 — a `hook-detail` change rewrites installed hook entries without a prompt** (§2.6). Confirm; the
alternative is to leave the files alone and have `hooks status` report `mixed` until the user re-runs install.

**Q5 — the OSC fallback ships for Claude Code only.** Codex's and Gemini's notification wording is not in
the spec and is not guessed; their `[notifications]` tables are empty until recorded from a real session.
Confirm, or supply the strings.

**Q6 — under (b), which sinks are "interrupting"?** The plan clears the banner and the Dock badge and keeps
the pane mark **and the workspace pill count** (the pill is where you look for the pane). Confirm the pill
side; making it clear with the badge is one line in `AppDelegate.workspaceNoticeCounts`.

**Q7 — scan heartbeat only while the app is active** (spec §3.1). Presence loss while you are in another app
is noticed only on the next hook or when you come back. Keeping the 5 s heartbeat always on costs one
`proc_listchildpids` walk every 5 s; say if you prefer that.

## 4. Work packages

Core lands first, on one branch, green, then A–E run in parallel on disjoint files and merge in any order.
Each package owns its tests; nobody edits another package's files. `xcodegen generate` is run by whoever
adds a file; conflicts in `project.pbxproj` are resolved by regenerating.

### 4.0 Core (sequential; one implementer)

Files: `Sources/Control/Wire/AgentEventPayload.swift` (new), `ControlCommandTable.swift` (class `report`,
the five command specs, output samples), `ControlProtocol.swift` (`originMismatch`), `ControlEvent.swift`
(type + fields), `ControlStatePayload.swift` (`ControlAgentRecord`, `ControlAgentsPayload`,
`ControlHooksPayload`, `ControlAgentEventPayload`, `PaneInfo.agent`, `ControlNoticeRecord.quietedAt`),
`MCPToolMap.swift` (tool + exclusions), `ControlDescribe.swift` (class doc), `ControlRateLimiter.swift`
(report ledger), `ControlEventBus.swift` (`producer:`, `message` redaction), `Sources/Control/ControlLineage.swift`
(new), `Sources/Notices/Notice.swift` (`quietedAt`, `.agentGone`, `NoticeChange.quieted`,
`NoticeCounts.interrupting`), `NoticeCenter.swift` (1.1, 1.4, 2.8, `userActedPolicy` — nothing for the registry, which
registers an ordinary sink), `NoticeSettings.swift` (`done`), `Sources/Notices/Sinks/ControlPlaneSink.swift`
(`location(of:)`, `producer:`), `Sources/Control/Commands/ControlNoticeCommands.swift` (`location(of:)`),
`Sources/Control/ControlStateEncoder.swift` (`location(of:)` only — the `agent` field is package D's),
`Sources/Control/ControlCommandRunner.swift` (every gate and dispatch line named below — no package edits
it), `Sources/Control/Commands/{ControlAgentEventCommands,ControlHooksCommands,ControlAgentCommands}.swift`
(stubs, see below), `Sources/Agents/HookInstaller.swift` (stub, see below),
`Sources/Agents/{AgentStatus,AgentRules,AgentRulesTOML,AgentRulesLoader,AgentStateReducer,AgentRegistry,AgentPolicy,AgentSettings,PaneSignal}.swift`
(new), `Sources/Panes/PaneView.swift` (`agentStatus`), `Sources/Config/ConfigSchema.swift` +
`ConfigStore.swift` (§2.10), `Sources/Windowing/AppSession.swift` (settings push, consent handoff, test
host `never`), `Sources/App/AppDelegate+Notices.swift` (registry `attach()` after the centre),
`Resources/agents/{claude-code,codex,gemini}.toml`, `Resources/{en,zh-Hans}.lproj/Agents.strings` (strip
texts, the auto-install ask) + `Notices.strings` (the `notice.agent.*` keys) + the consent table
(`consent.summary.hooks-install`) — every key a core file references, in both languages, or
`check-localization.py` fails the build — and both READMEs (`[agents]` block, `done` line: the test requires
them the moment the keys exist).

API the packages build against: everything in §2.2 (`AgentEventPayload`, `ControlLineage`), §2.4
(`PaneSignal`, `AgentStatus`, `AgentReduction`, `AgentStateReducer.reduce`), §2.5 (`AgentRegistry.apply`,
`observeEngine`, `mutesEngineNotices`, `status(pane:)`), §2.8 (`Notice.quietedAt`, `NoticeChange.quieted`,
`NoticeCounts.interrupting`, `NoticeCenter.userActedPolicy`), §2.9 wire types, §2.10 `AgentSettings`,
§2.3 `AgentRules` with `install: AgentRules.Install?` (`shape`, `config`, `lifecycle`, `tools`).
`HookInstaller` is **declared** in core (`Sources/Agents/HookInstaller.swift`) as an enum with the signatures
package B implements — `install(id:configDir:) throws -> HookChange`, `uninstall(id:configDir:) throws ->
HookChange`, `status(id:configDir:) -> HookAgentStatus`, `scriptStatus() -> HookScriptStatus`,
`requestInstall(id:via:peerName:completion:)` — and stub bodies: `install`/`uninstall` throw
`ControlErrorBody(.internalError, "hooks are not built in this checkout")`, `status` answers
`installed: false, issue: "not built"`, `scriptStatus` answers `exists: false`, `requestInstall` completes
with `.deny`. Core is runnable and every package compiles against it; B replaces the file whole.

The same shape for the three command files: core creates `Sources/Control/Commands/ControlAgentEventCommands.swift`,
`ControlHooksCommands.swift` and `ControlAgentCommands.swift`, each holding one `ControlCommandRunner`
extension function (`runAgentEvent(_:)`, `runHooks(_:)`, `runAgents(_:)`) whose stub body throws
`ControlErrorBody(.internalError, "<command> is not built in this checkout")`; **every edit to
`ControlCommandRunner.swift`** — the report gate in `handle()`, `case "agent-event"` and the `agents` /
`hooks` group dispatch in `execute()`, the `hooks.install` consent clause, `pin()` and `consentSummary` cases
— lands in core, so no package touches the runner. A, B and D each rewrite exactly their own command file.

Tests (core's own): `Tests/AgentRulesTests.swift` — the parser grammar (each accepted form, each rejected
form with its line), the three bundled files load and validate, a user override replaces by id, every
load-time rule in §2.3 has a red case (bad path, detail/state mismatch, unknown key, installer event not
mapped). `Tests/AgentStateReducerTests.swift` — every rule in §2.4 with a fixed clock: hook precedence,
unmapped hook still bumps `lastHookAt`, notification inside/outside the recency window, OSC-before-hook
yields `.evidenceUpgrade`, presence creates `unknown` only when nothing is known, presence loss releases
only `seenByScan`, `childExited` releases, `released` tag. `Tests/AgentRegistryTests.swift` — the
transitions in §2.5 against a `NoticeCenter` with the stub locator and a recording sink: post on entering
`blocked`, no repost on evidence upgrade, resolve on leaving with the posting origin, `refused` on a foreign
origin, `.agentGone` on presence loss, `done` info post gated by `settings.done`, the event emitted once per
change with `producer: .agentRegistry` and never on message-only changes, plus the two redraw bounds of §1.5.
`Tests/NoticeCenterTests.swift` — 1.1 (location moves), 1.4 (`StateChangeOutcome`), 2.8 (all three
policies: what resolves, what quiets, `interrupting` vs `needsUser`), the duplicate-publish bound.
`Tests/ControlWireTests.swift` — the new output samples parse; `ControlEventTests` closed lists extended;
`MCPToolMapTests` green; `ConfigSchemaTests` green.

### 4.1 Package A — `agent-event`, the CLI path, lineage in anger

Files: `Sources/Control/Commands/ControlAgentEventCommands.swift` (core's stub, rewritten),
`CLI/AgentEvent.swift` (new), `CLI/main.swift` (the one branch), `Tests/ControlAgentEventTests.swift` (new),
`Tests/AgentEventPayloadTests.swift` (new), `Tests/AgentEventCLITests.swift` (new),
`Tests/Fixtures/agent-payloads/<agent>/<Event>.json` (new; hand-written from the documented schemas, a
header comment says so; replaced by recordings when a real session is available). The runner's gates are
core's (§4.0); A tests them, A does not edit them.

Proves: the report class passes the readonly and modal gates (runner with `mode = "readonly"` and
`modalBusyProbe = { true }` both accept `agent-event`; the same runner refuses `pane new`); the
per-connection and origin buckets are untouched (send 40 `agent-event`s then one `pane new` — admitted); the
report bucket refuses the 61st in a burst and admits after refill (injected clock); a missing pane token →
`bad_request`; a wrong token → `bad_request` and a `refused:` activity entry naming `xctest`; an unknown
`--agent` → `bad_request` with candidates; an `event` over 8192 bytes → `bad_request`; the server re-reduces
a hand-built payload (a 5 KB `tool_input.content` comes out at 200 chars; `transcript_path` never reaches the
registry); each fixture payload, replayed through the runner, lands on the state the rule file says (a table
of `(agent, fixture) → (state, detail, tool, needsUser)`); `PermissionRequest` posts exactly one notice with
`origin.lineageRoot == ControlLineage.root(of: getpid())` and `sessionID` from the payload; a second
`agent-event` from a request whose `origin.paneToken` is pane B's but whose peer lineage is A's cannot resolve
B's alarm → `origin_mismatch`, exit class `denied`, an activity entry, the alarm still live; `seq` moves by
exactly one per state change and not at all for a repeated `PreToolUse` of the same tool; `AgentEventPayload.reduce`
stops at 8192 bytes and drops non-string sub-values. CLI-level (`Tests/AgentEventCLITests.swift`, spawning
the built `quickterm` from `Bundle.main.bundleURL/Contents/SharedSupport/quickterm` with `Process`, skipped
when absent): with `QUICKTERM_SOCKET` pointing at a path with no listener, `agent-event` exits 0 within
50 ms with empty stdout and stderr; with no `QUICKTERM_SOCKET` at all, the same; with a 1 MB stdin, the
process reads 8192 bytes and exits 0.

Smoke: a recorded-payload replay proves the whitelist, the cap, the class gates, the lineage check and the
rule mapping end to end inside one process. Only a real session proves that Claude Code's `PermissionRequest`
hook fires with our pane's environment inherited and `async: true` accepted by the installed version, that
the hook's ppid chain reaches the pane's shell (`PROC_PIDTBSDINFO` on the platform-binary shell), the order
and timing of `PermissionRequest` versus the OSC text, and the exact OSC wording (Q5). Procedure when a
session is available: launch an isolated instance (`QUICKTERM_CONFIG_FILE`, `QUICKTERM_STATE_FILE`,
`QUICKTERM_CONTROL_SOCKET` set), `export CLAUDE_CONFIG_DIR=$(mktemp -d)` in a pane, run
`quickterm hooks install claude-code --config-dir "$CLAUDE_CONFIG_DIR"`, start `claude`, ask for a `Bash`
tool, and watch `quickterm events follow --types agent.state.changed,notice.posted,notice.resolved` from a
second pane. Record the payloads by temporarily adding a second hook entry `tee -a /tmp/hooks.log` by hand
(never via our installer) and copy them into the fixtures.

### 4.2 Package B — the hook installer, the script, the menu, the auto-install ask

Files: `Sources/Agents/{HookInstaller,HookScript,HookConfigEditor,HookConfigShape}.swift` (core's stub
`HookInstaller.swift` is replaced whole), `Sources/Control/Commands/ControlHooksCommands.swift` (core's
stub, rewritten), `Sources/App/MainMenu.swift` (submenu), `Sources/App/AppDelegate+Agents.swift` (new: launch
self-heal, the registry's ask entry point), `Resources/*/Agents.strings` (menu keys — B appends to the table
core created; the ask and consent keys are core's because core's code references them), `Tests/HookInstallerTests.swift`
(new), `Tests/HookScriptTests.swift` (new).

Proves (all against temp `--config-dir`s; the user's real files are never touched by a test — a test that
computes a path under `~` without `--config-dir` fails by assertion): install writes exactly the events of
the tier for each shape (byte-compare against golden JSON per shape × tier); everything else in a
pre-existing file survives (keys, values, a user's own hook entry in the same event group); install twice is
byte-identical (idempotent) and `changed == false` the second time; `hook-detail` change rewrites entries
in place without duplicating; uninstall removes exactly ours and leaves the user's entry, drops empty groups
and an empty `hooks`; a non-object file is refused and left untouched; a symlinked config file is written
through (the link survives); a symlinked script path refuses to install; the script is `0755`, contains the
`v1` marker and a single-quoted `QT_BIN`; the command string is single-quoted; a bundle path with `'` is
refused; the launch self-heal rewrites only when the baked path is gone, never for a different build, never
with `configURLOverride` set. Script behaviour (run the written script with `/bin/sh` via `Process`): with no
`QUICKTERM_SOCKET` it exits 0 in under 50 ms with empty stdout/stderr; with the socket set and `QT_BIN`
pointing at a missing file, exit 0; with `QT_BIN` pointing at a stub that exits 2, still exit 0; stdin is
passed through to the stub (the stub echoes its byte count to a temp file). Consent: `hooks install` from the
harness prompts through `ControlConsent` with scope `hooks.install:claude-code`, a second install of the
same agent in the same launch does not prompt, `all` prompts once per agent; the auto-install ask fires once
per agent per launch under `ask`, installs silently under `always`, never under `never`.

Smoke: only a real Claude Code / Codex / Gemini can prove the shapes are accepted (no "invalid settings"
warning at start-up, the hook listed by `claude /hooks`), which is package B's first task for Codex.

### 4.3 Package C — the process scan

Files: `Sources/Agents/ProcessScanner.swift` (new), `Tests/ProcessScannerTests.swift` (new),
`Tests/ControlLineageTests.swift` (new).

Proves: with recording seams, a synthetic tree (QuickTerm → shell → `claude` → `sh` → `quickterm`; a
sibling `node` server; an unrelated pid not in the tree) yields `readArguments` calls for the `claude` pid
only — never the server, never the shell, never the outsider; the marker is parsed from the environment
block and the buffer released; a pane whose agent vanished gets an empty set; the 250 ms coalescing.
Against a **real child process** — a non-platform one, because a platform binary's environment (`/bin/sleep`,
`/usr/bin/env`, `sh`) is invisible even to its parent (spec §2.3), and the test says so in a comment: start a
`ControlServer` at a temp socket path (as `ControlServerTests.makeServer(at:)` does), then spawn the bundled
CLI `Bundle.main.bundleURL/Contents/SharedSupport/quickterm` (ad-hoc signed by this build, hence
non-platform) as `quickterm events follow --socket <path>` with `QUICKTERM_PANE=<uuid>` in its environment —
it streams until killed, so it stays alive for the scan. A test rule with `process = ["quickterm"]`; one real
scan with the default seams finds that pid under that pane, and `readArguments` was called for it alone.
Skipped (`XCTSkip`) when the CLI is not in the bundle, the same skip as `AgentEventCLITests`.
`ControlLineage.root(of:)`: spawn `/bin/sh -c 'sleep 30 & echo $!; wait'`, read the grandchild pid from
stdout, assert `root(of: grandchild) == sh.processIdentifier`; the test's own parent pid (not a descendant)
returns nil; a depth-33 chain is not walked (`maxDepth`).

Smoke: a real agent in a real pane appears in `agents list` as `unknown`/`process` before any hook fires;
`claude` exiting resolves a pending alarm as `agent-gone` within the heartbeat.

### 4.4 Package D — the strip, `agents list`, state and docs

Files: `Sources/Splits/PaneAgentStrip.swift` (new), `Sources/Splits/PaneChrome.swift` (one overlay line),
`Sources/Control/Commands/ControlAgentCommands.swift` (core's stub, rewritten; `runAgents(_:)` is already
dispatched by core's `case "agents"` line), `Sources/Control/ControlStateEncoder.swift` (`PaneInfo.agent`), `CLI/Render.swift`,
`docs/agents/quickterm-cli.md`, `docs/agents/AGENTS.quickterm.md`, both READMEs ("Agent hooks" paragraph;
the config lines are core's), `Tests/ControlAgentsTests.swift` (new), `Tests/PaneAgentStripTests.swift` (new).

Proves: `agents list` scopes by target like `notices list`; `message` is `<redacted>` with `redacted: true`
for a token-less caller in `agents list`, `state --json` and `events poll`, and present with the token;
`state` panes carry `agent` only when a status exists (fixtures byte-identical otherwise); the strip is not
drawn when `pane-padding < 14`, when `info-strip = false`, or when the pane has no status; text and colour per
state (a pure `PaneAgentStrip.Model.make(status:now:)` function tested without SwiftUI); the elapsed time
formats; the strip's hit-test rect is its own frame only; every new command has an output sample that
parses (`ControlWireTests`); `describe` lists the new class, code, event and tool; `quickterm_agents` is
read-only by annotation.

Smoke: with `hook-detail = tools` and a real session, the strip follows tool calls without visible lag and
the frame of the neighbouring pane does not flicker (the redraw bound of §1.5, observed).

### 4.5 Package E — the engine seams and the interrupting sinks

Files: `Sources/GhosttyEmbed/Ghostty.App.swift` (`GhosttyNoticeProducer` only), `Sources/Notices/Sinks/SystemNotificationSink.swift`
(`.quieted`), `Sources/Notices/Sinks/DockBadgeSink.swift` (`interrupting`), `Sources/App/AppDelegate+Notices.swift`
(nothing — the registry `attach()` is core's), `Tests/NoticeSourcesTests.swift` (extend),
`Tests/NoticeSystemSinkTests.swift` (extend), `Tests/NoticeSinkTests.swift` (extend).

Proves: an OSC notification that a rule consumes posts no `.terminal` notice; one that no rule matches posts
the `.terminal` info as before; while a pane's status has hook evidence, neither the OSC nor a long
`commandFinished` posts anything, and both still reach `observe` (a recording seam); `bell` is unaffected;
`resetForTesting` restores the seams; the Dock badge shows `interrupting` (two alarms, one quieted → `1`;
both quieted → nil; the pane mark of the quieted pane still draws); the banner is withdrawn on `.quieted`
and not re-presented until a superseding `needsUser`; `didReceive` still leaves a quieted notice live.

Smoke: a real Claude Code prompt with hooks installed shows one banner, one badge; pressing an arrow key in
the pane clears the banner and the badge, the mark stays, approving the tool and letting the turn finish
clears the mark (through `Stop` under `lifecycle`, through `PostToolUse` under `tools`).

### 4.6 What replay proves and what only a real session proves

Recorded-payload replay (packages A, core) proves everything that happens **after** a hook process reaches
our socket: the whitelist and the cap, the class gates, the token and lineage checks, the rule mapping, the
notice and event behaviour, the sinks. It proves nothing about the agents themselves: that the installed
Claude Code / Codex / Gemini accept our config entries, that the hook inherits the pane's environment, that
`async: true` behaves, the ppid chain through the agent's process tree, the real ordering of hook versus
OSC, the OSC wording, and macOS notification permission surviving a rebuild (spec §8). Each of those is named
in the package that owns it; none blocks the merge, and each is a fact to record in the rule file or the
README when a session is available.

## 5. Delivery

Core → branch, tests, full suite, review, merge. Then A–E in parallel from `main`, each: branch → implement
→ own tests → full suite → adversarial review → fix → full suite → merge. After all five: rebuild Debug,
restart the app with hooks installed for whichever agent is on this machine, run the smokes above, update
`docs/agents/*` and the READMEs with what the session taught, and only then consider a release
(third-level version bump per `release-versioning.md`).
