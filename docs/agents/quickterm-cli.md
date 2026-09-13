# The quickterm control plane (CLI and AI agents)

QuickTerm ships a control plane on a Unix domain socket, plus a `quickterm` command-line tool inside the app bundle.
**Read `quickterm describe --json` once first** (the whole control plane as a machine-readable schema); after that you never have to go back to `--help`.

## Install it

```
quickterm install-cli --alias qt        # symlink into /usr/local/bin, or ~/.local/bin when that is not writable
```
There is a menu item too: QuickTerm ▸ Install the quickterm Command Line Tool…
The binary lives at `QuickTerm.app/Contents/SharedSupport/quickterm`
(**not** `Contents/MacOS`: APFS is case-insensitive, so `quickterm` would clobber the main executable `QuickTerm`).
It **never asks for an admin password**; run it again after you upgrade or move QuickTerm.app.

## Zero configuration inside a pane

Every pane is created with these in its environment:

| Variable | Meaning |
|---|---|
| `QUICKTERM_SOCKET` | path to the control socket |
| `QUICKTERM_PANE` | this pane's UUID — what `-t @self` resolves through |
| `QUICKTERM_SCREEN` / `QUICKTERM_WORKSPACE` | the indices **at creation time** (a hint; they do not update when the pane moves) |
| `QUICKTERM_TOKEN` | proof of origin, **not a permission boundary** (see below) |
| `QUICKTERM_PANE_TOKEN` | **one per pane**, a verifiable origin mark. Used in exactly one place: skipping confirmation when `input send-text` writes to the caller's own pane |

`env | grep QUICKTERM` in any pane shows them.

## The command surface

Queries and the passthrough (Phase 1):

```
quickterm state   [-t target] [--fields a,b]
quickterm list    screens|workspaces|panes [-t target] [--fields a,b]
quickterm get     -t target
quickterm action  <wm-action> [-t target] [--precise]
quickterm action  --list
quickterm describe [--json]
quickterm version
quickterm install-cli [--alias qt] [--dir directory]
```

The noun-verb layer (Phase 2, **this is the layer meant for agents**):

```
quickterm pane      new|close|focus|move|swap|set|resize|capture-text
quickterm browser   open|goto|reload|close          # tabs inside a browser pane
quickterm workspace goto|set-layout|set|equalize|clear|count
quickterm screen    new|close|move|focus|set
quickterm app       get|set
```

Compose it all at once (Phase 3):

```
quickterm spec dump     [-t target] [--all] [--relocatable] [--include-ids]
quickterm spec validate [-f file | --spec JSON]
quickterm spec apply    [-f file | --spec JSON] [-t target]
                        [--into-empty | --replace | --reuse] [--dry-run]
```

Events and typing (Phase 4):

```
quickterm events poll   [--since <seq>] [--timeout 5s] [--limit N] [--types a,b]
quickterm events follow [--since <seq>] [--types a,b]
quickterm input send-text <text> -t target [--enter]
```

MCP (Phase 5):

```
quickterm mcp                    # stdio MCP server; the host launches it, do not type it in a terminal
quickterm mcp --list-tools       # the tool table itself (JSON)
```

`action` is the **keybinding-parity passthrough**: all 67 `WMAction`s go straight to `perform()` untouched,
so "anything a keybinding can do, the command line can do" was true on day one and cannot quietly drift out of true.
What rides along with that reach is **keybinding semantics**: these are toggles, and they act on whatever has focus.

**The noun-verb layer is absolute setters, every one of them** — that is the rule the whole of Phase 2 is built on:

| Don't write | Write | Why |
|---|---|---|
| `action toggle-zoom` | `pane set -t t7 --zoom on` | an agent cannot see state; retrying a toggle undoes itself |
| `action toggle-layout` | `workspace set-layout dwindle -t :4` | the toggle only reaches the **active** workspace, and cannot name a target |
| `action move-to-workspace-3` | `pane move -t t7 --to :3 [--follow]` | the former moves only the focused pane, and forces you to follow it |
| `action resize-right` | `pane set -t t7 --width 0.33` (or `pane resize -t t7 --dir right`) | absolute values are replayable, increments are not |
| `action theme-picker` | `app set theme tokyo-night` | that panel is driven by arrow keys; running it over the socket leaves the UI stuck halfway |

Run the same setter twice and the second run does nothing (`changed:false`);
add `--fail-if-noop` and the second run is **exit code 7** — which is exactly the signal for "I thought I changed something, and I did not".

### The two flags every mutating command takes

- `--dry-run`: returns `changes` (a diff) and **does not touch a single byte**. Rehearse before you commit.
  (Only the noun-verb layer implements these two. `action <wm-action>` is a direct line to `perform()` with no diff
  to preview, so passing them there is a `bad_request` — exit code 1, refused before the confirmation gate.)
