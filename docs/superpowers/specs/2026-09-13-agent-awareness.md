# Agent awareness: knowing what each pane's AI agent is doing, and asking for the user only when needed

Status: **confirmed by the owner (2026-09-13), implementation in progress.** v1 was reviewed by the
owner; every decision is recorded in §7.

## 1. What is being asked for

QuickTerm runs several AI coding agents at once — Claude Code, Codex, Gemini CLI, others — each in its
own terminal pane.

1. **Know what each pane is doing.** Which agent, and in which state: waiting for input, thinking,
   running a tool, waiting for the user's approval, waiting for the user's choice, finished, failed.
   Show it on an info strip on the pane.
2. **Ask for the user only when a human is needed, and stop asking once they act.** One system
   notification per pane, a red count on the Dock icon, a red mark on the pane, a red count on the
   workspace pill. The user opens the app, activates the pane and handles it; the marks go away.
3. Both built as **foundations**: agent recognition is a plugin system (many agents, all changing);
   the notification center is a general service any future feature can post into.

Owner's constraints (2026-09-13): **deterministic signals only — no screen scraping**; the info strip
must never resize the terminal; notify only when the pane is not active; a bare bell is not a notice;
no approve/deny actions from the notification — the human opens the app and acts in the pane. And:
study herdr, reuse its integrations if possible, prefer the agents' own hooks because they are exact.

## 2. Facts the design rests on

### 2.1 The agents expose lifecycle hooks — that is the exact signal

All three first-wave agents run a user-supplied command on lifecycle events and deliver a JSON
description on stdin. The hook process **inherits the pane's environment**, so it carries QuickTerm's
own `QUICKTERM_PANE`, `QUICKTERM_SOCKET` and `QUICKTERM_PANE_TOKEN`. A hook therefore knows exactly
which pane it is speaking for, and can prove it.

