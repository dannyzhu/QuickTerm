# Agent awareness: knowing what each pane's AI agent is doing, and asking for the user only when needed

Status: **confirmed by the owner (2026-09-13), implementation in progress.** v1 was reviewed by the
owner; every decision is recorded in §7. **Round 3 (2026-09-13): the review findings were merged
by the design's editor** — accepted findings are folded into §2–§6 and §8 (each edit says which
finding it answers), the one question that changes behaviour the owner decided is recorded in §9
without changing the design, and §10 is the Phase 1 API contract that four implementers build
against without talking to each other.

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
own `QUICKTERM_PANE`, `QUICKTERM_SOCKET` and `QUICKTERM_PANE_TOKEN`. A hook therefore knows which pane
it is speaking for and carries that pane's origin marker (what the marker does and does not prove is
measured in §2.3).

| Agent | Config | Events we use | Approval signal | Source |
|---|---|---|---|---|
| Claude Code | `~/.claude/settings.json` → `hooks` (user level; merges with project hooks) | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PermissionRequest`, `Notification` (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog`), `Stop`, `StopFailure` (`error_type`); optional `PreToolUse` / `PostToolUse` | `PermissionRequest` (`tool_name`, `tool_input`) and `Notification.permission_prompt` (`message`) | [hooks reference](https://code.claude.com/docs/en/hooks) |
| Codex CLI | `~/.codex/hooks.json` → `hooks` (on by default in current releases) | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PermissionRequest`, `Stop`, `Interrupt`; optional `PreToolUse` / `PostToolUse` | `PermissionRequest` (shell escalation, network) | [Codex hooks](https://learn.chatgpt.com/docs/hooks) |
| Gemini CLI | `~/.gemini/settings.json` → `hooks` | `SessionStart`, `SessionEnd`, `BeforeAgent`, `AfterAgent`, `Notification` (`notification_type: "ToolPermission"`); optional `BeforeTool` / `AfterTool` | `Notification.ToolPermission` (`message`, `details`) | [hooks reference](https://geminicli.com/docs/hooks/reference/) |

Common contract: stdin JSON with `hook_event_name`, `session_id`, `cwd`; exit 0 with no stdout means
"no decision"; the hook must never print JSON (we never want to influence the agent) and must never
block it (Claude Code supports `async: true`; we set short timeouts everywhere). **Exit code 2 is a
verdict, not a failure, to every one of them**: Claude Code reads it as "block the tool / erase the
prompt / do not stop", Gemini's `BeforeAgent` and `BeforeTool` and Codex do the same and have no
`async` to soften it. Our hook therefore exits 0 whatever happens (§3.3).

### 2.2 The agents also announce themselves over the terminal

Independently of hooks, the three emit desktop notifications (OSC 9 / 99 / 777) that libghostty
already parses into `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` with a `title` and `body`: Claude Code's
`preferredNotifChannel` (default `auto`) on finish / permission; Codex's
`[tui] notifications = ["agent-turn-complete", "approval-requested"]`; Gemini's OSC 9 on idle /
confirmation. The text is the agent's own fixed wording — matching it is deterministic. This is the
fallback when hooks are not installed, not the primary path.

### 2.3 Which process is in which pane — without a pty

libghostty exposes no pid or pty for a surface (checked against the vendored `ghostty.h`). Every
pane's shell is spawned with `QUICKTERM_PANE=<uuid>`, and macOS lets a same-uid process read another
process's arguments and environment through `sysctl KERN_PROCARGS2` (what `ps -E` uses) — under two
rules **measured on this machine (macOS 26.7)**:

1. the environment of an Apple platform binary (`login`, `zsh`, `/bin/sleep`) is hidden from every
   other process, its own parent included;
2. the environment of a non-platform binary (`node`, hence Claude Code and Gemini CLI; Codex's own
   binary) is readable in full by **any** same-uid process, related to it or not (121 variables of an
   unrelated `node` read from a shell).

What the design takes from that (reviewer finding, accepted):

- The scan finds agents by our marker but never the pane's shell itself. "Presence" means "an agent
  process carrying `QUICKTERM_PANE`", never "a shell is running here".
- The scan is restricted to **QuickTerm's own descendants**: `proc_listchildpids` walked recursively
  from `getpid()`, then `KERN_PROCARGS2` on those pids only. It never reads the environment of an
  unrelated process (a Chrome helper, a node server — where secrets live). The README states exactly
  this.
- `QUICKTERM_PANE_TOKEN` is readable by any same-uid non-platform process, an agent in another pane
  included. What it proves is "ran inside this pane, **or read this pane's environment**": stronger
  than the code comments assume against a platform-binary pane, weaker against a non-platform agent.
  It stays what `ControlEnvironment` says it is — proof of origin, never a permission boundary. The one
  thing it must not be allowed to do is **silence** a real alarm; §3.3 and §3.5 say how.

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
reused; none of it is duplicated. Two things do **not** exist yet and are Phase 1 work: nobody
installs a `UNUserNotificationCenterDelegate` today (the engine's `handleUserNotification(response:)`
has no caller, so a click on a banner does nothing), and the engine still posts its own banners
straight to `UNUserNotificationCenter` (`Ghostty.App.showDesktopNotification`,
`SurfaceView.showUserNotification`).

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

The process scan runs on a background queue over **QuickTerm's own descendants only** (§2.3): on
every hook event, every notification, every `commandFinished` (OSC 133) and a slow heartbeat (every
5 s while the app is active), and posts results to the main actor. It keeps nothing but pid, name,
argv[0] and our marker; the environment buffer it had to read for the marker is discarded in the
same call.

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
contradict a hook except a later hook or the process going away. **The reducer posts a notice only
on a transition into `blocked` / `error`**, never on every event that reports the same state; and
while a pane's status has evidence `.hook` or `.report`, the engine's OSC notifications and
`commandFinished` for that pane still feed the reducer but post **no notice of their own** — the hook
is the notice's source, and two sources on one pane would be two alarms for one prompt (Phase 2;
reviewer finding, accepted).

First wave, bundled: **Claude Code, Codex, Gemini CLI.** Every other agent is a rule file, or arrives
through the herdr shim.

### 3.3 Hooks: installing them, and the `agent-event` command

**One script for every agent**, written to `~/.config/quickterm/hooks/quickterm-agent-state.sh`:

```sh
#!/bin/sh
# Installed by QuickTerm. Reports the agent's lifecycle event to the QuickTerm pane it runs in.
# Outside QuickTerm (no socket in the environment) it does nothing and exits 0 immediately,
# so the same hook entry is harmless in Terminal.app, VS Code, tmux or CI.
# The CLI path is baked in on purpose. This script runs from a trusted, user-level hook entry;
# a path taken from the environment would let a project .envrc, `nix develop` or a Makefile
# choose which binary runs on every prompt. Never read QUICKTERM_BIN here.
QT_BIN='/Applications/QuickTerm.app/Contents/SharedSupport/quickterm'
[ -n "${QUICKTERM_SOCKET:-}" ] && [ -n "${QUICKTERM_PANE:-}" ] || exit 0
[ -x "$QT_BIN" ] || exit 0
"$QT_BIN" agent-event --agent "$1" </dev/stdin >/dev/null 2>&1
exit 0
```

Two rules the script embodies (both reviewer findings, accepted):

- **The binary is baked in, never taken from the environment.** The installer writes the absolute
  path of the running app's bundled CLI (`Contents/SharedSupport/quickterm`) into the script as a
  single-quoted constant, and single-quotes the script path in the command string it writes into the
  agent's config (Claude Code runs that string under `sh -c`; a home directory with a space in it
  would otherwise break the entry). It refuses to write when the script path already exists as a
  symlink. On launch the app rewrites the script **only when the baked path no longer exists** (the
  bundle moved) — never merely because a different build is running, so a Debug instance cannot
  repoint the user's hooks; an instance launched with `QUICKTERM_CONFIG_FILE` set (a second copy)
  neither installs hooks nor rewrites the script on its own. `QUICKTERM_BIN` is still injected into
  every pane as a convenience for users and for `HERDR_BIN_PATH`, but nothing QuickTerm installs
  trusts it.
- **The hook exits 0, always.** `quickterm agent-event` itself exits 0 and writes nothing to stdout
  or stderr, whatever the socket answers: `not_running`, `protocol_mismatch`, `rate_limited`,
  `disabled` and a refused origin are swallowed (logged once per cause at debug level). The script
  calls it without `exec` and ends in `exit 0` — belt and braces, because `ControlExit.notRunning` is
  2 and exit 2 is a verdict to every agent (§2.1). Concrete trigger: `[control] socket = false`
  flipped while agents run — the pane environment still carries `QUICKTERM_SOCKET`, the connect is
  refused, and the old script would have exited 2 and blocked the tool.

Codex passes its `notify` payload as an argument rather than stdin — but we use Codex's `hooks.json`,
which is stdin like the others, and leave `notify` alone.

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

**`quickterm agent-event --agent <id>`** — the command the hook runs. The CLI reads stdin with an
8 KB cap, extracts the whitelisted fields — `hook_event_name`, `notification_type`, `tool_name`,
`session_id`, `error_type`, and a summary of `message` / `tool_input` clamped to
`TitleRules.maxLength` — and sends **only those** over the socket, so a full `tool_input` (a whole
file body, a `transcript_path`) never crosses it (reviewer finding, accepted).

Trust (rewritten after the measurement in §2.3): **attribution is the proven origin pane** —
`origin.pane` whose `QUICKTERM_PANE_TOKEN` verifies (`ControlCommandRunner.originIsProven`), never
`-t` and never an unverified `origin.pane`; a request whose token does not verify is dropped and
logged as refused (the hook still exits 0). Because the pane token is readable by a same-uid
non-platform process, a token match cannot stop pane A's agent from posting events *about* pane B;
what it must never do is let such an event **silence** B's real alarm. So: a `needsUser` notice
resolves as `stateChanged` only from the **same process lineage** that posted it — the peer pid's
ppid chain (`proc_pidinfo PROC_PIDTBSDINFO`, cheap, cross-process for the same uid) walked up to the
direct child of QuickTerm it descends from — and, when the notice recorded a `session_id`, from the
same session. A mismatch is refused with its own error code (`origin_mismatch`, appended to
`ControlErrorCode`, exit class `denied`), logged as a cross-pane attempt, and still exits 0 at the
hook. A forger can add a notice; it can never remove one. The strip's *state* for that pane can
still be spoofed by such a process — that is information, not an alarm, and a same-uid process can
already write to the pane's tty directly (§8). Class: mutate, but **silent** — no status-bar flash,
no undo entry, no consent; it fires constantly and changes nothing but a status. Rate-limited per
pane.

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

**Attribution follows §3.3, not the positional argument** (reviewer finding, accepted): every shim
command is attributed to the proven origin pane, and the positional `<pane>` must equal it or the
call is refused with `origin_mismatch` — pane uuids are public through `state`, so the argument
alone proves nothing. The raw socket methods `pane.report_*` are accepted only inside our request
envelope with a verified origin; a bare herdr-style line without one is refused.

Why it is a switch: `HERDR_ENV=1` tells herdr-aware tools they are inside herdr, and some of them
(herdr's own Claude skill, for one) will then try to drive herdr's *other* commands through
`HERDR_BIN_PATH` and fail. Default **off** until the owner has tried it; documented as such.

### 3.5 `NoticeCenter` — the general notification center

The exact Swift surface is the contract in §10; this section is the behaviour it implements.

**One notice is (source, urgency, pane).** The coalescing key is exactly those three, computed by the
center, never supplied by the poster. Rules (two reviewer findings on the old "one key per pane, a
new post replaces it" merged and accepted — with that rule, Claude Code's own OSC "Claude needs your
permission" arriving *after* the `PermissionRequest` hook, or `commandFinished` firing when `claude`
itself exits, replaced the approval alarm with an `info`; and `PermissionRequest` plus
`Notification.permission_prompt` for one prompt re-presented the banner with sound twice):

1. An identical live notice (same key, same title, same body) makes a post a **duplicate**: nothing
   changes, no sink hears about it, `postedAt` stays.
2. A live notice with the same key but different content is **superseded**: it resolves as
   `.superseded`, the new one takes its place.
3. A post **never lowers a pane**: an `info` post while a `needsUser` is live is stored as its own
   notice under its own key and leaves the alarm alone. A pane's displayed urgency is the maximum
   over its live notices; `needsUser` ends only through the resolution rules below.
4. Badge, pill and mark count **panes** with at least one live `needsUser`, not notices.
5. Alerting sinks react to **pane transitions** (none → info, none → needsUser, info → needsUser) and
   to a superseded `needsUser` (a different tool now asks), never to a notice by itself — one banner
   per prompt however many sources describe it.

**Title and body are two fields with two rules** (reviewer finding, accepted). The title is
payload-free: the agent, the state and the tool *name* (`Claude Code · Awaiting approval · Bash`),
or the OSC title, or a sentence QuickTerm composed — never a command line. The body carries the
program's own text (an OSC body, a `tool_input` summary) and is **sensitive by default**; only text
QuickTerm composed itself ("Command took 12 s, exit 0") is marked plain. Every sink below says which
of the two it shows.

**Sinks** (each independent, each switchable):

| Sink | Behaviour |
|---|---|
| System notification | `UNUserNotificationCenter`, identifier = the pane's uuid, so an update replaces rather than stacks — **one per pane**. Posted only on a raising pane transition and only when the pane is not active: the app is not frontmost, or the pane's screen is not key, or its workspace is not the visible one, or the pane is not focused. Shows the title (and the pane's handle/title as subtitle); the body only per `[notifications] system-body` (`composed` by default: never a program's text — Notification Center persists it in its database, on the lock screen and after the app is gone). Withdrawn when the pane becomes active or its last notice resolves. **Click = navigation, not acknowledgement**: activate the app, that screen, that workspace, focus that pane, withdraw that banner — the notice stays live (reviewer finding, accepted: with two panes blocked, clicking A and getting pulled away must leave A marked). No action buttons. QuickTerm installs the `UNUserNotificationCenterDelegate` at launch; the engine's direct OSC→macOS path is removed so nothing fires twice. |
| Dock badge | `NSApp.dockTile.badgeLabel` = number of panes with a live `needsUser` across all screens; cleared at zero. |
| Pane mark | Red dot (`theme.alert`) at the pane's top-right corner drawn by `PaneFrame` (the border breaks around it like the title does); only for `needsUser`; tooltip = the notice title (payload-free by construction). |
| Workspace pill | `dev ●2` / `3 ●1` — panes with a live `needsUser` in that workspace, the `●N` in `theme.alert`; a term in `WorkspacePill`'s width budget, so the whole row still falls back together when it does not fit. |
| Control plane | events `notice.posted` / `notice.resolved`; `quickterm notices list [--needs-user]`, `quickterm notices ack -t t7`; `state --json` carries live `notices` per pane and a `needsUser` count per workspace. The body is present only when the caller carries `QUICKTERM_TOKEN` — the browser-URL rule, through the event bus's existing redactable flag. |
| Activity log | every `needsUser` post, every resolution of one, and every `ack`; the body is a `sensitive` change so the OSLog mirror keeps only the path. `info` posts are not logged (they would push real mutations out of the 200-entry ring; the event bus carries them). |

**Resolution** — a `needsUser` notice ends when any of:
1. the pane's agent state leaves `blocked`/`error` (a hook said so: `PostToolUse` after a
   `PermissionRequest`, `UserPromptSubmit` after `idle_prompt`, `Stop`, `SessionEnd`) —
   `stateChanged`, accepted only from the lineage that posted it (§3.3);
2. the user focuses the pane and sends it a keystroke — `userActed`. **A keystroke is a real
   `NSEvent` delivered to `SurfaceView.keyDown(with:)` of the focused pane in the key window of the
   active app; text arriving through `input send-text` (`model.sendText`) never counts** (reviewer
   finding, accepted). Phase 1 resolves the notice fully on that keystroke, as the owner decided
   ("the user handles it; the marks go away"); whether a hook-evidenced approval should keep its
   pane mark until a hook confirms the state change is §9 Q1 — the notice carries its `evidence`
   so Phase 2 can narrow this rule without an API change;
3. the user acknowledges it — `notices ack`. Clicking the system notification is *not* an
   acknowledgement (see the sink);
4. the pane closes.

No timeout. An unanswered approval stays visible until it is answered. `info` notices (`done`, a
finished download) resolve when the pane becomes active.

**Sources beyond agents in Phase 1**: the engine's own OSC notifications from any program (info), and
`commandFinished` for long commands (info, `[notifications] command-finished = "long"`). Bell:
ignored by default (`bell = "ignore" | "info"`).

### 3.6 The status bar — in the padding, never a resize

```
 ▌ build · web · Awaiting approval · Bash: npm test                          2m 14s ▐
```

Revised 2026-09-14 after the first real session: the 10pt text-only strip overlapped the pane's
title badge and was too faint to notice. It is now a **bar**: a filled band spanning the pane's inner
width inside the top padding, starting one border line in (so the border and the red pane mark stay on
top), `min(pane-padding, 16) − 2` tall — 12 pt at the default padding of 14 — with 11 pt semibold text.
Below `pane-padding = 12` nothing is drawn (the pane mark and the notifications still work); the
terminal surface is never resized. The line reads, left to right: the pane's own title if one is set
(else the agent's name) · the state · the tool · the agent's message, clamped through `TitleRules`,
with the elapsed time at the right edge. **While the bar is drawn the title badge on the border is not**
— the bar carries the title, so the two can never overlap; the badge returns unchanged when the bar
goes. Colours come from config: `[agents] strip-background` for idle / working / done / unknown,
`[agents] strip-attention` for blocked and error, `[agents] strip-text` for the text (`#rrggbb`;
defaults from the Tokyo Night palette); `done` flashes green and blends back into the base over 3 s.
Click → focus the pane. `[agents] info-strip = true|false`.