- `--fail-if-noop`: exit code 7 when you are already in the requested state, instead of succeeding silently.

Mutating replies share one envelope:

```json
{"ok":true,"seq":415,"resolved":{"screen":1,"workspace":2,"pane":"t9"},
 "data":{"command":"pane.set","applied":true,"changed":true,"dryRun":false,
   "changes":[{"path":"1:2.t9.zoom","from":"off","to":"on"}],
   "pane":{"handle":"t9","…":"…"},"undo":"Control plane: pane set"}}
```

### Where it lands (`--at` / `--where`)

`--where right|left|up|down|stack` runs the very same landing algorithm as a mouse drop (literally the same code),
and `--at` is the anchor pane: `quickterm pane new --cwd ~/proj --cmd 'npm run dev' --at t1 --where right`.
A pane created with `--cmd` closes itself when the command exits (`--hold` keeps it around).

### Sizes: you can read them, and you can change them

**Every read command carries sizes.** Each pane in `state` / `list panes` / `get` has a `size` block:

```json
"size":{"rect":[0.3,0,0.7,0.7],"points":[1086,630],"cols":135,"rows":33,
        "split":"vertical","ratio":0.7}
```

- `rect` = the normalized rectangle `[x,y,w,h]` inside the workspace's layout area, **origin at the top left**,
  computed from the ratios / column widths in the model (not read off a frame, so it never hands you last frame's
  numbers mid-relayout); in scrolling the horizontal unit is "one viewport width", so `x+w` goes past 1 when the
  strip overflows. **`rect` is the accurate one.**
- `points` = this pane's **slot** size in points. The base is the workspace layout area = the window's content area
  minus the status bar at the top, minus the ring of pane-gap padding around the outside — exactly the patch of
  ground the split tree really lays out on, and the same base `--points` converts against and the divider clamps to.
  Inside that slot there is still each pane's own ring of padding and the terminal's pane-padding, so the terminal
  canvas is smaller than the slot: if you want the grid, read `cols`/`rows` (measured by the engine), don't divide
  points by a character width. The whole field is absent until the window is mounted.
- dwindle adds `split`/`ratio` (the direction and ratio of the nearest divider);
  scrolling adds `width` (the column width factor) and `share` (the share within the column = 1 / panes in it).
- `hidden: true` = some pane in this workspace is zoomed and this is not that one: **it has no place on screen at all
  right now**, so it gets no `points`. `rect`/`ratio`/`width` still describe the tiling underneath — that is what
  `pane resize` changes, and what un-zooming returns to. The zoomed one reports the whole layout area.

The skeleton of a dwindle workspace is that tree, and it **uses the same vocabulary as `spec dump`**
(`split`/`ratio`/`a`/`b`), with handles at the leaves:

```json
{"index":3,"layout":"dwindle","panes":["t8","b3"],
 "tree":{"split":"vertical","ratio":0.62,"a":{"pane":"t8"},"b":{"pane":"b3"}}}
```

**Resizing has the same reach as the mouse**; three routes, one per mouse gesture:

```sh
quickterm pane resize -t t8 --ratio 0.62              # = drag that divider to 62%
quickterm pane resize -t t8 --points +120             # = drag it 120pt right/down (a bare number = set the a side to N pt)
quickterm pane resize -t t8 --split root --ratio 0.3  # = go drag an ancestor divider (path of a/b, the root one is root)
quickterm pane resize -t t7 --dir right --points 100  # = press ⌘⌃→ once (also the ⌘right-drag route)
quickterm pane resize -t t7 --width +0.05             # scrolling column width factor (--points works in points instead)
```

The clamping rules are the same ones too: `--ratio` / `--points` take the divider-drag route (each side keeps at
least 10pt — same function, same base as the drag, so the command line can reach nothing the mouse cannot),
`--dir` takes the keybinding route (0.1–0.9), and column width runs `0.25–0.90`.
At the boundary it is a no-op (`--fail-if-noop` exits 7).
`--dir` (the nearest divider on that axis) and `--split` (name one) are mutually exclusive: passing both is an error,
and it **never** quietly picks one of them and moves that.
When you compose a workspace, write the sizes straight into the spec (`columns[].width` / a `ratio` at each level of
`tree`): `spec dump → apply → dump` is a byte-for-byte fixed point even with non-default ratios.

### Name a pane: `pane set --title`

```sh
quickterm pane set -t t7 --title 'build · web'   # = the right-click "Change Terminal Title"
quickterm get -t 'title:~build'                  # and now you can address it by title
quickterm pane set -t t7 --title ''              # empty string = hand it back to the shell
quickterm pane set -t t7 --title '   '           # whitespace only = the same thing, hand it back
```

