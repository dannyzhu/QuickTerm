# QuickTerm control plane (CLI + AI agent) implementation plan, Phases 1–5

> Three decisions confirmed by the user: (1) **on by default**, mode `ask` (reads need no confirmation; mutations are silent but visible and undoable; destructive and sensitive operations ask once per caller);
> (2) the main command is `quickterm`, with an optional short alias `qt`, installed into `/usr/local/bin` (or `~/.local/bin` with a PATH hint if that is not writable), and it **never prompts for an admin password**;
> (3) **`send-text` is in scope** (Phase 4, available once the config option — off by default — is turned on; injecting into `@self` needs no confirmation, injecting into any other pane always does).
>
> The full design and research write-up (a point-by-point comparison against tmux/kitty/wezterm/zellij/hyprctl/iTerm2, JSON samples, the risk list) is in
> `/private/tmp/claude-501/-Users-Danny-Documents-workspace-quickterm/e6fdbbbb-fb93-44bb-86da-29bcc5a0b0b0/scratchpad/control-design-full.md`
> — **read that file end to end before implementing**; this file only carries the decisions and the skeleton.

## 0. Invariants (hold these in every phase)

- The existing test suite keeps passing; the first window is still titled `QuickTerm`; the truth about focus is still the window's first responder.
- **Everything is generated from one command table**: `Sources/Control/CommandTable.swift` (it landed as `Sources/Control/Wire/ControlCommandTable.swift`, shared with the CLI target) produces the CLI parser, `--help`, `describe --json`,
  the safety classification and Phase 5's MCP tool table all at once. No second description of a command may be written by hand anywhere else.
- **Absolute values only, never a toggle** (`--zoom on|off`, `set-layout dwindle`, `--width 0.33`). An agent cannot see state, and
  retrying a toggle undoes itself. `action <wm-action>` is the single exception (it is the direct line to the keybinding semantics).
- A target that matches more than one thing → **error out and list the candidates**, never "take the first".
- All JSON goes through `JSONEncoder`; hand-assembling it is banned (yabai once broke every downstream pipe with a hand-written trailing comma).
- Control commands always execute back on the main thread; the socket's callback thread must never touch `@Published` directly. `perform()` is reentrant
  (engine callbacks call it too), so serialize it with a flag rather than a queue lock.
- Run `flushPendingCloses()` before any destructive command; closing is a two-stage 0.28s animation, and the focus retry runs for up to 0.75s.

## 1. Addressing

`screen:workspace.pane`, with any segment omittable; what is omitted defaults rightwards from the context.

- **screen**: a 1-based index (matching the window title), `#uuid` (`MainWindowController.windowID`), `@current`/`@primary`.
- **workspace**: a 1-based index (matching ⌘1..0; the internal 0-based index must never leak out), `@active`/`@next`/`@prev`.
- **pane**: a short handle `t7`/`b3` (stable within the process, prefixed by kind), `#uuid` or a prefix of at least 4 characters, a relation —
  `@focused` (the default) / `@left @right @up @down` / `@next @prev` / `@self` (read from `QUICKTERM_PANE`) —
  or a predicate `title:~<regex>` / `cwd:<prefix>` / `kind:terminal|browser` / `role:file-manager`.
- A pane that is currently fading out (`model.closingPanes`) cannot be addressed.

## 2. Transport

`~/Library/Application Support/QuickTerm/control.sock`, `AF_UNIX`/`SOCK_STREAM`, the directory `0700` and the socket `0600`,
checking for symlinks and the parent directory's permissions before binding, and probing then cleaning up a stale socket at launch. **Note that `sun_path` is only 104 bytes**: when the path is too long,
fall back to `$TMPDIR/quickterm.sock` and log it. Use BSD sockets + `DispatchSource` (not `NWListener`, because we need
`getsockopt(LOCAL_PEERCRED/LOCAL_PEERPID)`). **Never build an escape-sequence channel**, and never listen on TCP.

Protocol: NDJSON, one JSON object per line, with `id` correlating a request to its response; a connection can be reused (the event stream is just that same connection held open).
A `v` mismatch → exit code 8, reporting both versions.