## 4. Configuration

Two new groups (each becomes a settings tab). `[notifications]` lands in Phase 1 except `done`,
which arrives with `[agents]` in Phase 2 (a key that changes nothing yet is a config line that
silently does nothing).

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
# system-body = "composed"          # never | composed | always — composed: only text QuickTerm wrote itself, never a program's (Notification Center keeps it)
# done = true                       # a finished turn posts an info notification (what the agents do themselves today)  [Phase 2]
# dock-badge = true
# pane-mark = true
# workspace-count = true
# bell = "ignore"                   # ignore | info
# command-finished = "long"         # never | long | always  (OSC 133, commands over 10 s)
```

## 5. Control plane

- `quickterm agent-event --agent <id>` — the hook's reporting command (mutate, silent, attributed to
  the proven origin pane; always exits 0).
- `quickterm agents list` — per pane: agent, state, detail, evidence, message (redacted for
  token-less callers), session id, since. Class `read`.
- `quickterm hooks install|uninstall|status [agent|all]` — class `mutate`, with a confirmation
  the first time it edits a given tool's config file.
- `quickterm notices list [--needs-user] [--history]`, `quickterm notices ack -t <pane>` — `ack`
  is an ordinary `mutate` command: status-bar flash, activity-log entry, `notice.resolved` event
  naming the peer. A same-uid process can therefore acknowledge another pane's alarm, but never
  silently.
- `state --json`: pane gains `agent {id, state, detail, evidence, since}` (Phase 2), `notices` and
  `urgency`; workspace gains `needsUser`.
- Events: `agent.state.changed` (Phase 2), `notice.posted`, `notice.resolved`.
- Error codes: `origin_mismatch` (Phase 2, appended).
- MCP: `quickterm_agents` (Phase 2), `quickterm_notices` (Phase 1), generated from the same table.
- herdr shim commands and socket methods as in §3.4.
- `AGENTS.quickterm.md`: "before asking the human, ask `quickterm notices list --needs-user`".

## 6. Phases

**Phase 1 — NoticeCenter and its sinks, on today's signals.** The center, the six sinks, resolution
rules, `[notifications]`, `notices` CLI and events; the engine's OSC path and `commandFinished`
routed through it so there is one owner, and a `UNUserNotificationCenterDelegate` installed so a
banner click routes. Verify on this machine that notification permission (granted per bundle id)
survives a rebuild. Built to the contract in §10; the test list is §10.9.

**Phase 2 — Hooks and the agent registry.** `agent-event` with proven-origin attribution and the
lineage rule; the hook script and the three installers (JSON edits that preserve everything else,
marker, idempotent, uninstall, baked path, symlink refusal, single quoting);
`auto-install-hooks = ask`; `PaneSignals` (hook, notification, descendants-only process scan); the
rule-file loader; bundled rules for Claude Code, Codex and Gemini CLI; the info strip; `agents list`;
`agent.state.changed`; the OSC/commandFinished mute for hook-evidenced panes; `[notifications] done`.
Tests: rule parsing; the hook → state maps against recorded payloads from the three agents'
documented schemas; process→pane mapping with a real child process — **a non-platform helper, with a
comment saying why** (`/bin/sleep`'s environment is invisible, §2.3); that the hook script exits 0
instantly outside QuickTerm; that with the socket stopped the hook exits 0 in under 50 ms with empty
stdout and stderr; that a report with the wrong pane token is refused and the hook still exits 0;
that a `stateChanged` resolution from a different lineage is refused with `origin_mismatch` and
logged; that the CLI sends only the whitelisted fields and stops reading stdin at 8 KB; that the
scan never calls `KERN_PROCARGS2` on a pid outside QuickTerm's descendants.

**Phase 3 — herdr compatibility.** The env variables, the four `pane report-*` commands, the socket
methods, `.report` signals in the reducer, the positional-pane-equals-proven-origin check and the
envelope requirement on raw `pane.report_*`. Validate against two real herdr integrations
(OpenCode's plugin, Pi's extension). Decide then whether to vendor herdr's installers for the six
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
  silently on anything unexpected — including its own CLI failing — so a broken assumption degrades
  to "unknown", never to a stuck agent, a blocked tool, an erased prompt or a transcript full of
  "hook error".
- **We are editing other tools' config files.** Only at user level, only with a marker, only after
  the user said yes (or set `always`), always reversible, never a project file. The entry we write
  runs a script whose binary path is baked in and quoted; the environment chooses nothing.
- **Process scanning reads other processes' environments.** Only QuickTerm's own descendants, same
  uid, our marker, pid + name kept. An unrelated process is never read. Stated in the README.
- **The pane token is readable by a same-uid non-platform agent in another pane** (§2.3). It can
  add a notice or spoof a strip state for a pane it does not live in; it can never resolve a
  `needsUser` notice it did not post (lineage rule), and the activity log names the peer. A
  same-uid process can already write to any pane's tty; this feature does not pretend to be a
  boundary that the platform does not offer.
- **Message bodies can carry command lines** (`Bash: rm -rf build`). The title never does; the body
  is sensitive by default: redacted for token-less callers, kept out of the OSLog mirror, and out of
  the system notification unless `system-body = "always"` — exactly like browser URLs.
- **herdr compat can confuse herdr-aware tools** — hence the switch, default off.
- **Notification permission** is per bundle id; verify on this machine in Phase 1 that it survives
  an ad-hoc re-sign (the engine's existing path suggests it does).

## 9. Open questions for the owner

Recorded, not decided. Phase 1 is buildable as specified whichever way these go.

**Q1 — After the user acts, should a hook-evidenced approval keep its pane mark until a hook
confirms the state change?** (Reviewer finding, marked for the owner.) Claude Code fires
`PermissionRequest` and `Notification.permission_prompt` once per prompt and never re-fires; with
rule 2 as written, focusing the pane and pressing any key — an arrow moving through the option
list, Esc, a modifier, a key meant for another TUI element — clears the Dock badge and the mark
while the prompt is still pending, and nothing will raise it again. Three shapes:
  (a) as decided today: the keystroke resolves everything (Phase 1 behaviour; matches §1 item 2,
      "the user handles it; the marks go away");
  (b) the keystroke clears the interrupting sinks (banner, Dock badge) but the pane mark and the
      strip stay red until a hook-confirmed state change; notification-only evidence still
      resolves fully, since no later signal will ever come;
  (c) as (a), plus a timed re-arm: the mark comes back if no state change arrives within N seconds
      after the pane loses focus.
Editor's recommendation: (b), no timer. Affects the Phase 2 default only; the Phase 1 contract
carries `evidence` on every notice so any of the three is a one-line policy change.

**Editor's decisions the owner may overrule** (each is a one-line change): `system-body` defaults
to `composed`; `notices ack` may acknowledge any pane but always flashes, logs and emits an event
naming the peer; badge and pill count panes, not notices; `info` posts are not written to the
activity log (the event bus carries them); the pane mark is drawn for `needsUser` only.

## 10. Phase 1 API contract

Four implementers build against this section without talking to each other: **(A)** the center and
its value types, **(B)** the sinks that draw (pane mark, workspace pill, Dock badge), **(C)** the
system-notification sink, click routing and the engine hand-over, **(D)** the control plane
(commands, events, state, activity log, config keys, READMEs). What each side may assume of the
others is written here; anything not written here is that side's private business. All types are
Swift 5.10, and everything below runs on the main actor unless it says otherwise.

### 10.1 Files, targets, catalogs

| File | Owner | Notes |
|---|---|---|
| `Sources/Notices/Notice.swift` | A | value types; `import Foundation` only |
| `Sources/Notices/NoticeCenter.swift` | A | the center |
| `Sources/Notices/NoticeLocator.swift` | A | pane lookups and activity (imports AppKit) |
| `Sources/Notices/NoticeSettings.swift` | A | the `[notifications]` values as the center reads them |
| `Sources/Notices/Sinks/PaneMarkSink.swift`, `WorkspacePillSink.swift`, `DockBadgeSink.swift` | B | |
| `Sources/Notices/Sinks/SystemNotificationSink.swift`, `Sources/Notices/NoticeRouting.swift`, `Sources/App/AppDelegate+Notices.swift` | C | |
| `Sources/Notices/Sinks/ControlPlaneSink.swift`, `Sources/Notices/Sinks/ActivityLogSink.swift`, `Sources/Control/Wire/ControlNoticePayload.swift`, `Sources/Control/Commands/ControlNoticeCommands.swift` | D | Wire files: `import Foundation` only, compiled into the CLI too |
| `Resources/en.lproj/Notices.strings`, `Resources/zh-Hans.lproj/Notices.strings` | whoever first needs a string; keys `notice.*` | one table owns every UI string of this feature; both languages in the same change |

Run `xcodegen generate` after adding any file; a `.strings` table not in the project is silently not
bundled. `scripts/check-localization.py` runs on every build.

### 10.2 Value types (A)

```swift
/// `nil` (no live notice) sorts below both; `info < needsUser`. `<` is written by hand: Swift does
/// not synthesise Comparable for an enum with raw values.
enum NoticeUrgency: String, Codable, Comparable {
    case info
    case needsUser = "needs-user"
}