An absolute setter: run it twice and you get the same result, the second time with `changed:false`
(exit 7 with `--fail-if-noop`).
**Whitespace is trimmed, and a value that is nothing but whitespace means the same as `''` — hand the title
back to the shell.** It does not pin a blank title: that used to leave a pane you could neither read on the
border nor address with `title:~`, and which the shell could never update again.
Because of the trim, `--title 'dev'` after `--title ' dev '` is correctly a no-op rather than a reported change.

"Did it change?" is decided by **whether the title has been taken over**, not by whether the string looks the
same. A shell that happens to be printing `dev` in its own title has not pinned anything, so setting
`--title dev` there is a real change (`changed:true`) — it takes the title away from the shell.
`state` / `list` / `get` say which is which: a pane whose title is pinned carries **`titleSet: true`**, and a
pane whose title still belongs to the shell **omits the field entirely** (the same convention `redacted`
follows). Read `titleSet`, not the text, when what you need to know is "is this name going to stay put".
`pane.title.changed` carries `titleSet` too, so a subscriber never has to call `get` to find out — and the
event fires when the pin flips even if the text is identical.
The title shows up in the `title` field of `state` / `list` / `get`, and **`title:~<regex>` is a first-class way to
address things** — naming the few panes that stick around is far steadier than looking up a handle every time
(handles are recycled when a pane closes).
Only terminal panes take one: a browser pane's title comes from the page, and the next navigation overwrites whatever
you set.
A title set this way is also drawn on the pane's top border (20 characters max; turn it off with
`[appearance] pane-title = false`).

### Name a workspace: `workspace set --title`

```sh
quickterm workspace set --title dev              # = right-click the workspace pill in the status bar
quickterm workspace set -t 2:4 --title 'web · logs'  # name the 4th workspace on a particular screen
quickterm workspace set -t :4 --title ''         # empty string = clear it, the pill falls back to the index
```

An absolute setter, with rules identical to `pane set --title` point for point (200-character limit, control
characters refused, run it twice and the second run reports `changed:false`, exit 7 with `--fail-if-noop`).
With no `-t` it means **the active workspace of whichever screen was addressed**.

The name belongs to the **slot**, not to the panes inside it: `workspace clear`, closing the last pane, and
`spec apply --replace` swapping out every pane in it all leave the name alone.
Three things can change it: this command, a right-click rename, and a spec that **carries a `title`** —
the one `spec dump` writes does, so applying screen 1's dump to workspace 5 carries the name over as well.
The name appears in the workspace `title` field of `state` / `list workspaces` / `get` (never redacted),
and a rename emits a `workspace.changed` event (carrying `title`).
`spec dump` writes it into `title` and `spec apply` lands it — **no `title` = don't touch the target workspace's name**
(the same rule as `visibleColumns`), so `dump → apply → dump` is still a byte-for-byte fixed point.
The status bar shows at most 12 characters; when a row of named pills will not fit, the whole row falls back to
indices (`[appearance] workspace-title = false` turns the display off entirely, though the names are still there).

### Browser tabs: `browser`

```sh
quickterm browser open   -t b3 --url http://localhost:3000   # a new tab
quickterm browser goto   -t b3 --url http://localhost:5173   # point the current tab at a URL
quickterm browser goto   -t b3 --tab 2 --url https://a.b     # name the tab
quickterm browser reload -t b3 --tab 1 [--hard]              # reload (--hard bypasses the cache)
quickterm browser close  -t b3 [--tab 1 | --others] [--force]
```

- **`-t` names the pane (`b3`), `--tab` names a tab inside it.** A tab can be written four ways:
  a **1-based index** (which shifts as tabs open and close), **`#<id, or a prefix of ≥4>`** (stable for as long as the
  tab lives — this is the one an agent should use), **`@active`** (the default) and **`@last`**. All of them read back
  verbatim from `tabList` in `state` / `get`:

  ```sh
  quickterm get -t b3 --json | jq '.data.pane.tabList'
  # [{"index":1,"id":"8A1F…","active":true,"title":"docs","url":"https://…"}]
  ```

- `browser goto` is an **absolute setter**: already on that URL means it does nothing (`--fail-if-noop` exits 7).
  To force a refetch use `browser reload` — "point it somewhere" and "reload" are two different intents.
  The comparison happens **after normalization**: `http://localhost:3000` and the `http://localhost:3000/` WebKit
  reports once it lands are the same page (likewise scheme / host case and default ports).
  And that is where it stops — a trailing slash on the path (`/a` vs `/a/`), query order, and the fragment are all
  **different pages**.
  The same rule drives browser-pane matching in `spec apply --reuse`, so a hand-written `"url":"http://localhost:3000"`
  in a spec does not tear the pane down and rebuild it every time.
