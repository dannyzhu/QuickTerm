# QuickTerm control plane (for AI agents)

> Copy this file into your project's root `AGENTS.md` (or append it there), or drop it at `~/.codex/AGENTS.md` to make it apply to every project.
> Works with Codex CLI, Claude Code, and any agent that can run a shell.

You are running inside **QuickTerm** — a macOS tiling terminal. The `quickterm` command lets you **drive the UI around you**:
screens (windows), workspaces, and panes (terminal / browser / file manager).

## Do this first

```bash
quickterm describe --json
```

One call gives you the lot: the commands, their argument types and allowed values, the safety classes, the exit codes, the event
types, the workspace spec schema, and all 67 keybinding actions.
**Read that once and stop there — don't keep paging through `--help`.** If the command isn't there (`command not found`), this
machine has no QuickTerm CLI, or the user never put it on PATH — in which case ignore everything in this file.

## Who you are, where you are

Every pane's environment carries these (no need to ask the user):

| Variable | Meaning |
|---|---|
| `QUICKTERM_PANE` | this pane's UUID — what `-t @self` resolves through |
| `QUICKTERM_SOCKET` | path to the control socket |
| `QUICKTERM_SCREEN` / `QUICKTERM_WORKSPACE` | the screen / workspace index at creation time (a hint; not updated when the pane moves) |
| `QUICKTERM_TOKEN` | one value per launch, the same in every pane: proof that a command came from *some* QuickTerm pane. It is what stops browser URLs and titles reading `<redacted>`, and `pane capture-text` refuses outright without it |
| `QUICKTERM_PANE_TOKEN` | **a different thing — don't read the two as one.** One value per pane (`HMAC(per-launch secret, pane id)`), so it proves *which* pane the command came from. The control plane uses it in exactly one place: `input send-text` writing into your own pane skips the confirmation, because the server can recompute the HMAC for the pane `-t` resolved to and check it |

Neither token is a permission boundary — environment variables are inherited and readable, so nothing anywhere
skips a confirmation merely because `QUICKTERM_TOKEN` came along.

To find out what things look like *now*, always use `quickterm state --json`.
Never lean on `QUICKTERM_SCREEN` / `QUICKTERM_WORKSPACE`.

## Addressing

`screen:workspace.pane`, every part optional. The forms you'll actually use:

- `t7` / `b3` — **short handles** (`t` = terminal, `b` = browser); every pane in `state` has one, and it's what both you and the user should say
- `@self` — the pane you are running in; `@focused` — whichever pane has focus right now
- `@left @right @up @down` / `@next @prev` — relative position
- `1:3` — workspace 3 on screen 1; `#<uuid, prefix of ≥4>` — an id that survives restarts
- predicates: `cwd:~/proj`, `title:~regex`, `kind:terminal`

**More than one match is an error that lists the candidates** — it will refuse rather than guess for you.

## The commands you'll use

```bash
quickterm state --json                  # everything: screens / workspaces / panes / every pane's size
quickterm list panes                    # the table for humans
quickterm get -t t7                     # the full record of a single pane

quickterm pane new --cwd "$PWD" --cmd "npm run dev" --at @self --where right
quickterm pane new --kind browser --url http://localhost:3000 --at @self --where down
quickterm pane focus -t t7
quickterm pane set -t t7 --zoom on      # absolute setter: on/off, not a toggle
quickterm pane resize -t t7 --ratio 0.6 # also --points +120 / --dir right
quickterm pane move -t t7 --to 1:3
quickterm workspace set-layout dwindle -t 1:3
quickterm workspace goto 2
```

**Tabs** inside a browser pane (`-t` picks the pane, `--tab` picks the tab):

```bash
quickterm browser open   -t b3 --url http://localhost:3000   # opens a new tab
quickterm browser goto   -t b3 --url http://localhost:5173   # points the current tab at a URL (absolute setter)
quickterm browser goto   -t b3 --tab 2 --url https://example.com
quickterm browser reload -t b3 --hard                        # bypass the cache
quickterm browser close  -t b3 --tab 1                       # destructive: pops a confirmation
quickterm browser close  -t b3 --others                      # keep only the current one
```

`--tab` accepts four forms: `1` (a 1-based index), `#<id, or a prefix of ≥4>`, `@active` (the default), `@last`.
Both the indexes and the ids are in `tabList`, in `state` / `get`.
**Closing the last tab closes the whole pane** (same as ⌘W).

Name a pane (terminal panes only — a browser pane's title is the web page's), and afterwards you can find it
by that name:

```bash
quickterm pane set -t t7 --title 'build · web'   # -t 'title:~build' hits it from then on
quickterm pane set -t t7 --title ''              # hand the title back to the shell
```

Name a **workspace** the same way — it renames the pill in the bar:

```bash
quickterm workspace set -t 1:4 --title dev
quickterm workspace set -t :4 --title ''         # clear it: the pill falls back to the index
```

That name belongs to the **slot**, not to the panes inside it: `workspace clear` and closing its last pane
both leave it standing. Three things change it and nothing else does — this command, a right-click rename, and
applying a spec that carries a `title` (the one `spec dump` writes does).

Build a whole workspace in one command (**the most efficient thing you can do here**):

```bash
cat <<'EOF' | quickterm spec apply -t 1:4 --into-empty -f -
{"schema":"quickterm.workspace/1","layout":"scrolling","columns":[
  {"width":0.3,"panes":[{"cwd":"~/proj","cmd":"nvim ."}]},
  {"width":0.4,"panes":[{"cwd":"~/proj","cmd":"npm run dev","hold":true},{"cwd":"~/proj"}]},
  {"width":0.3,"panes":[{"kind":"browser","url":"http://localhost:3000"}]}]}
EOF
```

