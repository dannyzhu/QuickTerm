# Manual launch check (do this after every build)

Unit tests cannot reach this path: under the test host `restoreSession()` is skipped wholesale, and
TCC (privacy grants) cannot be simulated in-process. **Running the binary straight from a terminal
proves nothing either** — on that path the TCC responsible process is the already-authorized
terminal, so it always succeeds. It has to be launched through LaunchServices (`open` / Dock / Finder).

## Background: why it hangs

macOS treats `~/Desktop`, `~/Documents` and `~/Downloads` as protected directories. The grant is
recorded in TCC against the **code signing identity**; this project is ad-hoc signed
(`CODE_SIGN_IDENTITY: "-"`), so the identity is the cdhash, which means **every rebuild is a new
identity** and the existing grant stops applying the moment you rebuild.

If the process was launched by LaunchServices at that point, tccd neither prompts nor denies:
`open(2)` just sits there forever (0% CPU). While restoring a session libghostty opens the archived
cwd synchronously inside `ghostty_surface_new`, so the whole app wedges in
`applicationDidFinishLaunching` and not a single window comes up.

The defence in the code is `Sources/Windowing/WorkingDirectoryGate.swift`: a protected root is first
probed with an `open` on a separate thread under a timeout, and if the probe does not come back the
pane falls back to the engine's default directory and starts as usual. The real fix is a stable
signing identity (Developer ID, or at least a self-signed certificate that stays in the login
keychain), which would let the grant survive across builds.

## Steps

1. Build Debug (`xcodebuild -scheme QuickTerm -configuration Debug build`) and note the product path.
2. Prepare a copy of an archive whose terminal `pwd`s **must** include a few under `~/Documents` /
   `~/Desktop` / `~/Downloads`, and which has at least two windows and one browser pane with tabs:

   ```
   cp ~/Library/Application\ Support/QuickTerm/state.json /tmp/qt-check.json
   ```

3. Launch through LaunchServices (**not** the binary directly), pointing the archive and the socket
   somewhere else so you do not take over the user's own session:

   ```
   mkdir -m 700 -p /private/tmp/qt-check     # the socket's directory must be yours, 0700, and not a symlink
   open -n /path/to/QuickTerm.app \
     --env QUICKTERM_STATE_FILE=/tmp/qt-check.json \
     --env QUICKTERM_CONTROL_SOCKET=/private/tmp/qt-check/c.sock
   ```

   (`--env QUICKTERM_CONTROL_SOCKET=/tmp/c.sock` fails: the socket's directory would then be `/tmp`
   itself, which is a symlink to `/private/tmp`, `ControlSocket.prepareDirectory` refuses it, and the
   control plane never starts listening.)

4. **Requirement: windows are up within 5 seconds, with every screen's panes present.** If they are
   not, it hung again — `sample QuickTerm 3` and look at the main thread; `__openat` at the bottom of
   the stack is exactly the trap this document is about.
5. Then check five more things:
   - With no archive (`QUICKTERM_STATE_FILE` pointing at a path that does not exist) → one new window
     with one terminal;
   - `open -n QuickTerm.app --args --open-browser https://example.com` → one extra browser pane once
     it is up;
   - `quickterm --socket /private/tmp/qt-check/c.sock state --json` returns the whole world (screen
     count / pane count match the archive, the browser pane is there too);
   - **Type `echo $QUICKTERM_SOCKET` by hand inside a restored pane**; it has to print
     `/private/tmp/qt-check/c.sock`. Empty means the control socket was bound too late: the variable
     is baked into the pane at spawn time and no listener started afterwards can put it back, and an
     agent in that pane would go and drive the user's real QuickTerm instead.
     (By hand only: the pane's shell is started by setuid `login`, so `ps -E` cannot show its environment.)
   - **Two seconds after launch** (the debounced save has landed) look at `/tmp/qt-check.json`: the
     `pwd`s that were under `~/Documents` must still be there, not rewritten to the home directory.
     Without the grant the shell really does start in the home directory (`lsof -a -p <shell pid> -d cwd`
     proves it), but the archive has to keep the user's own directories — see
     `SurfaceView.deniedWorkingDirectory`. The same directory should also have gained a
     `state.previous.json` (the safety copy taken before this process's first write).
6. Clean up: kill this instance (`kill` that pid), delete `/tmp/qt-check.json` and `/private/tmp/qt-check`.

## The automated half

`Tests/WorkingDirectoryGateTests.swift` moves the TCC-wedged environment into the suite with a probe
that never answers, covering the real `restoreSession(from:)` (two screens, five workspaces, several
terminals under `~/Documents`, one browser pane with several tabs) and asserting that every pane gets
built and that the whole thing returns in time.
It catches the regression where the code hands a cwd straight to the engine; it cannot catch the
launch mechanism itself — that half is the manual check above.