- **`browser close` on the last tab closes the whole pane**, exactly like ⌘W (Chrome semantics).
  It is destructive and asks for confirmation first; `--others` always keeps the one `--tab` names, and never closes
  the pane.
- **The redaction rule does not bend an inch**: for a caller without `QUICKTERM_TOKEN`, `title` / `url` in `tabList`
  read `<redacted>` (`index` / `id` / `active` still come through — you address tabs with those), and the diff in the
  mutation envelope is redacted too. For such a caller **`goto` stops being idempotent**: it counts as a change every
  time (`changed` is always true, and it loads as usual), because otherwise a single `--dry-run --fail-if-noop` would
  become a yes/no probe for "is this tab sitting on that URL right now" — a URL that caller cannot even read.
- **URLs and titles never reach the system log**: the in-app activity panel writes them in full (the person reading it
  is you), but the copy mirrored into the unified log (OSLog) keeps the path alone — `1:2.b3.tab1.url` changed,
  never what it changed to.
  That log lands in `/var/db/diagnostics`, survives app exit, and `sysdiagnose` packages it up.
  Terminal titles (`pane set --title` / `pane close`) work the same way.

### Read a terminal screen: `pane capture-text`

```sh
quickterm pane capture-text -t t7                      # the viewport
quickterm pane capture-text -t t7 --scrollback 200     # plus 200 lines of history above it
quickterm pane capture-text -t t7 --json | jq -r .data.text
```

You get **the text on that pane's screen right now**, along with the `cols` × `rows` the engine measured.
This is how you answer "what did that command I just started actually do?" — the event stream will never carry a
pane's output.

**It is `sensitive`, not `read`**, because a shell's viewport can hold tokens, a password typed but not yet entered,
or private code. Four gates, each independent:

- **Off by default**: refused (exit code 5) until `[control] capture-text = true`.
  It and `send-text` are **two** switches; turning one on never turns on the other.
- The caller has to carry this launch's `QUICKTERM_TOKEN` (the same one browser URL redaction keys off) —
  automatic when you run inside a QuickTerm pane; a caller that cannot read browser titles can never read a terminal
  screen.
- Every calling process needs the user to **confirm once** inside QuickTerm (the dialog spells out that this is
  "read all the text on the screen of pane X").
  There is no "reading your own pane needs no confirmation" exemption: a process could not read its own tty's
  scrollback buffer in the first place.
- The text **appears exactly once, in that one reply**: not in the activity log, not in the event stream, not in the
  unified log.

It changes nothing, so it **does not take `--dry-run` / `--fail-if-noop`** (passing them is a `bad_request`, exit
code 1): `--dry-run` elsewhere also means "no confirmation needed", which here would be a back door around every gate
straight to the full contents.

### When the working directory cannot be used: `cwd_denied` and `--require-cwd`

macOS counts `~/Desktop` `~/Documents` `~/Downloads` as protected directories, and a grant is recorded against a
**code-signing identity**.
Without the grant QuickTerm does not hand that directory to the engine (it would hang at startup — see
`WorkingDirectoryGate`), so the shell starts in the default directory. This **is no longer silent**:

```sh
quickterm pane new --cwd ~/Downloads
# ⚠️ Working directory /Users/you/Downloads could not be used: … (cwd_denied)
#    → Tick QuickTerm's entry under System Settings ▸ Privacy & Security ▸ Files and Folders…
```

```json
{"ok":true,"data":{"command":"pane.new","applied":true,
  "warnings":[{"code":"cwd_denied","path":"/Users/you/Downloads",
               "message":"…","hint":"…"}]}}
```

- By default it **opens the pane anyway and attaches a warning**: the command really did succeed, and turning it into
  a failure would take down every script that does not care about the directory.
  **Branch on `code`** (`cwd_denied` is stable), never match the message text.
- A script that cannot live with that fallback adds **`--require-cwd`**: an unusable directory exits 5, and **not one
  pane is created**. `spec apply` takes the same flag (it fails during the precheck, touching nothing).
- It only applies to **panes that actually use a cwd**: a browser pane does not consume `--cwd` (it only wants a URL),
  so `pane new --kind browser --cwd ~/Downloads` neither warns nor gets blocked by `--require-cwd` — a script that
  always passes `--cwd "$PWD"` will not fail to open a browser pane just because the current directory happens to be
  protected.

## Compose it all at once: `spec`

**To lay out a whole workspace, use `spec apply`; do not fire N `pane new`s.**
N commands = N relayouts, N animations, N failure points, and a failure halfway through leaves behind a half-built
thing nobody can explain; `spec apply` computes once and lands once (the whole layout is computed first, then assigned
to the model in one go).

The public format is `quickterm.workspace/1` (plus two envelopes, `quickterm.screen/1` and `quickterm.session/1`,
which reuse the same vocabulary verbatim). **Every field may be omitted**, so two lines is a legal spec:

```json
{"columns":[{"panes":[{}]},{"panes":[{},{}]}]}
```

A fuller one (scrolling: columns × a vertical stack inside each column):

```json
{ "schema": "quickterm.workspace/1", "layout": "scrolling", "visibleColumns": 3,
  "columns": [
    {"width":0.33,"panes":[{"kind":"terminal","cwd":"~/proj","cmd":"nvim ."}]},
    {"width":0.33,"panes":[{"kind":"terminal","cwd":"~/proj","cmd":"npm run dev","hold":true,
                            "env":{"NODE_ENV":"development"}},
                           {"kind":"terminal","cwd":"~/proj"}]},
    {"width":0.33,"panes":[{"kind":"browser","url":"http://localhost:3000"}]}],
  "focus": {"column":0,"row":0} }
```

dwindle is a split tree instead (`split` = `horizontal` puts a left and b right, `vertical` puts a on top and b below):

```json
{ "layout":"dwindle",
  "tree":{"split":"horizontal","ratio":0.6,
          "a":{"pane":{"cwd":"~/proj"}},
          "b":{"split":"vertical","ratio":0.5,
               "a":{"pane":{"cmd":"htop","hold":true}},
               "b":{"pane":{"kind":"browser","url":"http://localhost:3000"}}}},
  "focus":{"path":"b.a"} }
```

Defaults: `kind` = terminal, `ratio` = 0.5, `width` = derived from the visible column count,
`cwd` = inherited from the anchor pane, `focus` = the first pane. The field table lives in
`quickterm spec apply --help` and in `specSchema` in `describe --json` (one source, printed in two places).

Three modes:

| Mode | What it means |
|---|---|
| `--into-empty` (the default) | fill an **empty** workspace only; a non-empty one is refused (exit code 4). **It cannot destroy anything** |
| `--replace` | overwrite: every existing pane goes through the real close path (**destructive**, confirms first). An identical spec is a no-op |
| `--reuse` | panes that match stay exactly where they are (a running dev server is not restarted); the rest are closed / created |

The typical workflow — **dump one you know works, change two fields, land it again**:

```sh
quickterm spec dump -t 1:2 > dev.json          # what it prints is the spec itself; redirect it straight to a file
vi dev.json                                     # e.g. change one column's width to 0.5
quickterm spec apply -f dev.json -t 2:4 --dry-run   # look at the diff first: geometry-only changes mean no pane gets rebuilt
quickterm spec apply -f dev.json -t 2:4 --reuse
```

A few things you have to know:

- `cmd` / `env` / `hold` are **write-only**: a live surface does not remember what command started it, so
  `spec dump` never gives `cmd` back. For a slot that carries a `cmd`, `--reuse` keeps the matching pane in place
  (**it does not re-run it**, so retrying never restarts your dev server); `--replace` means tear down and rebuild, so
  that command does get started again.
- The `id` in `--include-ids` says "this exact pane and no other", and **only `--reuse` honors it**:
  otherwise you dump a spec with ids, change a `cwd`, `--replace` it, and every slot matches by id while your edit is
  thrown away wholesale.
- `dump → apply → dump` is a **fixed point**: land a dump back and dump again, and you get the same bytes.
- An unrecognized key is always an error (a misspelled `colums` is never silently ignored); a number out of range is
  an error that names the range, **never a silent clamp**.
- A caller without a token cannot read a browser pane's URL (`redacted:true`, the same rule as `state`):
  apply such a dump back and the browser pane opens on the home page instead of the original URL.
- `spec apply` **never moves windows**: `display` / `frame` in the screen envelope are echoed back by dump only.
  To move a window use `quickterm screen move`.
- A failure after the knife is in reports `partial_apply` (exit code 1): the workspace **has already been changed**,
  so run `spec dump` again, look at where things stand, and then decide how to clean up — it will never pretend
  nothing happened.

## Events: `seq` and `events poll`

Every successful change advances one globally monotonic `seq` (the one `state` and every reply carry).
**Both places measure with the same ruler**: poll with the seq a mutation returned and you will not miss the events
your own command produced.

```sh
seq=$(quickterm state --json | jq .seq)
quickterm events poll --since "$seq" --timeout 30s     # one call answers "what happened since I last looked"
```

- **`events poll` is the shape an agent wants** (one request, one reply, long-polled).
  `events follow` is an NDJSON stream for humans and shell scripts — a stream that never ends is pure overhead for a
  model: every line enters the context, and you have to watch it yourself.
- The `seq` that comes back is **the value to pass as `--since` next time**, even when the batch was empty
  (`timedOut: true` is not an error).
- The buffer is a ring: `missed: true` means events were pushed out in between, your snapshot is incomplete, so
  **read `state` again**.