enum NoticeSource: Hashable, Codable {
    case agent(String)      // adapter id, Phase 2: "claude-code"
    case terminal           // OSC 9 / 99 / 777 from whatever runs in the pane
    case command            // commandFinished (OSC 133)
    case bell               // BEL, only with [notifications] bell = "info"
    case download           // reserved: not wired in Phase 1
    case control            // reserved: not wired in Phase 1
    case custom(String)
    /// Wire and coalescing spelling: "agent:claude-code", "terminal", "command", "bell",
    /// "download", "control", "custom:<name>". Stable; agents branch on it.
    var id: String { get }
}

/// `.composed` = QuickTerm wrote the text itself; everything else is a program's own words.
enum NoticeEvidence: String, Codable { case hook, report, notification, process, composed }

enum NoticeResolution: String, Codable {
    case stateChanged = "state-changed"
    case userActed    = "user-acted"
    case acknowledged
    case superseded
    case paneFocused  = "pane-focused"   // info notices only
    case paneClosed   = "pane-closed"
}

/// Who may resolve a notice as `.stateChanged` (§3.3). Phase 1 never fills it; Phase 2 does.
struct NoticeOrigin: Equatable, Codable {
    var lineageRoot: pid_t?     // the direct child of QuickTerm the poster descends from
    var sessionID: String?
    /// nil stored origin: anyone may resolve. Otherwise `other` must be non-nil and every
    /// non-nil field of the stored origin must equal the same field of `other`.
    func permits(_ other: NoticeOrigin?) -> Bool
}