| Agent | Config | Events we use | Approval signal | Source |
|---|---|---|---|---|
| Claude Code | `~/.claude/settings.json` → `hooks` (user level; merges with project hooks) | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PermissionRequest`, `Notification` (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog`), `Stop`, `StopFailure` (`error_type`); optional `PreToolUse` / `PostToolUse` | `PermissionRequest` (`tool_name`, `tool_input`) and `Notification.permission_prompt` (`message`) | [hooks reference](https://code.claude.com/docs/en/hooks) |
| Codex CLI | `~/.codex/hooks.json` → `hooks` (on by default in current releases) | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PermissionRequest`, `Stop`, `Interrupt`; optional `PreToolUse` / `PostToolUse` | `PermissionRequest` (shell escalation, network) | [Codex hooks](https://learn.chatgpt.com/docs/hooks) |
| Gemini CLI | `~/.gemini/settings.json` → `hooks` | `SessionStart`, `SessionEnd`, `BeforeAgent`, `AfterAgent`, `Notification` (`notification_type: "ToolPermission"`); optional `BeforeTool` / `AfterTool` | `Notification.ToolPermission` (`message`, `details`) | [hooks reference](https://geminicli.com/docs/hooks/reference/) |

Common contract: stdin JSON with `hook_event_name`, `session_id`, `cwd`; exit 0 with no stdout means
"no decision"; the hook must never print JSON (we never want to influence the agent) and must never
block it (Claude Code supports `async: true`; we set short timeouts everywhere).

### 2.2 The agents also announce themselves over the terminal

Independently of hooks, the three emit desktop notifications (OSC 9 / 99 / 777) that libghostty
already parses into `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` with a `title` and `body`: Claude Code's
`preferredNotifChannel` (default `auto`) on finish / permission; Codex's
`[tui] notifications = ["agent-turn-complete", "approval-requested"]`; Gemini's OSC 9 on idle /
confirmation. The text is the agent's own fixed wording — matching it is deterministic. This is the
fallback when hooks are not installed, not the primary path.

### 2.3 Which process is in which pane — without a pty

libghostty exposes no pid or pty for a surface. But every pane's shell is spawned with
`QUICKTERM_PANE=<uuid>`, and macOS lets a process read the arguments and environment of another
process of the same uid (`sysctl KERN_PROCARGS2`, what `ps -E` uses). A scan of the process table,
filtered on our own marker, maps processes to panes. Deterministic, engine-free, cheap.

### 2.4 What herdr does, and what is worth reusing

herdr ([herdr.dev](https://herdr.dev/docs/integrations/), [repo](https://github.com/ogulcancelik/herdr),
Apache-2.0, Rust) is a terminal multiplexer built around agents. Its detection has two halves:

- **Screen manifests** — TOML rules matched against a snapshot of the pane's bottom lines. This is
  where its Claude Code and Codex *state* comes from today. **We do not take this half** (owner's
  decision: no scraping).
- **Lifecycle authority** — an agent-side plugin/hook reports semantic state straight to herdr's
  socket. Six agents do this natively (Pi, OMP, Kimi Code CLI, OpenCode, Kilo Code CLI, MastraCode);
  eleven more report only *session identity* through a `SessionStart` hook. The protocol is tiny and
  public: the pane gets `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_BIN_PATH`, `HERDR_SOCKET_PATH`; a plugin
  runs `"$HERDR_BIN_PATH" pane report-agent "$HERDR_PANE_ID" --source … --agent … --state
  idle|working|blocked|done|unknown [--message …]`, `pane release-agent …`,
  `pane report-agent-session …`, `pane report-metadata …`; the socket speaks newline-delimited JSON
  with `pane.report_agent` / `pane.report_agent_session` / `pane.release_agent` /
  `pane.report_metadata`.

**What we reuse:** the state vocabulary (`idle / working / blocked / done / unknown`) as our coarse
level, so anything written for herdr means the same thing here; and the protocol itself as a
**compatibility shim** — if QuickTerm injects those four variables pointing at itself and implements
the four `pane report-*` commands with the same flags, every herdr integration file reports into
QuickTerm unmodified. That is eighteen agents' worth of plugins we do not have to write, including
the six that report real state. Their installers (`herdr integration install <agent>`) write the
plugin files; Apache-2.0 lets us vendor those installers with attribution, or users can run herdr's
own installer.

**What we do better than herdr on the first three agents:** herdr uses Claude Code and Codex hooks for
identity only and scrapes the screen for state. Their hook systems carry `PermissionRequest`,
`Notification`, `Stop`, `StopFailure` — exact state, no scraping. We use them.

### 2.5 Surfaces that already exist in QuickTerm

The pane frame (`PaneChrome` / `PaneFrame`) already breaks its top border for a title; the workspace
pill (`WorkspacePill`) already budgets its width before drawing names; the control plane has a typed
event bus, a command table that generates `--help`, `describe` and the MCP tools, an activity log and
the HMAC pane token (`QUICKTERM_PANE_TOKEN`) that proves which pane a caller sits in. All of it is
reused; none of it is duplicated.

## 3. Architecture

```
  agent hooks ──▶ quickterm agent-event ──┐
  OSC 9/99/777 (engine) ──────────────────┼──▶ PaneSignals ──▶ AgentRegistry (adapters) ──▶ AgentStatus / pane
  process scan on QUICKTERM_PANE ─────────┤                                                      │
  herdr-protocol reports (shim) ──────────┘                                                      ▼
                                                                                           NoticeCenter ◀── any feature
                                                                                                 │
                        system notification · Dock badge · pane mark · workspace count · events + CLI · activity log
```

Three layers; each is usable without the one above it.

### 3.1 `PaneSignals` — one normalised, deterministic feed per pane

```swift
enum PaneSignal {
    case hook(agent: String, event: String, payload: JSONValue)      // from quickterm agent-event
    case report(source: String, agent: String, state: CoarseState, message: String?)  // herdr-protocol
    case notification(title: String, body: String)                  // OSC 9 / 99 / 777, engine-parsed
    case processes([ProcessInfo])                                    // pid, name, argv, start time
    case childExited
}
```

No screen text. `pane capture-text` stays a CLI feature for agents that want it; detection never
calls it.

The process scan runs on a background queue: on every hook event, every notification, every
`commandFinished` (OSC 133) and a slow heartbeat (every 5 s while the app is active), and posts
results to the main actor. It reads nothing but pid, name, argv[0] and our marker.

### 3.2 `AgentRegistry` — adapters, mostly as data

```swift
protocol AgentAdapter {
    var id: String { get }                          // "claude-code"
    var displayName: String { get }                 // "Claude Code"
    var processNames: [String] { get }              // ["claude"]
    /// Fold one signal into the pane's status; nil = no change.
    func reduce(_ signal: PaneSignal, into current: AgentStatus?) -> AgentStatus?
    /// How to install and remove this agent's hooks (nil = no hooks; identity via process scan only).
    var hooks: HookInstaller? { get }
}

struct AgentStatus: Equatable {
    let agent: String
    let state: CoarseState          // idle | working | blocked | done | error | unknown  (herdr-compatible + error)
    let detail: Detail?             // .thinking | .tool(name) | .approval(tool, summary) | .choice | .input
    let message: String?            // the agent's own words; redactable like a browser URL
    let since: Date
    let evidence: Evidence          // .hook | .report | .notification | .process
    let sessionID: String?          // the agent's own session id when a hook told us
}
```

`needsUser` is `state == .blocked || state == .error`. `done` is information, not a demand.

**Adapters are TOML rule files** (`Resources/agents/<id>.toml`, user overrides in
`~/.config/quickterm/agents/`) for the parts that are data — process names, the hook map, the
notification map — and Swift for the installers, which have to edit JSON safely:

```toml
id = "claude-code"
name = "Claude Code"
process = ["claude"]

[hooks]                                   # hook_event_name -> state (+ detail from the payload)
SessionStart       = "idle"
UserPromptSubmit   = "working:thinking"
PreToolUse         = "working:tool"       # opt-in tier ("hook-detail = tools")
PostToolUse        = "working:thinking"
PermissionRequest  = "blocked:approval"   # tool_name + tool_input summarised into message
Stop               = "done"
StopFailure        = "error"
SessionEnd         = "released"
[hooks.Notification]                      # keyed on notification_type
permission_prompt  = "blocked:approval"
idle_prompt        = "idle"
agent_needs_input  = "blocked:input"
elicitation_dialog = "blocked:choice"

[notifications]                           # OSC text -> state, exact prefixes, used when hooks are absent
"Claude needs your permission" = "blocked:approval"
"Claude is waiting for your input" = "idle"
"Claude Code task complete"    = "done"
```

Precedence: a `hook` or `report` signal is authoritative; a `notification` may set a state only when
no hook has been heard from that pane in the last few seconds (hooks not installed); a process
scan only establishes *presence* (`unknown` on first sight, `released` on disappearance). Nothing can
contradict a hook except a later hook or the process going away.

First wave, bundled: **Claude Code, Codex, Gemini CLI.** Every other agent is a rule file, or arrives
through the herdr shim.

### 3.3 Hooks: installing them, and the `agent-event` command

**One script for every agent**, written to `~/.config/quickterm/hooks/quickterm-agent-state.sh`:

```sh
#!/bin/sh
# Installed by QuickTerm. Reports the agent's lifecycle event to the QuickTerm pane it runs in.
# Outside QuickTerm (no socket in the environment) it does nothing and exits 0 immediately,
# so the same hook entry is harmless in Terminal.app, VS Code, tmux or CI.
[ -n "${QUICKTERM_SOCKET:-}" ] && [ -n "${QUICKTERM_PANE:-}" ] || exit 0
[ -x "${QUICKTERM_BIN:-}" ] || exit 0
exec "$QUICKTERM_BIN" agent-event --agent "$1" </dev/stdin >/dev/null 2>&1
```

`QUICKTERM_BIN` is a new variable injected into every pane (the absolute path of the bundled CLI in
`Contents/SharedSupport`), so hooks never depend on PATH. Codex passes its `notify` payload as an
argument rather than stdin — but we use Codex's `hooks.json`, which is stdin like the others, and
leave `notify` alone.

**Registration** is idempotent and exact: each entry we write carries a marker (`"name":
"quickterm"` / the script path), so `hooks status` can tell ours from the user's and `hooks uninstall`
removes exactly ours. JSON files are parsed and rewritten preserving everything else (Claude:
`settings.json`; Codex: `hooks.json`; Gemini: `settings.json`). Claude Code entries use
`"async": true` and `"timeout": 5`; all three get the smallest timeout the agent allows. We never
touch a project-level settings file — user level only.

**Two detail levels**, because tool hooks fire on every tool call (dozens a minute, one process each):
`[agents] hook-detail = "lifecycle"` (default: session, prompt, permission, notification, stop,
failure — everything the notices need) or `"tools"` (adds Pre/PostToolUse for the "running Bash"
strip detail).

**Getting the hooks installed** — never silently editing another tool's config:
- `quickterm hooks install claude-code|codex|gemini|all`, `hooks uninstall …`, `hooks status`; a
  menu item under QuickTerm ▸ Agent Hooks…;
- `[agents] auto-install-hooks = "ask"` (default) — the first time a pane is seen running an agent
  whose hooks are not installed, one in-app prompt per agent: "Install QuickTerm's Claude Code hooks?
  This adds one entry to ~/.claude/settings.json; nothing else changes." `"always"` and `"never"`
  exist for people who have decided.

**`quickterm agent-event --agent <id>`** — the command the hook runs. It reads the stdin JSON and
sends it over the socket. Trust: the caller must carry the `QUICKTERM_PANE_TOKEN` of the pane it
reports for (the HMAC we already verify for `send-text`), so a process can only ever describe the
pane it lives in. Class: mutate, but **silent** — no status-bar flash, no undo entry, no consent; it
fires constantly and changes nothing but a status. Rate-limited per pane; payloads capped at 8 KB;
only `hook_event_name`, `notification_type`, `tool_name`, `session_id`, `error_type` and a summary of
`message` / `tool_input` are kept.

### 3.4 herdr protocol compatibility (the shim)

Behind `[agents] herdr-compat = true|false`:

- panes additionally get `HERDR_ENV=1`, `HERDR_PANE_ID=<our pane uuid>`, `HERDR_BIN_PATH=$QUICKTERM_BIN`,
  `HERDR_SOCKET_PATH=$QUICKTERM_SOCKET`;
- the CLI accepts `quickterm pane report-agent <pane> --source S --agent A --state idle|working|blocked|done|unknown [--message M]`,
  `pane release-agent <pane> --source S --agent A`, `pane report-agent-session <pane> … --agent-session-id ID`,
  `pane report-metadata <pane> …` (display-only; we honour `title` and `display_agent`, ignore the rest);
- the socket accepts the JSON methods `pane.report_agent`, `pane.report_agent_session`,
  `pane.release_agent`, `pane.report_metadata` with herdr's field names.

A report from a herdr integration is a `.report` signal: authoritative like a hook. This is how
OpenCode, Pi, Kimi and the others arrive without a line of adapter code.

Why it is a switch: `HERDR_ENV=1` tells herdr-aware tools they are inside herdr, and some of them
(herdr's own Claude skill, for one) will then try to drive herdr's *other* commands through
`HERDR_BIN_PATH` and fail. Default **off** until the owner has tried it; documented as such.

### 3.5 `NoticeCenter` — the general notification center

```swift
struct Notice: Identifiable, Codable {
    let id: UUID
    let source: NoticeSource         // .agent(id) | .command | .download | .control | .custom(String)
    let pane: UUID?
    let screen: UUID; let workspace: Int
    let title: String
    let body: String?                // redactable
    let urgency: Urgency             // .needsUser | .info
    let postedAt: Date
    var resolvedAt: Date?
    var resolution: Resolution?      // .stateChanged | .userActed | .acknowledged | .paneClosed
}

@MainActor final class NoticeCenter: ObservableObject {
    func post(_ n: Notice, coalescingKey: String)          // one live notice per key; a new post REPLACES it
    func resolve(_ id: UUID, _ how: Resolution)
    func resolveAll(pane: UUID, _ how: Resolution)
    var live: [Notice]
    func count(needsUser screen: UUID? = nil, workspace: Int? = nil) -> Int
    func addSink(_ sink: NoticeSink)
}
```

**Sinks** (each independent, each switchable):

| Sink | Behaviour |
|---|---|
| System notification | `UNUserNotificationCenter`, identifier = the pane's uuid, so an update replaces rather than stacks — **one per pane**. Posted only when the pane is not active: the app is not frontmost, or the pane's screen is not key, or its workspace is not the visible one, or the pane is not focused. Click → activate the app, that screen, that workspace, focus that pane. No action buttons. Replaces the engine's direct OSC→macOS path so nothing fires twice. |
| Dock badge | `NSApp.dockTile.badgeLabel` = live `needsUser` count across all screens; cleared at zero. |
| Pane mark | Red dot at the pane's top-right corner drawn by `PaneFrame` (the border breaks around it like the title does); tooltip = the notice title. |
| Workspace pill | `dev ●2` / `3 ●1` — live `needsUser` count for that workspace, in the accent red; a term in `WorkspacePill`'s width budget, so the whole row still falls back together when it does not fit. |
| Control plane | events `notice.posted` / `notice.resolved`; `quickterm notices list [--needs-user]`, `quickterm notices ack -t t7`; `state --json` carries `notices` per pane and per workspace. |
| Activity log | every post and resolution; body redacted in the OSLog mirror. |

**Resolution** — a `needsUser` notice ends when any of:
1. the pane's agent state leaves `blocked`/`error` (a hook said so: `PostToolUse` after a
   `PermissionRequest`, `UserPromptSubmit` after `idle_prompt`, `Stop`, `SessionEnd`) — `stateChanged`;
2. the user focuses the pane and sends it a keystroke — `userActed` (optimistic; a fresh request
   posts a fresh notice);
3. the user acknowledges it — clicking the system notification, or `notices ack`;
4. the pane closes.

No timeout. An unanswered approval stays visible until it is answered. `info` notices (`done`, a
finished download) resolve when the pane is focused.

**Sources beyond agents in Phase 1**: the engine's own OSC notifications from any program (info), and
`commandFinished` for long commands (info, `[notifications] command-finished = "long"`). Bell:
ignored by default (`bell = "ignore" | "info"`).

### 3.6 The info strip — in the padding, never a resize

```
 ◐ Claude Code · Awaiting approval · Bash: npm test                       2m 14s
```

Drawn as an overlay inside the pane's top padding (`pane-padding`, default 14 pt), the same way the
title badge lives on the border: the terminal surface is never resized, so a running TUI never
reflows. If the padding is smaller than the strip needs (≈14 pt), the strip is simply not drawn —
the pane mark and the notifications still work. State colours: `working` dim with a spinner,
`blocked` accent red, `error` alert red, `done` green fading after a few seconds, `idle` dim. The
message is the agent's own text, clamped through `TitleRules`. Click → focus the pane.
`[agents] info-strip = true|false`.

## 4. Configuration

Two new groups (each becomes a settings tab):

```toml
[agents]
# detect = true                     # recognise agents in terminal panes
# enabled = ["claude-code", "codex", "gemini"]
# hook-detail = "lifecycle"         # lifecycle | tools — tools adds Pre/PostToolUse (one process per tool call)
# auto-install-hooks = "ask"        # ask | always | never
# info-strip = true                 # overlay in the top padding; never resizes the terminal
# herdr-compat = false              # speak herdr's integration protocol so herdr plugins report here

[notifications]
# system = "inactive"               # inactive (pane not focused / workspace hidden / app not frontmost) | never
# done = true                       # a finished turn posts an info notification (what the agents do themselves today)
# dock-badge = true
# pane-mark = true
# workspace-count = true
# bell = "ignore"                   # ignore | info
# command-finished = "long"         # never | long | always  (OSC 133, commands over 10 s)
```

## 5. Control plane

- `quickterm agent-event --agent <id>` — the hook's reporting command (mutate, silent, pane-token-bound).
- `quickterm agents list` — per pane: agent, state, detail, evidence, message (redacted for
  token-less callers), session id, since. Class `read`.
- `quickterm hooks install|uninstall|status [agent|all]` — class `mutate`, with a confirmation
  the first time it edits a given tool's config file.
- `quickterm notices list [--needs-user]`, `quickterm notices ack -t <pane>`.
- `state --json`: pane gains `agent {id, state, detail, evidence, since}` and `notices`; workspace
  gains `notices`.
- Events: `agent.state.changed`, `notice.posted`, `notice.resolved`.
- MCP: `quickterm_agents`, `quickterm_notices`, generated from the same table.
- herdr shim commands and socket methods as in §3.4.
- `AGENTS.quickterm.md`: "before asking the human, ask `quickterm notices list --needs-user`".

## 6. Phases

**Phase 1 — NoticeCenter and its sinks, on today's signals.** The center, the six sinks, resolution
rules, `[notifications]`, `notices` CLI and events; the engine's OSC path routed through it so there
is one owner; `commandFinished` as an info source. Verify on this machine that notification
permission (granted per bundle id) survives a rebuild. Tests: coalescing per pane, resolution on
focus + keystroke, counts across two screens, pill width budget with counts, click-to-focus routing.

**Phase 2 — Hooks and the agent registry.** `agent-event` with pane-token trust; the hook script and
the three installers (JSON edits that preserve everything else, marker, idempotent, uninstall);
`auto-install-hooks = ask`; `PaneSignals` (hook, notification, process scan); the rule-file loader;
bundled rules for Claude Code, Codex and Gemini CLI; the info strip; `agents list`;
`agent.state.changed`. Tests: rule parsing; the hook → state maps against recorded payloads from the
three agents' documented schemas; process→pane mapping with a real child process; that the hook
script exits 0 instantly outside QuickTerm; that a report with the wrong pane token is refused.

**Phase 3 — herdr compatibility.** The env variables, the four `pane report-*` commands, the socket
methods, `.report` signals in the reducer. Validate against two real herdr integrations (OpenCode's
plugin, Pi's extension). Decide then whether to vendor herdr's installers for the six
lifecycle-authority agents (Apache-2.0, attribution).

**Phase 4 — Reach and docs.** `hook-detail = tools` strip details, more rule files as agents are
confirmed, MCP tools, READMEs, the drop-in agent doc.

## 7. Decisions taken by the owner (2026-09-13) and the ones still open

Taken:
1. Study herdr; reuse where possible; prefer agent hooks because they are exact → §2.4, §3.3, §3.4.
2. Info strip in the padding, never a resize → §3.6.
3. System notification only when the pane is not active → §3.5.
4. A bare bell is not a notice by default → `bell = "ignore"`.
5. No screen scraping; deterministic only → tier 3 deleted; `PaneSignals` carries no screen text.
6. No approve/deny from the notification; the human opens the app and acts → no notification actions.

Taken in the second round (2026-09-13):
7. Hook detail default is `lifecycle`; `tools` stays opt-in.
8. Hooks are installed after asking once per agent (`auto-install-hooks = "ask"`).
9. A finished turn posts an info notification when the pane is not active; it does not count
   toward the Dock badge.
10. herdr compatibility ships behind a switch that is off by default.
11. First wave: Claude Code, Codex, Gemini CLI.

## 8. Risks named up front

- **Hooks are the agents' contract, and contracts move.** Event names and payload fields are in
  rule files, not code, so a rename is a rule-file fix. The hook script is defensive: it exits 0
  silently on anything unexpected, so a broken assumption degrades to "unknown", never to a stuck
  agent or a transcript full of "hook error".
- **We are editing other tools' config files.** Only at user level, only with a marker, only after
  the user said yes (or set `always`), always reversible, never a project file.
- **Process scanning reads other processes' environments.** Same uid, our marker, pid + name only.
  Stated in the README.
- **Message bodies can carry command lines** (`Bash: rm -rf build`). Redacted for token-less callers
  and in the OSLog mirror, exactly like browser URLs.
- **herdr compat can confuse herdr-aware tools** — hence the switch, default off.
- **Notification permission** is per bundle id; verify on this machine in Phase 1 that it survives
  an ad-hoc re-sign (the engine's existing path suggests it does).