- Nine event types: `pane.opened` `pane.closed` `focus.changed` `workspace.changed` `layout.changed`
  `screen.opened` `screen.closed` `pane.title.changed` `pane.cwd.changed`.
  `workspace.changed` has two causes — a workspace switch, or a workspace being renamed — and the `title`
  field tells the three cases apart:
  **no `title` field at all** = a switch (the name was not touched) · **`title` with a name** = renamed to that
  name · **`title` as `""`** = the name was cleared, and the pill falls back to the index.
  Absent and empty are deliberately different things here; do not collapse them.
- **No event ever carries a pane's output** — only structure, titles and cwds, and for a caller without a token a
  browser pane's title / cwd are redacted exactly as in `state`. To see output, go look in that pane.
- Some changes (`app set theme`, `screen set --fullscreen`) advance `seq` without a typed event of their own:
  then all you know is "the snapshot is stale", and you re-read `state` to find out what.
- **The `data.seq` you get back is the cursor; keep polling with it and you miss nothing.** When `--limit` truncates a
  batch it only reaches the last event actually sent, and comes with `truncated: true` — see that and poll again
  immediately with that seq, don't wait for the next timeout. (`missed` is a different story: those events are out of
  the buffer for good, so re-read `state`.)

## Typing into someone else's shell: `input send-text`

```sh
quickterm input send-text 'git status' -t @self --enter
```

**This command is typing on that tty** — and that shell might be root, or a live ssh session.
So:

- **Off by default**: refused until `[control] send-text = true` in `~/.config/quickterm/config.toml` (exit code 5).
- Writing to the caller's **own** pane needs no confirmation (that tty was already its own). The test only accepts the
  **verifiable** token: the `QUICKTERM_PANE_TOKEN` the request carries has to match the freshly computed HMAC for the
  pane `-t` **actually resolved to**.
  The self-reported `QUICKTERM_PANE` plays no part in the test (the server cannot verify it), so setting it to somebody
  else's UUID buys you nothing.
- Writing to **any** other pane is confirmed every single time, and that approval **is not cached**;
  the dialog lists **the text about to be typed** (sanitized and truncated) and whether a Return follows —
  what the user approves is "this string", not a blanket "typing allowed".
- Control characters are always refused (refused, not filtered); **a newline only ever comes from an explicit
  `--enter`** — text without `--enter` just sits on the command line and does not run.
- `-t` is mandatory: there is no "type into whatever pane has focus" spelling.
- The text itself **never enters the activity log** (the log records "how many characters + whether Return followed").

## MCP: `quickterm mcp`

The same command table also generates a stdio MCP server with **13 coarse-grained tools** (not one tool per command):

```sh
claude mcp add quickterm -- /usr/local/bin/quickterm mcp     # Claude Code
codex mcp add quickterm -- /usr/local/bin/quickterm mcp      # Codex CLI
quickterm mcp --list-tools | jq -r '.tools[].name'           # see what gets exposed
```

The tools: `quickterm_describe` `quickterm_state` `quickterm_action` `quickterm_new_pane`
`quickterm_focus` `quickterm_arrange` `quickterm_close` `quickterm_browser`
`quickterm_read_terminal` `quickterm_dump_spec` `quickterm_apply_spec`
`quickterm_poll_events` `quickterm_send_text`.

- Which commands from the table sit behind each tool is written in its `description`, and in `mcpTools` in
  `quickterm describe --json`. The parameter names are identical to the CLI's (`target` / `dry-run` / …).
- The annotations are **mechanically** mapped from the safety classes: `read` → `readOnlyHint`,
  `destructive` / `sensitive` → `destructiveHint`, `idempotent` → `idempotentHint`.
  Hosts use them to auto-allow reads and to prompt on destructive calls — a **second, independent** gate on top of
  QuickTerm's own confirmation.
- The MCP layer **has no privileges of its own**: every `tools/call` goes over the same socket, through the same
  confirmations, the same rate limiting and the same activity log.