The CLI target: a new directory `CLI/` (because the app target's `sources:` is all of `Sources`, so another `main.swift` in there would be compiled into the app);
the wire types live in `Sources/Control/Wire/` and are listed in both targets. The build copies the binary into `QuickTerm.app/Contents/SharedSupport/` — **not** `Contents/MacOS/`, as this plan originally said: APFS is case-insensitive by default, so `quickterm` there overwrites the app's own executable `QuickTerm`.

## 3. Security (on by default + ask)

- Socket permissions + a `LOCAL_PEERCRED` same-uid check (a hard refusal).
- `QUICKTERM_TOKEN` (regenerated on every launch) is injected into the environment of every new pane: **it is proof of origin, not a permission boundary**,
  the code comments must say so, and any "has a token, so skip the confirmation" logic is wrong.
- Four levels: `read` is silent (**a caller without a token cannot read browser URLs or titles — they are always redacted**) ·
  `mutate` is silent but **flashes the status bar** with the command and the originating pane, and registers with `AppDelegate.undoManager` (⌘Z undoes it) ·
  `destructive` (`pane close` / `screen close` / `workspace clear` / `spec apply --replace`) and
  `sensitive` (`send-text`, reading browser URLs) **ask once per (peer pid, command class)**, with the dialog showing the real process name and the originating pane.
- The confirmation dialog must not use a nested-runloop approach that can deadlock the main thread (the app already has several `runModal` sites); if the main thread is stuck
  the dialog cannot even appear, so there has to be rate limiting and a "refuse while busy" path.

## 4. The phases

### Phase 1 — socket + queries + a direct line to every action + describe
The socket and the wire types, the `quickterm`/`qt` binary and its installation, `state`/`list`/`get` (a flat pane array + a workspace skeleton of references),
`action <wm-action>` (all 67 of them; the 5 modal-panel ones are classed `interactive` and refused; destructive ones go through confirmation), `describe --json`,
`--help` (every subcommand ends with an example, and the query commands embed a JSON sample), environment variable injection, the `[control]` config section, and the short-handle registry.

### Phase 2 — the noun-verb layer + the confirmation UI + undo
`pane new/close/focus/move/swap/set/resize`, `workspace goto/set-layout/equalize/clear/count`,
`screen new/close/move/focus/set`, `app get/set`; every toggle gets an absolute-value counterpart; `--dry-run`, `--fail-if-noop`,
status-bar visibility, the control log, undo registration, rate limiting, and protection while a modal is up.
This needs `insertNewPane`/`removeFromAnyWorkspace`/`removeFromActiveLayout`/`clearZoom` widened from private to internal
(reimplementing their invariants would certainly introduce bugs).

### Phase 3 — spec dump/apply (composing a whole layout in one shot)
A public schema `quickterm.workspace/1` (plus `quickterm.screen/1` and `quickterm.session/1`), paired with the v5 archive by projection but
**evolving independently of it**; `spec dump/apply/validate`, with `--into-empty`/`--replace`/`--reuse`/`--dry-run` (which prints a readable diff).
Applying it builds the `ScrollingStrip`/`SplitTree` value in one go and then assigns it to `model.layouts[i]`: one re-layout, one animation, one save.
**Do not go through `applyArchive`/`restore(from:)`** — those are whole-window paths written for creating a new window, and they skip `BrowserPaneView.paneWillClose`.

### Phase 4 — the event stream + send-text
Every state change bumps `seq` (returned by `state`, so an agent can tell whether its snapshot is stale); `events poll --since --timeout` (the main form)
and `events follow` (an NDJSON stream); typed events (pane.opened/closed, focus.changed, workspace.changed, layout.changed,
screen.opened/closed, pane.title/cwd.changed) — **no event may ever carry a pane's output**.
`send-text`: only available with `[control] send-text = true` in the config, classed `sensitive`; injecting into `@self` needs no confirmation, any other pane asks every time;
control characters are refused; a newline can only be sent with an explicit `--enter`.

### Phase 5 — the MCP server + docs
`quickterm mcp` (stdio), 9 coarse-grained tools carrying `readOnlyHint`/`destructiveHint`/`idempotentHint` and an `outputSchema`,
all generated from that same command table (writing them by hand guarantees drift, and a test has to pin that down). Plus `helpEN` for all 67 actions,
`docs/agents/quickterm-cli.md`, and a section in both READMEs.

## 5. Delivery

Every phase: branch → implement → targeted tests → the full suite → adversarial review → fix → the full suite → commit → merge into main.
Once all five phases are done, rebuild Debug and restart the app, bring the README and porting-notes up to date, and only then consider a release.