Dumping the layout you already have, changing two lines and putting it back is safer than writing one from scratch:

```bash
quickterm spec dump -t 1:2 > /tmp/ws.json
quickterm spec apply -f /tmp/ws.json --dry-run   # look at what it would change first
```

## House rules (follow them and you'll stay out of trouble)

1. **Set absolute values; don't count on toggles.** `pane set --zoom on`, not `action toggle-zoom`.
   You cannot see the current state, and a retried toggle undoes what the first one did. Every `pane set` /
   `workspace set-layout` is idempotent: run it twice, same result. Add `--fail-if-noop` and "already in the requested
   state" exits with code 7.
2. **`--dry-run` before you move anything**, `spec apply` above all. It reports what would change and touches nothing.
3. **Address by handle or uuid; never carry "whatever has focus" from one command to the next.** Focus may have moved in between.
4. **Compose layouts with `spec apply`; don't fire off N `pane new`s in a row.** The first reflows once and animates once; the
   second makes the UI flicker, and failing halfway leaves you with a half-built workspace.
5. **Don't hammer it.** Mutations are rate-limited per origin (a burst of 30, refilling at 10/s) and process-wide
   (a burst of 40, refilling at 20/s); over the limit is exit code 6 with `retryAfterMs` in the body. One workspace
   holds at most 32 panes. To wait for the UI to change, use `quickterm events poll --since <seq> --timeout 10`
   (`state`'s reply carries the `seq`; `--timeout` is seconds, or `500ms` / `2m`, up to 300s) — don't poll `state`.
6. **Give `--cwd` an absolute path** (`"$PWD"` or `~/proj`). A relative path is refused (`bad_request`): it would be
   resolved inside QuickTerm's process, whose working directory is not yours, so `.` never means what you meant.
   `~/Desktop`, `~/Documents` and `~/Downloads` are macOS protected directories: QuickTerm can't use them until it has been
   granted "Files and Folders", and the pane still opens but the shell starts somewhere else — the reply then carries a
   `warnings[].code == "cwd_denied"` (**read the code, not the prose**). If you'd rather fail than land elsewhere, add `--require-cwd`.
7. **Read errors as JSON.** On failure stderr is JSON with a stable `code`, and the process exit code is derived
   from that code — never match on the message text:
   **1** a bad argument or a plain failure · **2** QuickTerm is not running · **3** a bad or ambiguous target
   (the body lists the candidates) · **4** `confirmation_required` — nobody answered the confirmation within ten
   seconds, or `spec apply --into-empty` found the workspace non-empty · **5** `denied` — the user pressed Deny,
   or policy refused it (an action that opens a panel) · **6** busy or rate-limited (the body carries
   `retryAfterMs`) · **7** nothing changed, only ever with `--fail-if-noop` · **8** protocol version mismatch.

## What will get stopped

- **Destructive operations** (`pane close`, `browser close`, `screen close`, `workspace clear`,
  `spec apply --replace`) **pop a confirmation dialog** inside QuickTerm, counted once per (calling process,
  command class). The user presses Deny → **exit code 5** (`denied`). Nobody answers within ten seconds → the
  dialog goes away and you get **exit code 4** (`confirmation_required`); either way the command did not run.
  Don't retry; go ask the user.
- **`input send-text` (typing into a pane) is off by default**; the user has to turn on `[control] send-text = true` in the config.
  Even with it on: writing to **your own** pane skips the confirmation — and what decides "your own" is the
  `QUICKTERM_PANE_TOKEN` you inherited, recomputed by the server for the pane `-t` resolved to, never the pane id
  you report about yourself. Writing to any other pane **asks the user every single time** —
  because that amounts to running a command in someone else's shell (which may be root, and may be a live ssh session).
  To run a command, reach for `pane new --cmd "..."` rather than stuffing characters into another terminal.
- **Actions that open a panel** (the theme picker, the main menu, and so on) are refused outright — `interactive_action`,
  exit code 5: they need keyboard interaction, and running them over the socket would only leave the UI stuck half-open.
- **Reading the text on a terminal's screen (`pane capture-text`) is off by default**; the user has to write `[control] capture-text = true`.
  Even with it on: it requires `QUICKTERM_TOKEN`, and **every calling process has to be confirmed by the user once** — including
  reading your own pane. (`send-text` gets an exemption for writing to itself; reading gets none: whatever the user typed before
  handing you the pane may still be sitting on that screen.)
  It changes nothing, so it accepts neither `--dry-run` nor `--fail-if-noop`.
  For the output of your own commands, use `pane new --cmd "..."` or just run them locally — don't go reading someone else's screen.
- **A browser pane's URL and title read `<redacted>`** to any caller without `QUICKTERM_TOKEN` — and so does the per-tab `tabList`.
  Run inside a pane and you have that variable.
- **The whole control plane can be turned down in the config.** `[control] socket = false` means nothing is
  listening: no socket, token or pane token is injected into any pane, and every command that needs the app exits
  with code 2 (`describe` and `version` still answer, out of the CLI's own tables). `[control] mode = readonly`
  lets reads through and refuses every mutation with `denied` (exit code 5). There is no "never ask" mode: the
  confirmation gate is not something the config can switch off.

## How to work well here

- Dev server: `pane new --cwd "$PWD" --cmd "npm run dev" --hold --at @self --where right` —
  the log sits right there where the user can see it at any time, which beats pulling the output into your own context.
- Want the user to look at a web page: `pane new --kind browser --url ...`; don't open the system browser.
- Layout got messy: `quickterm spec dump -t <workspace> > /tmp/before.json`, and one command puts it back if your edit goes wrong.
- Don't leave junk panes behind when you're done — but **closing a pane pops a confirmation**, so ask the user
  whether to close them rather than firing `pane close` yourself.