- `events follow` (a stream) and `install-cli` (which creates symlinks) are deliberately not exposed over MCP;
  `spec` can only be passed inline (there is no `-f` on the MCP side: reading files is always the caller's job).
- **Which one when**: interactive, one-off control goes through MCP (the host layer does the gating for you);
  batch composition goes through the CLI — the tool table is a context tax you pay every session (roughly 70 KB of
  schema), while the CLI costs you not one token until you call it.

## Addressing

`screen:workspace.pane`, every part optional, defaulting rightward to the current context.

- **screen**: 1-based index (= the window title), `#uuid:` (mind the colon), `@current`, `@primary`
- **workspace**: 1-based index (= ⌘1..0), `@active`, `@next`, `@prev`
- **pane**: `t7`/`b3` short handles, `#uuid` (prefix of ≥4), `@focused` (the default), `@self`,
  `@left @right @up @down`, `@next @prev`
- **predicates**: `title:~<regex>`, `cwd:<prefix>`, `kind:terminal|browser`, `role:file-manager`
  - `title:~` regexes share a 200ms matching budget across the whole command; a timeout is a `bad_target` error
    (exit code 3) rather than a wedged main thread: nested quantifiers (`(a|aa)+`, `(.|.)+`) are exponential on
    ICU. **Don't write nested quantifiers**, or just use a handle.
  - While `expose-browser` redaction is in effect, browser panes **stay out of the `title:~` candidate pool** —
    otherwise the predicate would become a channel for probing a redacted title character by character.

Disambiguation rules (nothing is left to "it depends"): a bare number is a **screen** (pane handles always carry a type
prefix); a bare `#uuid` is a **pane**, and naming a screen by uuid requires `#uuid:`; a `:` or `.` inside a predicate
is never taken as a separator.

**Multiple matches are always an error that lists the candidates (exit code 3), never the first one.**

How "current" is resolved: an explicit `-t` → the caller's own pane (`QUICKTERM_PANE`) →
the key window while the app is frontmost → the window that was key most recently → the first screen.
Every reply echoes `resolved`, so you know what you hit without sending a second query.

## Output and errors

- stdout is a TTY → human-readable; not a TTY → JSON. **An agent needs no flag at all.**
- Errors are always **JSON on stderr**, carrying a stable `code` and `exit`. **Never match on the message text.**
- Exit codes: 0 success · 1 failure · 2 not running · 3 bad or ambiguous target · 4 confirmation required ·
  5 denied · 6 busy / rate-limited · 7 no-op · 8 protocol version mismatch
- **Exit codes are coarse on purpose; `error.code` is the fine signal.** Four different codes share exit 5,
  and they want opposite things from you:

  | `code` | what happened | retrying |
  |---|---|---|
  | `denied` | a human pressed **Deny** in QuickTerm's dialog | may well succeed next time — but ask the user first |
  | `disabled` | a switch is **off**: `[control] mode = "off"` / `"readonly"`, a sensitive command never enabled, `[control] mcp = false`, or `pane capture-text` from a caller carrying no `QUICKTERM_TOKEN` | pointless until the user edits the config; the `hint` names the switch |
  | `cwd_denied` | `--require-cwd` plus a directory macOS will not hand over — **nothing was created** | pointless until the Files-and-Folders grant is given |
  | `limit` | a structural cap or floor: tabs per browser pane, panes per workspace, the last screen, shrinking a workspace below the panes in it | pointless until something is closed or freed |

  `cwd_denied` is spelled **exactly** like the `cwd_denied` in `warnings[]`, and that is deliberate: it is one
  condition with two reportings — a warning when the command goes ahead anyway, this error when `--require-cwd`
  asks it not to — so you branch on the same string either way.
  New codes are only ever appended. Branch on `code`, never on the message.

## Security

**On** by default, in mode `ask` (change it in the `[control]` section of `~/.config/quickterm/config.toml`).
`mode` has exactly three settings: `off` (does not listen) · `readonly` (reads only) · `ask` (the default; `on` is an
alias for `ask`).
**There is no "never ask" setting**: the confirmation gate can only be bypassed via `off` / `readonly`, and a
misspelled value just falls back to `ask`.

- **read** is silent; but **a caller with no origin token cannot read a browser pane's URL or title** (`<redacted>`) —
  browser panes hold sessions the user is logged into, which makes `quickterm state` an exfiltration surface all by
  itself.
- **mutate** runs silently, but **visibly**: the status bar flashes (naming the command and the pane it claims to come
  from), and it is recorded in full under QuickTerm ▸ "Control Plane Activity…"; layout changes are registered with the
  UndoManager, so Edit ▸ Undo (⌘Z) rolls the whole thing back. (With focus in a terminal pane ⌘Z belongs to the
  terminal — use the menu item.)
  Mutating commands are rate-limited per origin; over the limit is exit code 6 with a `retryAfterMs`.
- **destructive** — anything that **closes something of the user's** (`close-pane`, `pane close`, `browser close`,
  `workspace clear`, `screen close`, `spec apply --replace`) — is **confirmed once per calling pid and command class**,
  and that answer is remembered for the rest of this launch;
  the process name and pid the dialog shows come from the kernel (`LOCAL_PEERPID`), so stealing a token does not let
  you impersonate anyone;
  the line in the dialog saying "claims to come from pane t3" is **the caller's own claim**, which the server cannot
  verify — hence the wording.
  The dialog names **the one pane that was resolved** (handle + title + screen/workspace),
  and after approval the identity is checked once more before the knife goes in — if another command moved focus while
  the dialog was up, the whole thing comes back busy and nothing happens.
  10 seconds with nobody answering → exit code 4; approve it inside QuickTerm and retry.
  While another dialog is in front of the user, **every** mutating command returns `busy` (exit code 6).
  **`--force` is not a way around any of this.** QuickTerm's own "a process is still running" prompt is a
  *different* prompt — the one it shows when you close a pane by hand — and `--force` is the flag that skips
  that one, and only that one. There is no flag that skips the control plane's confirmation.