struct Notice: Identifiable, Equatable, Codable {
    let id: UUID
    let key: String                  // Notice.key(source:urgency:pane:)
    let source: NoticeSource
    let pane: UUID
    let screen: UUID                 // MainWindowController.windowID at post time
    let workspace: Int               // zero-based, at post time
    let urgency: NoticeUrgency
    let evidence: NoticeEvidence
    let title: String                // payload-free, printable, ≤ TitleRules.maxLength
    let body: String?                // ≤ Notice.maxBodyLength, printable, nil when empty
    let bodySensitive: Bool
    let origin: NoticeOrigin?
    let postedAt: Date
    var resolvedAt: Date?
    var resolution: NoticeResolution?
    var isLive: Bool { resolvedAt == nil }

    static let maxBodyLength = 1024
    static func key(source: NoticeSource, urgency: NoticeUrgency, pane: UUID) -> String   // "\(source.id)|\(urgency.rawValue)|\(pane.uuidString)"
}

struct NoticeRequest {
    var source: NoticeSource
    var pane: UUID
    var urgency: NoticeUrgency
    var evidence: NoticeEvidence
    var title: String
    var body: String? = nil
    var bodySensitive: Bool = true   // false only for .composed text
    var origin: NoticeOrigin? = nil
}

struct NoticeLocation: Equatable { var screen: UUID; var workspace: Int }

