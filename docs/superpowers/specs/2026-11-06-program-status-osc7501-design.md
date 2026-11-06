# Program status (OSC 7501)

Date: 2026-11-06. Status: decided with the owner, not yet implemented.

## Why

QuickTerm learns what an AI agent in a pane is doing from hooks: a small script the agent runs on each lifecycle event, which reports to QuickTerm's control socket. Hooks are reliable and carry a session id, but they have to be installed into each agent's own config, they only exist for the agents QuickTerm knows, and they cannot reach an agent running over ssh or inside tmux.

The Program Status Protocol (OSC 7501, revision 0.4, https://www.superlogical.com/rex/docs/build/program-status) lets any program in a terminal tell the terminal its state with an escape sequence: idle, working, done, blocked (on permission, a question or auth), error, with an optional progress, label and message. Codex 0.167 (installed on the owner's Mac) already emits it (`]7501;state=…:app=codex:kind=…`). iTerm2 consumes it. Ghostty 1.4.0 parses it but its embedded app path drops it; Ghostty 1.3.1, which QuickTerm embeds, does not parse it at all.

The goal: QuickTerm reads OSC 7501 from every pane and shows the result in the pane's status band, with the same alarms as an agent's, for agents and for any other program (`cargo`, `terraform`, a deploy script).

## Goals

- Any program in a pane that emits OSC 7501 has its state shown in the pane's top band and raises the same alarms an agent does.
- An agent that emits OSC 7501 and has no hook installed (Codex today) is still tracked well, including approval prompts.
- Hooks keep working exactly as before; where both exist, the hook wins.

## Non-goals

- Replacing hooks. OSC 7501 has no session id (needed for agent resume), cannot be traced to a process (needed to stop a forged "done" from silencing an approval alarm), and Claude Code and kiro-cli do not emit it.
- Emitting OSC 7501 from QuickTerm, or from the hook script.
- OSC 9;4 progress (ConEmu) and OSC 21337 (iTerm2 session status). Both are out of scope; the protocol says a terminal should stop using 9;4 once 7501 arrives anyway.
- Upgrading the engine to Ghostty 1.4.

## Anti-goals

- A program can make an approval alarm disappear by printing an escape sequence (for example `cat` of a crafted file). An OSC 7501 report may raise an alarm; it may never resolve one a hook raised.
- Bytes from a report reach the screen, a notification, the control plane or a log as anything but plain, length-capped text.
- A pane stuck showing "working" or "waiting for you" forever after its program exited.
- A chatty program (progress every 100 ms) flooding notifications or redraws.

## Decisions

### The protocol, as QuickTerm reads it

1. **Accepted sequence:** `ESC ] 7501 ; <pairs> ST` (ST = `ESC \` or BEL), pairs `key=value` separated by `:`, keys `[a-z]+`, values `[A-Za-z0-9_.,+/=-]*`. Malformed pairs are skipped, unknown keys ignored, a repeated key takes its last value. Keys: `state` (required: `idle`, `working`, `done`, `blocked`, `error`, `clear`; any other value → the whole report is ignored), `id` (slash path, segments `[A-Za-z0-9_.+-]{1,32}`, ≤ 8 deep, ≤ 128 bytes; absent = root record), `kind` (with `blocked`: `permission`, `question`, `auth`; anything else = absent), `progress` (integer 0–100), `app` (`[A-Za-z0-9_.+-]{1,32}`), `title` and `msg` (base64 UTF-8).
2. **Limits, all enforced; a report breaking any of them is discarded whole:** sequence ≤ 4096 bytes; key ≤ 16 bytes; `msg` ≤ 2732 encoded / 2048 decoded bytes; `title` ≤ 256 / 192; `app` ≤ 32; invalid base64; any decoded `msg`/`title` containing U+0000–U+001F, U+007F or U+0080–U+009F.
3. **Records:** each report replaces the addressed record completely (a program repeats `app`/`title` to keep them). `clear` removes the addressed record and everything beneath it; `clear` with no `id` removes all of the pane's records. At most 64 records per pane; past that the least recently updated one is dropped. Records belong to the pane, not to a screen of it; `RIS` (full reset) removes them all.
4. **Feature query:** `ESC ] 7501 ; ? ST` is answered with `ESC ] 7501 ; ? ST` (no lists = the default states and kinds). The reply contains nothing from any report.
5. **Clearing on exit (protocol MUST):** when the pane's program exits, `working` and `blocked` records are dropped; `idle` records are dropped too; `done` and `error` stay. The protocol also clears them on a new shell prompt (OSC 133 `A`); QuickTerm does that when the shell reports prompts, and otherwise relies on the process signal below, because the owner runs with `shell-integration = none`.

   **Exit signal (my call; the owner approved "clear when the program exits", not the mechanism).** The existing process scan cannot do this: it only sees processes a rule file names, and it reads a process's environment to find its pane, so it never sees the pane's shell and never sees `cargo` (README "What the scan reads"). Instead the engine reports each surface's **pty foreground process group** (`tcgetpgrp` on the pty), a number and nothing else: no command line, no environment, so the README's privacy promise is unchanged. Each record remembers the foreground group that was current when it arrived. When the pane's foreground group later differs from that remembered one, the job that sent the report is over, and `working`, `blocked` and `idle` records drop. The check runs on every report and on the existing 5 s presence heartbeat. A report typed at the prompt (`printf` is a shell builtin, so the foreground group is the shell itself) therefore stays until the next command starts, which is what "until the next prompt" would do. A record also drops when the pane's shell exits.

### Engine

6. **Patch 0005** (`patches/ghostty/0005-osc-7501-program-status.patch`) on Ghostty 1.3.1 adds: a C function returning a surface's pty foreground process group (decision 5), an OSC 7501 parser in `src/terminal/osc/parsers/` (porting 1.4.0's `program_status.zig` where it fits 1.3.1's parser API), the query reply, and a path from the stream handler to the app the same way OSC 9 desktop notifications travel today (osc command → `termio/stream_handler.zig` → `apprt.surface.Message` → `Surface.zig` → an apprt action → a `ghostty_action_*_s` struct in `ghostty.h`). The engine validates the limits in decision 2 and delivers only reports that pass; it never interprets them beyond that. Record keeping lives in QuickTerm, not the engine.
7. Prompt-start (OSC 133 `A`) reaches QuickTerm through the same patch (one more action, or a flag on an existing one), so decision 5's prompt clearing works where shell integration is on.

### Status and precedence

8. **Two new evidence kinds** in the existing agent model: `PaneSignal.programStatus(record)` and `NoticeEvidence.programStatus`. Ranking: hook > program status > OSC 9/777 notification text > process presence.
9. **Mapping to the existing states:** `idle` → idle, `working` → working (with `progress` if present), `done` → done, `error` → error, `blocked` + `permission` → blocked:approval, `blocked` + `question` → blocked:input, `blocked` + `auth` → blocked:auth (new detail, label "waiting for you to sign in"), `blocked` with no kind → blocked:input.
10. **Where records live (my call).** The registry keeps its one agent status per pane exactly as today; program-status records live in a separate per-pane store next to it. A record whose agent is hook-tracked feeds that agent's status (decision 11); every other record stays in the store. Wire: notices from a generic record have source `program:<app>` (or `program` with no `app`); `quickterm state` gains a per-pane `programs` array; `agents list` keeps listing agents only.
11. **Whose report is it:** a record whose `app` names a loaded rule file's id (`codex`, `claude-code`, `kiro-cli`, …) or one of its `process` names belongs to that agent. Any other record (`cargo`, or no `app`) is a **generic program** status: same band, same alarms, labelled with its `title`, else its `app`, else "Program".
12. **Hook first:** while a pane's agent status is hook-evidenced (from the first hook until the agent is released; my call — not a 5 s recency window, so two sources never take turns during a long tool run), a program-status record for the same agent never changes the state; it may only add `progress` and `msg`. A record for a different program in the same pane is a separate status (decision 13).
13. **Alarms never resolved by a report.** A `blocked` record raises the same alarm as an agent's approval (pane mark, Dock badge, system notification when the pane is not being looked at), with evidence `programStatus`. Leaving `blocked` through a report resolves only an alarm that a program-status report itself raised; an alarm raised by a hook stays until the hook (or the process leaving) takes it down — the existing origin rule.
14. **Several records in one pane:** the band shows one: the most urgent of the pane's agent status and all its records, ordered blocked > error > working > done > idle, ties by most recent (my call: a `cargo` waiting for input outranks a hook-tracked agent that is merely working). Notifications come from the record that changed.
15. **Band text:** `<pane title> · <label> · <state>[ · <progress>%][: <msg>]`, the same shape and clamping the agent band uses. `msg` and `title` are plain text, bidirectional overrides and other invisible format characters removed, never markup.
16. **Done and error are information, not alarms** (owner-approved playback: "完成或失败：你不在看这个 pane 时，弹一条普通通知，你看一眼就消失"). Both post an `info` notice (no Dock badge), which resolves the moment the user looks at the pane. Note this differs from a hook-reported agent error, which today is a `needsUser` alarm; the difference is deliberate for program status. The record itself stays and the band keeps showing it the way the agent band shows a finished turn, until the program reports again or decision 5 drops it.
17. **Typing and repeats (my call).** A program-status alarm is quieted, not resolved, when the user types into the pane (the same treatment hook alarms get), because a 7501 program sends later reports. A report repeating the same state, kind and id as the record does not raise anything again; a different `blocked` kind supersedes the alarm, as a second hook approval does.
18. **Rate limits (my call on the details).** Per pane, at most one `info` banner (done/error) per 10 s from program status; a suppressed info banner is dropped (the notice is still posted, so the pane mark rules and `quickterm notices` see it). A `blocked` banner is never rate-limited, and neither are the pane mark and the Dock badge. Band redraws are coalesced to at most 4 per second.

### Control plane and config

19. `quickterm state` includes program-status records per pane (`app`, `id`, `state`, `kind`, `progress`, and `title`/`msg` only where the control plane already exposes agent messages); the existing `agent.state.changed` event fires for them with `evidence: "program-status"`. All English.
20. **Config:** `[agents] program-status = true` (default on; off = the engine still answers the query, QuickTerm ignores every report and shows nothing). Documented in both READMEs.

## Constraints

- Engine stays at Ghostty 1.3.1 + patches 0001–0004; patch 0005 applies after them, idempotently, in the existing build script, and the universal build must pass.
- The OSC parser runs on the engine's IO thread on untrusted bytes: no allocation proportional to input beyond the 4096-byte cap, no panics on malformed input.
- English-first: code, logs, commits, CLI and control plane in English; every new UI string in `en.lproj` and `zh-Hans.lproj` through `L(...)`.
- Tests never touch the owner's real config or agents.

## Left to the builder

- The exact C struct for the program-status action and how the record's fields cross the C boundary.
- How much of 1.4.0's parser can be ported as-is versus rewritten for 1.3.1's OSC parser interface.
- The `auth` detail's exact wording and band colour.
- How the foreground process group crosses the C boundary, and how the presence heartbeat calls it.

## Verification

- Engine: parser tests for every key, every limit, malformed pairs, unknown state, control characters in decoded text, ST vs BEL, the query reply.
- App: mapping table; precedence (hook wins; report cannot resolve a hook alarm; report can resolve its own); multiple records and the band's choice; clear by id and subtree; record cap; drop on a changed foreground group and on prompt, and NOT on the first heartbeat for a report typed at the prompt; generic program labelling; done/error as info; typing quiets; repeats do not re-raise; rate limits only on info banners; config off.
- Manual on the owner's Mac: a Codex session with no hook shows working, approval and done in the band; a `printf '\e]7501;state=working:app=cargo:progress=40\e\\'` shows `cargo · working · 40%`; a crafted `state=done` printed while a hook-raised approval is up does not clear it.