- **sensitive** (`input send-text`, `pane capture-text`) is **one switch per command, both off by default**,
  and the confirmation cache is per command as well — approving "read the screen" never quietly approves "type into
  the shell".
  - `input send-text` (`[control] send-text = true`): only writing to the caller's own pane skips confirmation,
    and it has to prove that with the per-pane `QUICKTERM_PANE_TOKEN` (the self-reported `QUICKTERM_PANE` does not
    count); writing to **any** other pane is confirmed every time (with the text in the dialog), and that approval is
    not cached.
  - `pane capture-text` (`[control] capture-text = true`): **no self-read exemption**;
    the caller must also carry `QUICKTERM_TOKEN` (the same one browser redaction uses), and then it is
    **confirmed once per calling process**;
    it does not take `--dry-run` (that would become a back door around the confirmation); the text never enters any
    durable record.
- **interactive** (`theme-picker` `next-background` `keybind-help` `main-menu` `open-settings`
  `web-extensions`) is **always refused**: these open panels or pop-up menus that need the keyboard.
- A connection must share QuickTerm's uid (`LOCAL_PEERCRED`, checked on every connection, no exceptions);
  the socket is 0600, the directory 0700.
- **`QUICKTERM_TOKEN` is proof of origin, not a permission boundary.** There is one per launch, injected into every
  pane, so all it can answer is "this command came from **some** QuickTerm pane";
  **any design of the form "has a token, skip the confirmation" is wrong**.
- **`QUICKTERM_PANE_TOKEN` is one per pane** (`HMAC(per-launch key, paneID)`), and answers the question the other one
  cannot: "from **which** pane". It is used in exactly one place, the self-write exemption in `input send-text`, and it
  is not a permission boundary either: holding it only means "I am in this pane".

The real threat is not another user, it is **a subverted agent**: an agent in a pane reads a poisoned web page /
README / CI log and is then told to go run `quickterm` commands. That is why the confirmation gate has been there
since version one.

## Rules of thumb for agents

1. Read `quickterm describe --json` once at the start of a session; stop going back to `--help`.
2. Address things **by handle or `#uuid`**, never by pointing at "that focused pane" across two commands — focus
   handoff is asynchronous.
3. A mutating reply already carries the affected subtree and the new `seq`, so **do not** follow it with a `state`.
4. On exit code 3, read `candidates`; do not retry the same ambiguous target.
5. `--fields` cuts `state` down; the full JSON for a six-screen session eats a great deal of context.
6. **Prefer the noun-verb layer over `action`**: the former is absolute setters and replayable, the latter is toggles,
   and retrying one undoes it.
7. Before a destructive command (`pane close` / `workspace clear` / `screen close`), run `--dry-run` and read
   `changes`.
8. Exit code 7 is not an error; it is "the state you asked for already holds". Only add `--fail-if-noop` when you
   **need to know whether you really changed something**.
9. **Compose in bulk with `spec apply`, do not fire N `pane new`s**; `--dry-run` before `spec apply --replace`.
10. To change an existing layout: `spec dump` → edit fields → `spec apply --reuse`. Don't start over (`--replace` ends
    the running processes along with everything else).
11. To wait for something to happen, use `events poll --since <seq> --timeout 30s`, **don't poll `state`**:
    one call answers "what happened since I last looked", while polling `state` stuffs the entire snapshot into your
    context every time.
12. Events do not carry a pane's output, and never will. To read the text on screen use `pane capture-text`
    (the user has to enable it under `[control]` and confirm once); to capture a command's output reliably,
    `pane new --cmd 'cmd > /tmp/out' --hold` into a file is still the steadiest route.
13. `input send-text` is not a "run a command" API: it is **typing on somebody else's keyboard**.
    To run something, reach for `pane new --cmd` first — that route has a clear process boundary, and it will not
    blunder into a shell that is waiting for a password.
14. Name the panes that stick around (`pane set --title`) and address them with `-t 'title:~…'` afterwards —
    handles are recycled when a pane closes, names are not.
15. Address browser tabs with `--tab #<id>` (copied from `tabList`), not by index: opening one new tab shifts every
    index.
16. Mount `quickterm mcp` for interactive, one-off control (the host layer handles the confirmations for you);
    compose in bulk straight from the CLI — the tool table is a context tax you pay every session, while the CLI costs
    you not one token until you call it.