/// Panes with at least one live needsUser, and where each of them is.
struct NoticeCounts: Equatable {
    var needsUser: [UUID: NoticeLocation]
    var total: Int { needsUser.count }
    func count(screen: UUID) -> Int
    func count(screen: UUID, workspace: Int) -> Int
}

/// The pane's displayed urgency before and after one change.
struct PaneTransition: Equatable {
    let pane: UUID
    let before: NoticeUrgency?
    let after: NoticeUrgency?
    var raised: Bool      // after > before, with nil below info
    var cleared: Bool     // before != nil && after == nil
}

/// Whether the user is looking at this pane right now. All four must hold for `isActive`.
struct PaneActivity: Equatable {
    var appActive: Bool          // NSApp.isActive
    var screenKey: Bool          // the pane's window is key
    var workspaceVisible: Bool   // its workspace is the screen's active one and no other pane is zoomed over it
    var focused: Bool            // controller.focusedPane === pane
    var isActive: Bool { appActive && screenKey && workspaceVisible && focused }
}

enum NoticeChange {
    case posted(Notice, PaneTransition, PaneActivity?)
    case superseded(old: Notice, new: Notice, PaneTransition, PaneActivity?)
    case resolved(Notice, PaneTransition, PaneActivity?)
    /// Only for panes holding a live notice, only when the activity actually changed.
    case activityChanged(pane: UUID, PaneActivity)
    case countsChanged(NoticeCounts)
}
```

Sanitising (done by `post`, so every sink may trust it): `title` goes through
`TitleRules.fromTypedInput` and is cut to `TitleRules.maxLength`; an empty result is replaced by
`L("notice.title.fallback", source.id)`. `body` goes through the same printable filter with
newlines collapsed to single spaces, is cut to `Notice.maxBodyLength`, and becomes `nil` when empty.
Nothing else is rewritten.

### 10.3 The center (A)

```swift
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()
    /// Tests build their own with a stub locator; the app calls `attach` once (10.10).
    init(locator: NoticeLocating = NoticeLocator.unattached, clock: @escaping () -> Date = Date.init)
    func attach(locator: NoticeLocating)

    static let historyCapacity = 200

    @Published private(set) var live: [Notice]        // post order
    private(set) var history: [Notice]                // resolved, oldest first, capped
    var settings: NoticeSettings { get set }          // setting it toggles every sink's isEnabled

    enum PostOutcome: Equatable { case posted(UUID), duplicate(UUID), superseded(old: UUID, new: UUID), unknownPane }
    @discardableResult func post(_ request: NoticeRequest) -> PostOutcome

    enum ResolveOutcome: Equatable { case resolved, notLive, notFound, originMismatch }
    @discardableResult func resolve(_ id: UUID, _ how: NoticeResolution, origin: NoticeOrigin? = nil) -> ResolveOutcome
    /// Every live notice of the pane (optionally only one urgency); returns how many resolved.
    @discardableResult func resolveAll(pane: UUID, _ how: NoticeResolution,
                                       urgency: NoticeUrgency? = nil, origin: NoticeOrigin? = nil) -> Int

    // The resolution rules of §3.5, each with exactly the callers named in 10.6
    @discardableResult func agentStateLeftNeedsUser(pane: UUID, origin: NoticeOrigin?) -> Int   // rule 1 (Phase 2 caller)
    func userDidType(in pane: UUID)                                                           // rule 2
    nonisolated static func noteKeyDown(in pane: PaneView)                                    // the only road to rule 2
    nonisolated static func noteActivityChange()                                              // coalesced; rules 4 and "info resolves on focus"

    // Reading (consistent at the moment of any sink callback)
    func live(pane: UUID) -> [Notice]
    func notice(id: UUID) -> Notice?
    func urgency(pane: UUID) -> NoticeUrgency?         // max over live
    private(set) var counts: NoticeCounts
    func needsUserCount(screen: UUID? = nil, workspace: Int? = nil) -> Int

    // Sinks
    func addSink(_ sink: NoticeSink)
    func removeSink(id: String)
    func sink(id: String) -> NoticeSink?
    var systemSink: SystemNotificationSink?           // C sets it in 10.10; the delegate lives there

    func resetForTesting()                            // clears live, history, counts; sinks stay
}

