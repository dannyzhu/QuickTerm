# Session restore: pane content and agent resume

Date: 2026-10-29. Status: decided with the owner, not yet implemented.

## Why

QuickTerm already brings back windows, workspaces, layouts and each pane's working directory after a quit. What it does not bring back is what was **in** the panes. After an upgrade, a reboot or a deliberate Cmd+Q, every terminal starts empty, and an AI agent that was mid-conversation is gone along with the context needed to pick it up again.

Other terminals have set the expectation. Terminal.app, iTerm2 and Warp show the previous output again after a relaunch; zellij and tmux-resurrect do it as an option. Upstream Ghostty has accepted the same feature (issue #1847, likely 1.5) but it is not in 1.3.1 or 1.4.0.

The goal is for a relaunch to feel like the user never left: the old output is on screen, clearly marked as old, and an agent that was running can be resumed with one key.

## Goals

- After a deliberate quit and relaunch, each terminal pane shows its previous output (last 5000 lines, with colours), a marker line, then a fresh shell that works exactly like any other pane's (shell integration included).
- A pane whose AI agent (Claude Code, Codex, kiro-cli) was running at quit offers to resume that agent's conversation with one click.
- Saved content is encrypted by default and never outlives its purpose on disk.

## Non-goals

- **Crash recovery.** A crash or force quit restores layout as today, but no content: content is exported only on a clean quit.
- **Keeping processes alive across a quit** (iTerm2's server processes, a tmux-like daemon). Processes still end at quit; what comes back is a transcript and a resumed conversation.
- **Re-running arbitrary commands.** Only the agents' own resume commands are ever offered, and only behind a keypress.
- **Restoring an agent's launch flags** (`--mcp-config`, `--add-dir`, ...). Reading another program's command line would break the README's privacy promise.
- **A history archive.** Content exists only to be shown once on the next launch; closed panes are not kept.
- **Browser panes and the scratchpad.** Browser panes keep restoring their URL only; the scratchpad is not archived today and stays that way.
- **Gemini.** Its resume needs the original project root and its free tier was replaced by another product; add it later through a rule file if wanted.

## Anti-goals (failures even if it technically works)

- An old error mistaken for a new one because nothing marks the restored text as old.
- A relaunch that runs anything without the user clicking.
- A restored pane that loses shell integration (cwd inheritance, cwd saving, Cmd+W closing an idle shell without asking), or plaintext content written to disk on the way to the screen.
- A value written by a program inside a pane that becomes a command QuickTerm executes on the next launch.
- Secrets left on disk after the user turned the feature off, or in a Time Machine backup.
- The user's clipboard touched during quit.

## Decisions

### Scope

1. Deliberate quit only. Two paths count as a quit and export content:
   - `applicationWillTerminate` (Cmd+Q, logout, reboot, an update relaunch);
   - closing the **last** screen window (`closeScreen` in `AppDelegate+Screens.swift` already saves the layout early on this path, because `windowWillClose` tears the model down before `applicationWillTerminate` runs; the export has to run at that same point).

   Closing a screen window while others stay open is not a quit: its panes count as closed (decision 7). Every terminal pane on every screen and workspace, tiled and floating, is covered.

### Content

2. **Export.** At quit, each terminal pane's primary screen is exported: the last `[restore] lines` lines (default 5000) of scrollback plus the screen, **with colours and styles** (the engine's VT format: SGR sequences, `\r\n` newlines).
3. **Engine patch 0003: two C functions.** It is applied by the existing build-script mechanism and is removed once Ghostty restores content natively.
   - **Export.** Engine 1.3.1 can format a screen as VT (`write_screen_file`, `ScreenFormatter`) but only hands the result back through the clipboard, the pty or `open_url`. The patch adds a function returning that VT text directly (shape: like `ghostty_surface_read_text`, an owned buffer the caller frees, with a line limit, primary screen only). Intercepting the clipboard was rejected: a mistake at quit would overwrite the user's clipboard.
   - **Import.** A function that feeds bytes into a surface's terminal **as program output**, through the engine's existing `Termio.processOutput` (the same path pty output takes, under the renderer lock). Nothing in 1.3.1 exposes this: `ghostty_surface_text`, `initial_input` and the `text:` binding are all *input* to the pty.
4. **Full-screen programs.** A pane on the alternate screen at quit (Claude Code, vim, htop) gets **no content restored**: the alternate screen is a picture drawn for one window size, and the shell history behind it is not reachable. Such a pane can still offer an agent resume (decision 13).
5. **Showing it.** A restored pane is created exactly like a normal one: same login shell, same command (none), so the engine's automatic shell integration still applies. Before the shell's first output, QuickTerm decrypts the saved content **in memory** and feeds it, followed by one marker line, into the surface through the import function. The marker is localized, for example `─── Restored 10-29 09:46 ───` / `─── 恢复于 10-29 09:46 ───`.

   Rejected: starting the pane with a script that prints the content and then `exec`s the shell. The engine only injects shell integration when the command's first word is `zsh`, `bash` or `fish` (`detectShell`, `src/termio/shell_integration.zig`), so every restored pane, which after the first relaunch is nearly every pane, would lose cwd inheritance, cwd saving and the no-confirm Cmd+W close. A script also cannot read the keychain, so the content would have to reach it as plaintext on disk or in a too-large argument.
6. **Read once.** The app reads, decrypts and **deletes** the content file when it creates the pane. The next quit exports again, and since the export includes what was restored, an untouched pane comes back with the same content next time (still capped at `lines`). Consequence: content exists on disk only while QuickTerm is not running, and a crash never shows stale content.
7. **Closed panes.** Closing a pane deletes its content file if one exists; the archive only ever holds files for panes open at quit.

### Storage and privacy

8. **Location.** `~/Library/Application Support/QuickTerm/restore/<pane uuid>.<ext>`, directory mode 0700, files 0600, the directory excluded from Time Machine (`NSURLIsExcludedFromBackupKey`).
9. **Encryption** (default on). AES-GCM via CryptoKit; one 256-bit key in the login keychain (generic password, service `dev.danny.quickterm.restore`), created on first use. A file that does not decrypt (key missing or reset) is deleted, not shown, and logged to the diagnostic log; the pane opens normally.
10. **Switching encryption.** The next export writes every file in the current mode and removes files in the other mode: the disk only ever holds one format.
11. **Turning content off** deletes the whole `restore/` directory immediately, not at the next quit.
12. **Config** (new `[restore]` section, `ConfigSchema` registry, both READMEs). `content` and `agent-resume` are independent: with content off, a pane can still offer an agent resume, and the other way round. Turning content off (decision 11) does not touch the agent fields in the session archive.

    ```toml
    [restore]
    content = true        # restore each terminal pane's output after a relaunch
    lines = 5000          # lines kept per pane (range to be set in the schema, e.g. 100–50000)
    encrypt = true        # encrypt saved content (key in the login keychain)
    agent-resume = true   # offer to resume an agent that was running at quit
    ```

### Agent resume

13. **When.** Only for an agent whose process was **still running** in that pane at quit. At export time QuickTerm runs one synchronous process scan (the existing `ProcessScan` walk) and offers a resume only for a pane where it finds the agent's process. A registry status alone is not enough: an entry can come from OSC text, or outlive its process for a while. An agent the user exited before quitting is not offered again.
14. **Which agents.** Claude Code, Codex and kiro-cli. The resume command lives in each agent's rule file under a new key, so adding an agent is a rule-file change:

    ```toml
    [resume]
    session = ["claude", "--resume", "{session}"]   # codex: ["codex", "resume", "{session}"]; kiro: ["kiro-cli", "chat", "--resume-id", "{session}"]
    latest  = ["claude", "--continue"]              # codex: ["codex", "resume", "--last"];    kiro: ["kiro-cli", "chat", "--resume"]
    ```

    Arrays, not strings: arguments are passed as separate words, never re-parsed by a shell.
15. **What is saved.** Per pane in the session archive: agent id, session id (when known), and nothing else. The hook payload whitelist does not change (`cwd` and `transcript_path` stay dropped); the pane's own saved working directory is the resume directory.
16. **Session ID is untrusted input.** It was reported by a program in the pane, and the resume button types a line containing it into the user's shell. It is accepted only if it matches `^[A-Za-z0-9_-]{8,128}$`; anything else is treated as "no session id". The line is built from the rule file's argument array, every argument shell-quoted, so even an ID that passed the check is one word to the shell.
17. **No session id (no hook installed).** Offer the agent's `latest` form ("the most recent session in this directory") instead, worded as such, and only when exactly one pane in that directory had this agent running. Otherwise offer nothing.
18. **Duplicate session.** If two panes reported the same session id, only the pane that reported it last offers to resume.
19. **The offer.** A button in the pane's top band (the agent status band, `PaneAgentStrip`), for example `Claude Code · Resume last session`, with a tooltip noting that launch flags such as `--mcp-config` are not restored. Clicking it sends the resume command as one line of input to the pane's shell; when the agent exits, the shell is simply there. The button goes away when clicked, when the user types into the pane, or when a new agent starts in it. The pane itself is an ordinary shell from the start, so ignoring the button costs nothing.

    The command is sent only once the shell is ready to read it (its first prompt), never typed ahead of a shell that is still starting. With the button there is no Return/any-key prompt; a script-based prompt was rejected for the same shell-integration reason as in decision 5.
20. **Checks before offering.**
    - The saved directory no longer exists: restore content, show no button, and add one localized line after the marker: `The original directory is gone; the conversation cannot be resumed here.`
    - The agent's executable is missing: the resume command fails in the shell like any typed command would (`command not found`), which is visible and harmless.
21. **kiro-cli fallbacks.** If confirming live shows the hook's `session_id` is not what `--resume-id` accepts, kiro uses the `latest` form only. If global hooks do not fire in an untrusted folder, kiro is detected by process there and also falls back to `latest`. kiro support ships either way.
22. **kiro-cli hooks.** Installed the same way as Claude Code's and Codex's: only with the user's consent, removable by `hooks uninstall`. It is a standalone file `~/.kiro/hooks/quickterm-agent-state.json` (V3 global hooks), so no existing agent config is edited. A new rule file `Resources/agents/kiro-cli.toml` maps its V3 events (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd`); presence by process (`kiro-cli-chat`, and the V3 node process whose title is `kiro`; to be confirmed). The hook must exit 0 and print nothing (a `Stop` hook exiting 1 would make kiro continue).

## Constraints

- Engine stays at Ghostty 1.3.1 (upgrade deferred until 1.4.x settles). Patch 0003 must apply with the existing idempotent mechanism in `scripts/build-ghosttykit.sh`, and the universal build must still pass.
- Quit must stay fast: export runs synchronously in `applicationWillTerminate`, so it is bounded by `lines` per pane. Measure with many panes and 5000 lines each; if it is slow, lower the default rather than making quit asynchronous.
- English-first: all new code comments, logs and commits in English; every new UI string (marker, prompts, errors) in both `en.lproj` and `zh-Hans.lproj` through `L(...)`.
- The control plane, `describe` output and CLI stay English and are unaffected.
- No test may touch the user's keychain, `~/.kiro`, `~/.claude` or real config files (`AppDelegate.isRunningTests` guards, injected paths and key stores).

## Left to the builder

- The exact C signature and Zig implementation of patch 0003, and its engine-side test.
- Archive schema change (`PersistedState` version bump to v6 with a migration from v5), where the per-pane agent fields live.
- When exactly to feed the restored content (before the shell writes anything, so it lands above the first prompt), and how "the shell is ready" is detected for the resume button (OSC 133 prompt mark when integration is on; a short fallback otherwise).
- The button's look and copy in the band.
- The `lines` range and the exact wording of every string.
- The kiro-cli presence process names, and the two facts to confirm live before shipping kiro support (with the owner's permission to install the hook file):
  1. the hook's `session_id` is what `--resume-id` accepts;
  2. global hooks in `~/.kiro/hooks` fire in a folder the user has not trusted.

## Verification

- Unit tests: session-id validation; resume command building per agent (both forms); encryption round trip with an injected key store, wrong key, and switching modes; the restore directory's permissions and backup exclusion; delete-on-read; delete-on-close (and a non-last screen closed by hand); export on last-screen close; delete-on-disable; the alternate-screen skip; the quit-time process check; duplicate session resolution; "directory gone" handling; content and agent-resume toggled independently; the `[restore]` keys' defaults.
- A restored pane keeps shell integration: after a restore, a new pane split from it inherits its cwd (when the engine's integration is enabled).
- Engine: tests for both functions of patch 0003 in the Ghostty tree (run where the Zig test build links), including a VT export fed back through import producing the same screen.
- Manual, on the owner's machine: quit with several panes (one with colours, one in vim, one running Claude Code with a hook, one running Codex without), relaunch, check each case and click each resume button; repeat by closing the last window instead of Cmd+Q; then `content = false` and confirm the directory is gone.