@MainActor
protocol NoticeSink: AnyObject {
    /// "system", "dock-badge", "pane-mark", "workspace-count", "control-plane", "activity-log"
    var sinkID: String { get }
    /// Driven by `NoticeCenter.settings`; a disabled sink receives nothing and gets `clearAll()`
    /// once when it is switched off.
    var isEnabled: Bool { get set }
    func apply(_ change: NoticeChange)
    func clearAll()
}
```

**`post` semantics, in order:**
1. `locator.locate(request.pane) == nil` → `.unknownPane`; nothing stored, nothing logged (a pane
   that is fading out is not addressable, same as `state`).
2. Sanitise title and body (10.2). Compute `key`. Take `before = urgency(pane)`.
3. A live notice with the same key and equal `(title, body)` → `.duplicate(existing.id)`; return
   without touching anything (no sink call, `postedAt` unchanged).
4. A live notice with the same key and different content → mark it `resolvedAt = now,
   resolution = .superseded`, move it to `history`, store the new one, sinks receive
   `.superseded(old:new:transition:activity:)`.
5. Otherwise store it; sinks receive `.posted(notice, transition, activity)`.
6. Recompute `counts`; if changed, sinks receive `.countsChanged(counts)` **after** the
   posted/superseded call.
7. `screen` and `workspace` are taken from the locator at this moment.

**`resolve` semantics:** unknown id → `.notFound`; already resolved → `.notLive`;
`how == .stateChanged && !notice.origin.permits(origin)` → `.originMismatch` (nothing changes; the
control-plane sink is told through `logRefusal`-style logging in Phase 2, not through a
`NoticeChange`); otherwise set `resolvedAt` / `resolution`, move to `history` (capped), sinks
receive `.resolved(notice, transition, activity)`, then `.countsChanged` if the counts moved.

**Rule 2:** `noteKeyDown(in:)` is `nonisolated static`, wrapped in `MainActor.assumeIsolated` like
`ControlEventBus.noteChange()`. It calls `userDidType(in: pane.id)` only when
`pane.window?.isKeyWindow == true`, `NSApp.isActive`, and `pane.focused`; `userDidType` is
`resolveAll(pane:, .userActed)` over every urgency (Phase 1; §9 Q1 may narrow it by `evidence`).

**Activity pass** (`noteActivityChange()`): coalesced with `DispatchQueue.main.async` exactly like
`ControlEventBus.scheduleScan()` — any number of calls in one run-loop turn produce one pass. The
pass, for every pane that holds a live notice: `locator.activity(pane)`; `nil` means the pane is
gone → `resolveAll(pane:, .paneClosed)` (rule 4); `isActive` → `resolveAll(pane:, .paneFocused,
urgency: .info)`; and when the activity differs from the one recorded at the last pass, sinks
receive `.activityChanged(pane:, activity)`. The center records the last activity per pane so a sink
never hears about a change that did not happen.

**Guarantees to sinks:** every call is on the main actor; `.posted` arrives after the notice is in
`live`; `.resolved` after it has left; `counts`, `urgency(pane:)` and `live(pane:)` already reflect
the change inside the callback; a sink is never called while `isEnabled == false`.

### 10.4 Pane lookups and activity (A)

```swift
@MainActor
protocol NoticeLocating {
    func locate(_ pane: UUID) -> NoticeLocator.Located?
    func activity(_ pane: UUID) -> PaneActivity?
    func handle(_ pane: UUID) -> String?
}

@MainActor
struct NoticeLocator: NoticeLocating {
    struct Located {
        let pane: PaneView
        let controller: MainWindowController
        let workspace: Int          // zero-based
        var location: NoticeLocation { .init(screen: controller.windowID, workspace: workspace) }
    }
    static var unattached: NoticeLocating          // locate/activity/handle all return nil
    init(screens: ScreenRegistry)
    func locate(_ pane: UUID) -> Located?          // ControlResolver.addressablePanes(in:) — fading panes excluded
    func activity(_ pane: UUID) -> PaneActivity?   // nil when locate is nil
    func handle(_ pane: UUID) -> String?           // ControlHandleRegistry.shared.existingHandle(for:)
}
```

`activity` is computed, never cached, from: `appActive = NSApp.isActive`;
`screenKey = located.controller.window?.isKeyWindow == true`;
`workspaceVisible = controller.model.activeIndex == workspace && (zoomed == nil || zoomed == pane.id
|| pane is floating in that workspace)` with `zoomed = ControlStateEncoder.zoomedPaneID(in:
controller.model.layouts[workspace])`; `focused = controller.focusedPane === pane`. Note the
difference from `ScreenRegistry.controlCurrent`: a notice asks "is the user looking", so the key
window counts only while the app is active — that is what `appActive && screenKey` says.

**Who calls `NoticeCenter.noteActivityChange()`** (A adds these five call sites; nobody else adds
one): `PaneView.focusDidChange` (next to the existing `ControlEventBus.noteChange()`); the
`model.$layouts` / `$floatings` / `$activeIndex` Combine sinks in `MainWindowController.init` that
already feed the event bus; `MainWindowController.windowDidBecomeKey` and a new
`windowDidResignKey`; `ScreenRegistry.remove`; and the center's own observers of
`NSApplication.didBecomeActiveNotification` / `didResignActiveNotification`, installed in `attach`.

### 10.5 Drawing sinks (B)

**Pane mark.** `PaneView` gains

```swift
struct NoticeMark: Equatable { var urgency: NoticeUrgency; var title: String }
// PaneView
private(set) var noticeMark: NoticeMark?
/// Sends objectWillChange first, exactly like `focused`; written only by PaneMarkSink.
func setNoticeMark(_ mark: NoticeMark?)
```

`PaneMarkSink` (`sinkID "pane-mark"`) sets, on every `.posted` / `.superseded` / `.resolved` /
`.countsChanged` for the pane, `noticeMark = urgency(pane) == .needsUser ? NoticeMark(urgency:
.needsUser, title: <title of the most recently posted live needsUser>) : nil`; `clearAll` sets nil
on every pane of every screen. `PaneChrome` passes `surfaceView.noticeMark` into `PaneFrame(color:
titleColor: title: overhang: mark:)`. Geometry lives in `PaneTitleBadge` as pure functions so it can
be tested: `markDiameter = 6`, `markTrailingInset = 8` (from the outer right edge to the dot's
trailing edge), `markGap = 2` of broken border on each side, the dot centred on the top border line;
`PaneTitleBadge.markReserve` (= `markDiameter + 2·markGap + markTrailingInset`) is subtracted from
`availableTextWidth` when a mark is drawn (the `place`/`fit` family gains a `mark: Bool` parameter)
so a title never runs under the dot. Colour `theme.alert`. The frame keeps
`.allowsHitTesting(false)`; the tooltip is `.help(mark.title)` on a 10×10 hit-testable overlay over
the dot alone, so terminal clicks elsewhere pass through unchanged.

**Workspace pill.** `WorkspaceModel` gains `@Published var noticeCounts: [Int]` (parallel to
`layouts`; panes with a live `needsUser` per workspace; kept aligned like `titles`).
`WorkspacePillSink` (`"workspace-count"`) writes it on `.countsChanged` for every controller (from
`NoticeCounts.count(screen:workspace:)`); `clearAll` zeroes it. `WorkspacePill.label`,
`pillWidth`, `pill`, `leftSectionWidth` and `showsTitles` each gain a `count: Int` /
`counts: [Int]` parameter: the label becomes `base + " ●N"` when `count > 0` (the `●N` drawn in
`theme.alert`, the base unchanged), and the measured width includes it.
`testPillWidthMatchesTheLaidOutPill` is extended with counts. `StatusBarView` reads
`model.noticeCounts`.

**Dock badge.** `DockBadgeSink(setBadge: (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 })`
(`"dock-badge"`): on `.countsChanged`, `setBadge(total == 0 ? nil : String(total))`; `clearAll` →
`nil`. The initialiser parameter exists so the test host asserts without touching the real Dock.

### 10.6 Producers and the engine hand-over (C)

`Ghostty.Delegate` gains two requirements; `AppDelegate+Notices.swift` implements them and is the
**only** poster in Phase 1 besides tests:

```swift
extension Ghostty { protocol Delegate {
    func ghosttySurface(id: UUID) -> PaneView?
    func ghosttyDesktopNotification(surface: Ghostty.SurfaceView, title: String, body: String)
    func ghosttyCommandFinished(surface: Ghostty.SurfaceView, exitCode: Int, duration: Duration)
} }
```

- `Ghostty.App`'s `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` calls `ghosttyDesktopNotification`;
  `commandFinished` calls `ghosttyCommandFinished` for **every** finish (the engine's own
  `notify-on-command-finish` gates and its bell action are not consulted: `[notifications]
  command-finished` decides, and the key's help says so). `showDesktopNotification(_:title:body:
  requireFocus:)`, `shouldPresentNotification`, `handleUserNotification(response:)`, and
  `SurfaceView.showUserNotification` / `handleUserNotification(notification:focus:)` /
  `notificationIdentifiers` are deleted, with the `import UserNotifications` they carried. The bell
  keeps posting `.ghosttyBellDidRing`; the producer observes it.
- Producers post: desktop notification → `NoticeRequest(source: .terminal, pane: surface.id,
  urgency: .info, evidence: .notification, title: title.isEmpty ? L("notice.terminal.title",
  handle) : title, body: body, bodySensitive: true)`; command finished, when
  `settings.allowsCommandFinished(duration)` → `(source: .command, urgency: .info, evidence:
  .composed, title: L("notice.command.succeeded" | ".failed" | ".finished"), body:
  L("notice.command.took", duration, exitCode), bodySensitive: false)`; bell, when
  `settings.bell == "info"` → `(source: .bell, urgency: .info, evidence: .notification, title:
  L("notice.bell.title"), body: nil)`. **No Phase 1 producer posts `needsUser`**; tests do.
- Rule 2's call: `Ghostty.SurfaceView.keyDown(with:)` calls `NoticeCenter.noteKeyDown(in: self)`
  right after its `bell = false` line, before any translation — and `Ghostty.Surface.sendText` /
  `model.sendText` is never routed there (a test pins this).

### 10.7 System notification sink and click routing (C)

```swift
/// The subset of UNUserNotificationCenter the sink uses, so tests inject a recorder.
protocol UserNotificationCentering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void)
    func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void)
    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)?)
    func removeDeliveredNotifications(withIdentifiers: [String])
    func removePendingNotificationRequests(withIdentifiers: [String])
}
extension UNUserNotificationCenter: UserNotificationCentering {}

@MainActor
final class SystemNotificationSink: NSObject, NoticeSink, UNUserNotificationCenterDelegate {
    static let category = "dev.danny.quickterm.notice"          // registered with no actions
    static func identifier(pane: UUID) -> String                 // "notice-pane-<uuid>"
    init(center: UserNotificationCentering, locator: NoticeLocating, route: @escaping (UUID) -> Void)
}
```

Behaviour: `apply(.posted)` and `apply(.superseded)` present when `settings.system == "inactive"`,
the activity is known and not active, and either `transition.raised` or (superseded and
`new.urgency == .needsUser`); a superseded `info` replaces its banner silently (no sound). Content:
`title = notice.title`, `subtitle = L("notice.system.subtitle", handle, paneTitle clamped to
PaneTitleBadge.maxCharacters)`, `body` = the notice body only when `settings.systemBody == "always"`,
or `"composed"` and `!bodySensitive`; otherwise empty. `userInfo = ["pane": uuid, "notice":
uuid]`, `sound = .default` on raising transitions only. Authorization is requested lazily at the
first present, as the engine did. Withdraw (delivered and pending, for the pane's identifier) on
`.resolved` when `urgency(pane) == nil`, on `.activityChanged` when `isActive`, and in `clearAll`.

Delegate: `willPresent` answers `[.banner, .sound]` when the pane is not active at that moment,
else `[]`. `didReceive` with the default action: `route(pane)`, then withdraw the identifier; the
notice **stays live**. The dismiss action does nothing. The delegate is installed in 10.10 before
`restoreSession()` runs, so a click that launched the app is delivered.

Click routing:

```swift
@MainActor
enum NoticeRouting {
    static let hoverFocusHold: TimeInterval = 3
    /// Activate the app, make the pane's screen key, switch to its workspace, focus it.
    @discardableResult static func reveal(pane: UUID, locator: NoticeLocating) -> Bool
}
// MainWindowController
func reveal(_ pane: PaneView, in workspace: Int)
func holdFocus(on pane: PaneView, for seconds: TimeInterval)
func releaseFocusHold()
```

`reveal`: `flushPendingCloses()`; `switchWorkspace(workspace)` if needed; if another pane is
zoomed in that workspace, un-zoom it (the existing zoom path, so the target is visible);
`window?.makeKeyAndOrderFront(nil)`; `NSApp.activate(ignoringOtherApps: true)`;
`requestFocus(to: pane)`; `holdFocus(on: pane, for: NoticeRouting.hoverFocusHold)`. The hold makes
`paneMayReclaimFocus(other)` answer `false` for every `other !== pane` until the deadline or until
the first `keyDown` reaches that pane (`SurfaceView.keyDown` calls `controller.releaseFocusHold()`),
because `PaneView.hoverFocusIfNeeded` is gated on exactly that method and, with focus-follows-mouse
on, the cursor is parked at the banner's spot over some other pane after the click — the first
twitch would steal focus from the pane the user was just routed to.

### 10.8 Settings and config keys (A declares the type, D the keys)

```swift
struct NoticeSettings: Equatable {
    var system = "inactive"          // inactive | never
    var systemBody = "composed"      // never | composed | always
    var dockBadge = true
    var paneMark = true
    var workspaceCount = true
    var bell = "ignore"              // ignore | info
    var commandFinished = "long"     // never | long | always
    static let longCommand: TimeInterval = 10
    init()
    init(_ settings: ConfigStore.Settings)
    func allowsCommandFinished(_ duration: Duration) -> Bool
    var allowsBell: Bool { bell == "info" }
}
```

`ConfigSection` gains `case notifications` (before `keybinds`; `titleZH "通知"`, `titleEN
"Notifications"`). `ConfigSchema.keys` gains, in this order, `system` (enumeration, strict),
`system-body` (enumeration, strict), `dock-badge`, `pane-mark`, `workspace-count` (bool), `bell`
(enumeration, strict), `command-finished` (enumeration, strict), each with `labelZH/labelEN/helpZH/
helpEN` and `hotReload: true`; `ConfigStore.Settings` gains `notificationsSystem`,
`notificationsSystemBody`, `notificationsDockBadge`, `notificationsPaneMark`,
`notificationsWorkspaceCount`, `notificationsBell`, `notificationsCommandFinished` with the matching
`ConfigBindings.table` entries; `AppSession.applyGlobalConfig` sets `NoticeCenter.shared.settings =
NoticeSettings(settings)`. Both READMEs get a `[notifications]` block in their configuration table
carrying every `templateAssignment` line verbatim (`ConfigSchemaTests.testEveryKeyIsDocumented`).
`settings` maps onto sinks: `system == "never"` → the system sink disabled; the three booleans →
their sinks; `bell` and `command-finished` are read by the producers, not by the center.

### 10.9 Control plane (D)

**Commands** (`ControlCommandTable.commands`, group `"notices"`):

- `notices list` — `cls: .read`, `idempotent: true`, `acceptsTarget: true` (the target scopes:
  a screen, a workspace or one pane; none = everything). Args: `needs-user` (bool: only panes with
  a live needsUser), `history` (bool: include the resolved ring). Payload:

  ```swift
  struct ControlNoticesPayload: Codable, Equatable {
      var schema = "quickterm.notices/1"
      var notices: [ControlNoticeRecord]
      var panesNeedingUser: Int
  }
  struct ControlNoticeRecord: Codable, Equatable {
      var id: String
      var pane: String          // handle
      var paneID: String
      var screen: Int           // one-based
      var screenID: String
      var workspace: Int        // one-based
      var source: String        // NoticeSource.id
      var urgency: String       // NoticeUrgency.rawValue
      var evidence: String
      var title: String
      var body: String?         // present only when the request carried QUICKTERM_TOKEN
      var redacted: Bool?       // true when a body exists and was withheld
      var postedAt: String      // ISO8601 with milliseconds (ControlEvent.stamp)
      var resolvedAt: String?
      var resolution: String?
  }
  ```

- `notices ack` — `cls: .mutate`, `idempotent: true`, `acceptsTarget: true`; the target must name
  a pane (`bad_request` with a hint otherwise). Runs through `commit(_:apply:)` with
  `changes = [ControlChange(path: "notices.<handle>", from: "<n> live", to: "0")]` (empty when
  nothing is live, so the second call is the usual silent no-op / exit 7 under `--fail-if-noop`),
  `undoCommand: nil`, `target: <handle>`; `apply` is `resolveAll(pane:, .acknowledged)`. Flash and
  activity log come from `commit`; nothing extra.

**State.** `ControlStatePayload.PaneInfo` gains `notices: [ControlNoticeRecord]?` (live only, nil
when none) and `urgency: String?`; `WorkspaceInfo` gains `needsUser: Int?` (panes, nil when 0).
Both encoded only when present so existing fixtures stay byte-identical. The body rule is
`ControlStateEncoder.trusted`, regardless of `bodySensitive` — one rule, no exceptions to remember.

**Events.** `ControlEventType` appends `noticePosted = "notice.posted"` and
`noticeResolved = "notice.resolved"` (summaries in the same voice as the others). `ControlEvent`
gains `noticeID: String?`, `urgency: String?`, `source: String?`, `body: String?`,
`resolution: String?`; `title`, `pane`, `paneID`, `screen`, `screenID`, `workspace` are filled.
`ControlEventBus` gains `func emit(_ event: ControlEvent, redactable: Bool)` — direct emission
that stamps `seq`/`ts`, appends to the ring and wakes waiters, **bypassing the snapshot diff**
with a comment saying why this is the one exception (a notice is an event by nature with a single
producer; there is no snapshot to subtract). `ControlEventBus.redact` clears `body` on every
redactable record and `title`/`cwd` only when the type is not a notice type (notice titles are
payload-free). `ControlPlaneSink` (`"control-plane"`) emits on `.posted`, `.superseded` (one
`notice.resolved` for the old, one `notice.posted` for the new) and `.resolved`, with
`redactable: notice.body != nil`.

**Activity log.** `ActivityLogSink` (`"activity-log"`) records, for a `needsUser` post and for
every resolution of a `needsUser`, `ControlActivityLog.Entry(command: "notice.post" |
"notice.resolve", peer: "QuickTerm", originPane: nil, target: <handle>, outcome: <resolution
rawValue or "applied">, changes: [ControlChange(path: "notice.title", to: title),
ControlChange(path: "notice.body", to: body, sensitive: true)])` — the second only when a body
exists. `info` posts are not logged.

**MCP.** `MCPToolMap` adds `MCPTool(name: "quickterm_notices", title: "Read or acknowledge
notices", commands: [notices.list, notices.ack])`; `MCPToolMapTests` covers the rest. `describe`
picks up the commands and event types from the tables.

### 10.10 Construction order (C wires it, in `AppDelegate.applicationDidFinishLaunching`)

Immediately after `self.session = session` and before `session.loadInitialConfig()`:

```swift
let center = NoticeCenter.shared
center.attach(locator: NoticeLocator(screens: screens))
let system = SystemNotificationSink(
    center: Self.isRunningTests ? RecordingNotificationCenter() : UNUserNotificationCenter.current(),
    locator: NoticeLocator(screens: screens),
    route: { pane in NoticeRouting.reveal(pane: pane, locator: NoticeLocator(screens: screens)) })
center.systemSink = system
center.addSink(system)
center.addSink(DockBadgeSink())
center.addSink(PaneMarkSink(screens: screens))
center.addSink(WorkspacePillSink(screens: screens))
center.addSink(ControlPlaneSink())
center.addSink(ActivityLogSink())
if !Self.isRunningTests { UNUserNotificationCenter.current().delegate = system }
```

`loadInitialConfig()` then pushes `settings` through `applyGlobalConfig`. The test host never
touches the real notification center or the real hooks; `RecordingNotificationCenter` lives in
`Tests/NoticeTestSupport.swift` and records every request, removal and the delegate.

### 10.11 Tests (each side writes its own file; names are fixed so nobody overlaps)

`Tests/NoticeCenterTests.swift` (A): duplicate post is a no-op (no sink call, `postedAt`
unchanged); different title supersedes with `.superseded` on the old; `info` after `needsUser`
leaves the `needsUser` live, `urgency(pane) == .needsUser`, counts unchanged; `needsUser` after
`info` raises; counts are panes not notices (two `needsUser` on one pane = 1) and split correctly
across two screens and two workspaces; `resolve(.stateChanged)` with a stored origin and a
mismatched/nil supplied origin → `.originMismatch`, with no stored origin → `.resolved`;
`userDidType` resolves every urgency; a `keyDown` NSEvent through `SurfaceView` resolves and
`model.sendText` does not; the activity pass resolves `info` on focus, resolves everything as
`.paneClosed` when the pane is gone, and reports `.activityChanged` once per real change; history
is capped at 200; sink callbacks see consistent `live`/`counts`; a disabled sink receives nothing
and got `clearAll()` once.

`Tests/NoticeSinkTests.swift` (B): `PaneTitleBadge` mark geometry (dot on the line, gap widths,
title reserve, no title when nothing fits with a mark); `noticeMark` set only for `needsUser` and
cleared on resolve; `WorkspacePill` width with counts equals the laid-out pill; the row falls back
to numbers together when counts push it into the clock; the Dock badge string for 0 / 1 / 7.

`Tests/NoticeSystemSinkTests.swift` (C): presents only when the pane is inactive; never on a
duplicate; withdraws when the pane becomes active and when the last notice resolves; body
included exactly per `system-body` × `bodySensitive`; `willPresent` answers by activity;
`didReceive` routes (workspace switched, window key, pane focused, hover-focus held for the hold
period, released by a `keyDown`) and leaves the notice live; the delegate is installed at launch;
the engine's desktop notification and command finished arrive as `.terminal` / `.command` info
notices with the right evidence and sensitivity, and `command-finished = never` posts nothing.

`Tests/ControlNoticeTests.swift` (D): `notices list` scoping and `--needs-user`; body present
only with the token in `notices list`, `state --json` and `events poll`; `notices ack` resolves
as `.acknowledged`, flashes, logs, is a no-op the second time and exit 7 with `--fail-if-noop`,
and rejects a target without a pane; `notice.posted` / `notice.resolved` carry the fields above
and `seq` moves; the activity-log `logLine` never contains a body; every `[notifications]` key is
in the template and both READMEs (existing `ConfigSchemaTests`); `quickterm_notices` covers both
commands.
