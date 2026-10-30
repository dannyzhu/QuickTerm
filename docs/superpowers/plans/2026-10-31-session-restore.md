# Session Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a deliberate quit and relaunch, each terminal pane shows its previous output above a fresh shell, and a pane whose Claude Code / Codex / kiro-cli was running offers a one-click resume.

**Architecture:** Engine patch 0003 adds two C functions: export a surface's primary screen as VT text, and feed bytes into a surface as program output. At quit, `RestoreStore` exports every terminal pane, encrypts the text, and writes one file per pane; the session archive gains per-pane agent fields. On launch, a restored pane is an ordinary shell pane: before its shell writes anything, the decrypted content plus a marker line are fed into the screen, and the file is deleted. The resume offer is a button in the pane's agent band that types the agent's resume command into the shell once the shell is ready (its first output has settled).

**Tech Stack:** Swift 6 / AppKit / SwiftUI, CryptoKit (AES-GCM), Security (keychain), libghostty 1.3.1 (Zig 0.15.2) with patches, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-29-session-restore-design.md`

## Global Constraints

- Engine stays at Ghostty 1.3.1 (`vendor/ghostty`). Patch 0003 is `patches/ghostty/0003-surface-vt-export-and-import.patch`, applied by `scripts/build-ghosttykit.sh`'s existing idempotent loop. Native build for development; `GHOSTTYKIT_TARGET=universal GHOSTTYKIT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` before a release.
- Config: new `[restore]` section, keys `content = true`, `lines = 5000` (int, 100–50000), `encrypt = true`, `agent-resume = true`, declared in `ConfigSchema` with ZH/EN help, parsed in `ConfigStore`, documented in both READMEs (`testEveryKeyIsDocumented` requires a `# key = default` line in each).
- Storage: `~/Library/Application Support/QuickTerm/restore/`, directory 0700, files 0600, directory flagged `NSURLIsExcludedFromBackupKey`. Encrypted files `<pane uuid>.qtr`, plaintext `<pane uuid>.vt`. Keychain generic password, service `dev.danny.quickterm.restore`, account `content-key`, 32 random bytes.
- Session id accepted only if it matches `^[A-Za-z0-9_-]{8,128}$`.
- English-first: comments, logs, commits in English; every UI string in `Resources/en.lproj/Restore.strings` and `Resources/zh-Hans.lproj/Restore.strings` (new table; add to both `.lproj` and re-run `xcodegen generate`), read through `L(...)` / `Localization`.
- Tests never touch the real keychain, `~/.kiro`, `~/.claude`, `~/.codex` or real config: inject the key store and every path; guard app-side wiring with `AppDelegate.isRunningTests`.
- Run the full suite with `xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Debug -derivedDataPath build/dd test` (sandbox off); pass = `** TEST SUCCEEDED **` and no `.swift:N: error` lines. One xcodebuild at a time.

## Review Focus

1. **A slow shell start** (a heavy `.zshrc`, `shell-integration = none` as the owner uses, a pane restored while the Mac is busy). Expected: the restored content still appears above the first prompt, and a resume click before the shell is ready is held until it is, never typed into a half-started shell. → Task 6 tests `testAcceptBeforeReadyWaitsForIt` and `testReadyNeedsQuietOutput`; Task 5 feeds content before the shell writes anything, so the content never depends on the shell.
2. **A huge or binary-ish scrollback** (a `cat` of a minified file, lines of 100 KB, invalid UTF-8). Expected: the export is capped by line count and by bytes, quit stays fast, the import never crashes. → Task 1 engine test for the line cap; Task 3 test `testExportIsCappedAtTheByteLimit` (cap 4 MiB per pane, keep the tail).
3. **Corrupted or foreign files in `restore/`** (truncated `.qtr`, a file from another key, a stray file, a symlink). Expected: skipped, deleted, logged; never followed through a symlink; the pane opens normally. → Task 2 tests `testWrongKeyIsDeletedNotShown`, `testTruncatedFileIsDeleted`, `testSymlinkIsNeverFollowed`.
4. **The same pane uuid restored twice** (state.json restored, then the previous file was never deleted because the app crashed after reading). Expected: delete-on-read happens before the content is fed, so a crash after reading can at worst lose content, never show it twice. → Task 5 test `testFileIsDeletedBeforeContentIsFed`.
5. **A session id that is valid but belongs to another agent or a stale session.** Expected: the button only ever runs that agent's own resume command with the id as one quoted word; a failing resume is a visible shell error, nothing else. → Task 4 test `testResumeLineQuotesEveryArgument` (id `abc'; rm -rf ~` rejected; valid id produces exactly one quoted word).

---

### Task 1: Engine patch 0003 — VT export and output import

**Files:**
- Modify: `vendor/ghostty/src/apprt/embedded.zig` (two exported functions)
- Modify: `vendor/ghostty/include/ghostty.h` (two declarations)
- Create: `patches/ghostty/0003-surface-vt-export-and-import.patch` (the diff of the two files above, `git -C vendor/ghostty diff`)
- Test: Zig tests in `vendor/ghostty/src/terminal/formatter.zig` or a new test block in `embedded.zig`

**Interfaces:**
- Produces (C):
  - `bool ghostty_surface_export_vt(ghostty_surface_t, uint32_t max_lines, ghostty_text_s* result);` — VT format (`ScreenFormatter`, `emit = .vt`, `unwrap = true`, `trim = false`, current palette) of the **primary** screen's last `max_lines` rows of history plus the screen. Returns false (and writes nothing) when the active screen is the alternate screen. The caller frees `result` with the existing `ghostty_surface_free_text`.
  - `void ghostty_surface_import_output(ghostty_surface_t, const char* bytes, uintptr_t len);` — calls `Termio.processOutput` (takes the renderer lock itself).

- [ ] **Step 1: Write the engine test** — format a terminal holding red `ERR` + 3 history lines as VT with `max_lines = 2`, feed the result through `processOutput` into a fresh terminal, assert the fresh terminal's plain text equals the last 2 history lines + screen and the `E` cell's foreground is palette index 1. A second test: alternate screen active → export returns false.
- [ ] **Step 2: Run it to see it fail** — `cd vendor/ghostty && QUICKTERM_SDK=../../.tools/sdk-arm64fix-MacOSX26.5.sdk PATH=../../.tools/bin:$PATH ../../.tools/zig-0.15.2/zig build test -Dtest-filter=export_vt`. Expected: FAIL (function missing). If the test build does not link on this SDK (it did not on 2026-10-28), record that and rely on Step 6.
- [ ] **Step 3: Implement both functions** in `embedded.zig` next to `ghostty_surface_read_text`, and declare them in `ghostty.h` after `ghostty_surface_free_text`.
- [ ] **Step 4: Run the engine test** (same command). Expected: PASS, or the link failure noted in Step 2.
- [ ] **Step 5: Write the patch file** — `git -C vendor/ghostty diff -- src/apprt/embedded.zig include/ghostty.h <test file> > patches/ghostty/0003-surface-vt-export-and-import.patch`; verify `git -C vendor/ghostty apply --reverse --check ../../patches/ghostty/0003-surface-vt-export-and-import.patch`.
- [ ] **Step 6: Rebuild the engine and the app** — `GHOSTTYKIT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-ghosttykit.sh` (log shows `engine patch already applied: 0003-…`), then the Debug app build. Expected: `BUILD SUCCEEDED`; `nm` on the built library lists `_ghostty_surface_export_vt` and `_ghostty_surface_import_output`.
- [ ] **Step 7: Commit** `patches/ghostty/0003-surface-vt-export-and-import.patch` — `feat(engine): patch 0003 exports a surface's screen as VT and imports output`.

### Task 2: `RestoreStore` — encrypted, read-once files

**Files:**
- Create: `Sources/Restore/RestoreStore.swift`, `Sources/Restore/RestoreKeyStore.swift`
- Test: `Tests/RestoreStoreTests.swift`

**Interfaces:**
- Produces:
  - `protocol RestoreKeyStore { func key(createIfMissing: Bool) throws -> SymmetricKey? }`; `struct KeychainRestoreKeyStore: RestoreKeyStore` (service/account from Global Constraints); tests use an in-memory one.
  - `final class RestoreStore` — `init(directory: URL, keyStore: RestoreKeyStore)`; `static let defaultDirectory: URL`; `func write(_ text: Data, pane: UUID, encrypt: Bool) throws`; `func take(pane: UUID) -> Data?` (reads, **deletes first**, then decrypts/returns; any failure → nil + diagnostic log line `[restore] dropped <uuid8>: <reason>`); `func remove(pane: UUID)`; `func removeAll()`; `func prune(keeping: Set<UUID>)`; `func files() -> [URL]`.
- File format `.qtr`: 4-byte magic `QTR1` + AES-GCM `combined` box.

- [ ] **Step 1: Write the tests** — `testRoundTripEncrypted`, `testRoundTripPlain`, `testTakeDeletesTheFile` (second `take` returns nil), `testSwitchingModeLeavesOneFormat` (write encrypted, write plain for the same pane → only `.vt` exists), `testWrongKeyIsDeletedNotShown`, `testTruncatedFileIsDeleted`, `testSymlinkIsNeverFollowed` (a symlink named `<uuid>.qtr` pointing elsewhere: `take` returns nil and the target file is untouched), `testDirectoryIsPrivateAndExcludedFromBackup` (posix 0o700, `isExcludedFromBackup == true`), `testPruneKeepsOnlyTheGivenPanes`, `testRemoveAllDeletesTheDirectory`.
- [ ] **Step 2: Run them** — `xcodebuild … test -only-testing:QuickTermTests/RestoreStoreTests`. Expected: FAIL (types missing).
- [ ] **Step 3: Implement** both files; open files with `O_NOFOLLOW`; create the directory 0700 and set the backup exclusion on every write.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(restore): RestoreStore keeps per-pane content encrypted and read-once`.

### Task 3: `[restore]` config and quit-time export

**Files:**
- Modify: `Sources/Config/ConfigSchema.swift` (new `ConfigSection.restore` with ZH `恢复` / EN `Restore`, four keys), `Sources/Config/ConfigStore.swift` (`Settings.restoreContent`, `restoreLines`, `restoreEncrypt`, `restoreAgentResume` + parsers), `README.md`, `README.zh-CN.md` (template lines under a new `[restore]` block and a settings-table row each)
- Create: `Sources/Restore/RestoreExporter.swift`
- Modify: `Sources/App/AppDelegate.swift` (`applicationWillTerminate`, before `saveNow()`), `Sources/App/AppDelegate+Screens.swift` (`closeScreen`'s last-screen branch, before its early save), `Sources/Windowing/AppSession.swift` (on `content == false`, `RestoreStore.removeAll()` immediately)
- Modify: `Sources/GhosttyEmbed/Surface View/SurfaceView_AppKit.swift` (`func exportVT(maxLines: Int) -> Data?` wrapping Task 1's C call)
- Test: `Tests/RestoreExporterTests.swift`, additions in `Tests/ConfigStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's `ghostty_surface_export_vt`; Task 2's `RestoreStore`.
- Spec decision 7 (closed panes) is met by delete-on-read (Task 2) plus `prune(keeping:)` here: while the app runs no file exists for an open pane, and at quit every file not exported now is removed.
- Produces: `enum RestoreExporter { static let maxBytes = 4 * 1024 * 1024; static func export(panes: [Ghostty.SurfaceView], settings: ConfigStore.Settings, store: RestoreStore, read: (Ghostty.SurfaceView, Int) -> Data?) }` — writes one file per pane that returned content (keeping the **tail** when over `maxBytes`), then `store.prune(keeping:)` the exported ids; with `content == false` it only calls `store.removeAll()`.

- [ ] **Step 1: Write the tests** — `testRestoreKeysDefaults` (`ConfigStore.parse("")` → true / 5000 / true / true; `lines = 10` clamps to 100), `testExportWritesOneFilePerPane`, `testAlternateScreenPaneGetsNoFile` (read closure returns nil), `testExportIsCappedAtTheByteLimit` (5 MiB in → ≤ `maxBytes` out, ending with the input's last line), `testExportPrunesClosedPanes`, `testContentOffRemovesEverything`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the config keys, `RestoreExporter`, `exportVT`, and the two call sites (both must run before the archive save on that path; skip entirely when `AppDelegate.isRunningTests`).
- [ ] **Step 4: Run the tests and the full suite.** Expected: PASS, including `testEveryKeyIsDocumented` and `LocalizationTests`.
- [ ] **Step 5: Commit** — `feat(restore): export every terminal pane's screen at quit ([restore] config)`.

### Task 4: Agent resume data — rule files, validation, quit-time capture, archive

**Files:**
- Modify: `Sources/Agents/AgentRules.swift` (new optional `[resume]` table: `session: [String]?` containing exactly one `{session}`, `latest: [String]?`; reject unknown keys)
- Modify: `Resources/agents/claude-code.toml`, `Resources/agents/codex.toml` (the `[resume]` arrays from spec decision 14)
- Create: `Sources/Restore/AgentResume.swift`
- Modify: `Sources/Windowing/SessionState.swift` (`PersistedState` v5 → v6; per-pane `agentResume: AgentResumeRecord?` stored next to the pane in the layout archive; decoding v5 = no records), `Sources/GhosttyEmbed/Surface View/SurfaceView_AppKit.swift` (encode/decode the optional record)
- Modify: `Sources/App/AppDelegate.swift` (at quit, before the save: one synchronous `ProcessScan.run()` and fill each pane's record)
- Test: `Tests/AgentResumeTests.swift`, additions in `Tests/AgentRulesTests.swift`, `Tests/SessionStateTests.swift`

**Interfaces:**
- Produces:
  - `struct AgentResumeRecord: Codable, Equatable { var agent: String; var session: String? }`
  - `enum AgentResume { static func isValidSessionID(_: String) -> Bool; static func command(rules: AgentRules, session: String?) -> [String]?; static func shellLine(_ argv: [String]) -> String; static func records(statuses: [UUID: AgentStatus], running: [UUID: AgentPresence], directories: [UUID: String]) -> [UUID: AgentResumeRecord] }`
  - `records` keeps a pane only when the scan found that agent's process in it (spec 13); drops a session id that fails validation (spec 16); when two panes share a session id keeps it only on the one whose status has the latest `since` (spec 18); with no session id keeps the pane only if no other pane with the same directory has the same agent running (spec 17).

- [ ] **Step 1: Write the tests** — `testSessionIDValidation` (accepts `a1b2c3d4`, `sess_0f9e…`, rejects `short`, a 129-char id, `abc'; rm -rf ~`, `a b c d e f g h`); `testResumeLineQuotesEveryArgument` (`["claude","--resume","a1b2c3d4"]` → `'claude' '--resume' 'a1b2c3d4'`); `testCommandUsesLatestWithoutSession`; `testOnlyARunningAgentIsKept`; `testDuplicateSessionKeepsTheLatestPane`; `testLatestNeedsASinglePaneInTheDirectory`; `testRuleFileResumeTableParses` and `testResumeSessionFormNeedsThePlaceholder`; `testArchiveV5DecodesWithoutRecords`, `testArchiveRoundTripsRecords`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the rule table, the two rule files, `AgentResume`, the v6 archive with migration, and the quit-time capture (gated by `restoreAgentResume`).
- [ ] **Step 4: Run the tests and the full suite.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(restore): remember which agent to resume in each pane`.

### Task 5: Launch-time content import and the marker line

**Files:**
- Create: `Resources/en.lproj/Restore.strings`, `Resources/zh-Hans.lproj/Restore.strings` (keys `restore.marker` = `─── Restored %1$@ ───` / `─── 恢复于 %1$@ ───`, `restore.directory-gone`, `restore.resume.button`, `restore.resume.latest`, `restore.resume.help`); re-run `xcodegen generate`
- Create: `Sources/Restore/RestoreImporter.swift`
- Modify: `Sources/GhosttyEmbed/Surface View/SurfaceView_AppKit.swift` (decode path: hold the pane uuid's content; feed it right after `ghostty_surface_new`, before the first draw)
- Test: `Tests/RestoreImporterTests.swift`

**Interfaces:**
- Consumes: Task 1's `ghostty_surface_import_output`; Task 2's `RestoreStore.take`; Task 4's `AgentResumeRecord`.
- Produces: `enum RestoreImporter { static func payload(content: Data?, restoredAt: Date, directoryGone: Bool) -> Data? }` — content, then `\r\n` + the dim marker line (`ESC[2m … ESC[0m`) + `\r\n`, then the directory-gone line when set; nil when there is neither content nor a line to show. `static func feed(_ payload: Data, into surface: ghostty_surface_t)`.

- [ ] **Step 1: Write the tests** — `testRestoredPaneHasNoCommand` (the decoded surface's `SurfaceConfiguration.command` is nil, so the engine still injects shell integration), `testPayloadEndsWithTheMarker`, `testNoContentNoLineNoPayload`, `testDirectoryGoneLineFollowsTheMarker`, `testFileIsDeletedBeforeContentIsFed` (inject a `feed` that checks the store has no file for the pane at call time), and a surface test `testImportedContentIsOnScreen` (create a test surface, feed `hello\r\n` + marker, `controlReadText` contains both).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the importer and the surface hook; only restored panes (decoded from the archive) take content, never a new pane.
- [ ] **Step 4: Run the tests and the full suite.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(restore): a relaunched pane shows its previous output above a fresh shell`.

### Task 6: The resume button in the agent band

**Files:**
- Modify: `Sources/Panes/PaneView.swift` (`private(set) var pendingResume: AgentResumeRecord?` with a setter that sends `objectWillChange`)
- Modify: `Sources/Splits/PaneAgentStrip.swift` (when `pendingResume != nil` and no live agent status: draw a button `restore.resume.button` (`%1$@ · Resume last session`) or `restore.resume.latest`, tooltip `restore.resume.help`)
- Create: `Sources/Restore/ResumeOffer.swift`
- Modify: `Sources/GhosttyEmbed/Surface View/SurfaceView_AppKit.swift` (clear the offer on the first `keyDown`). Engine 1.3.1 has no prompt-start action (only `GHOSTTY_ACTION_COMMAND_FINISHED`) and no per-surface output callback, so "ready" is decided by polling the viewport text (`controlReadText(tag: GHOSTTY_POINT_VIEWPORT)`, every 0.1 s, only between a click and the send).
- Test: `Tests/ResumeOfferTests.swift`

**Interfaces:**
- Consumes: Task 4's `AgentResume.command` / `shellLine`, `AgentResumeRecord`; `Ghostty.Surface.sendText`.
- Produces: `final class ResumeOffer` — `init(record: AgentResumeRecord, rules: AgentRules, send: @escaping (String) -> Void, scheduler: …)`; `snapshot: @escaping () -> String` (the viewport text); `var isReady: Bool` (true once the viewport has changed from what it was when the pane was restored and then stayed unchanged for `quietPeriod = 0.3` s); `func accept()` (sends `shellLine(argv) + "\r"` at once when ready, otherwise as soon as it becomes ready, and in any case after `maxWait = 5` s; at most once); `func dismiss()`. The offer is dismissed on a keystroke, on a new agent status in the pane, or on accept.

- [ ] **Step 1: Write the tests** (injected scheduler, no real waiting) — `testAcceptWhenReadySendsOnce` (second accept sends nothing), `testAcceptBeforeReadyWaitsForIt`, `testReadyNeedsQuietOutput` (snapshot changes at t=0, 0.2, 0.4 → not ready until 0.7), `testAcceptSendsAfterMaxWaitWithNoOutput`, `testTypingDismissesTheOffer`, `testANewAgentDismissesTheOffer`, `testBandShowsTheButtonOnlyWithoutALiveAgent` (`PaneAgentStrip.Model` level), `testNoOfferWhenTheDirectoryIsGone`, `testOfferWithContentOff` (agent-resume on, content off: the button still appears).
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** `ResumeOffer`, the band button and the surface hooks; restored panes get their offer from the archive record at decode time when `restoreAgentResume` is on.
- [ ] **Step 4: Run the tests and the full suite.** Expected: PASS.
- [ ] **Step 5: Commit** — `feat(restore): a restored pane offers to resume its agent from the status band`.

### Task 7: kiro-cli rule file and hook installer shape

**Files:**
- Create: `Resources/agents/kiro-cli.toml` (`process = ["kiro-cli-chat"]`, process-path for the V3 node process to be confirmed; `[fields] session = "$.session_id"`; `[hooks]` for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd`; `[install] shape = "kiro"`, `config = "~/.kiro/hooks/quickterm-agent-state.json"`; `[resume]` per spec 14)
- Modify: `Sources/Agents/AgentRules.swift` (`Shape.kiro`), `Sources/Agents/HookConfigShape.swift`, `Sources/Agents/HookInstaller.swift` (the kiro shape writes and deletes a **whole standalone file** `{"version":"v1","hooks":[{name, trigger, action:{type:"command",command}, timeout}]}`, never edits another file; uninstall deletes the file only if it carries our marker)
- Test: additions in `Tests/HookInstallerTests.swift`, `Tests/AgentRulesTests.swift`

**Interfaces:**
- Consumes: `HookScript.command(scriptPath:agent:)`, `HookScript.isOurs`.

- [ ] **Step 1: Write the tests** (temp `configDir`) — `testKiroInstallWritesAStandaloneFile` (JSON shape, one entry per event, timeout 5), `testKiroUninstallDeletesOnlyOurFile` (a user file in the same directory survives; a file without our marker is refused), `testKiroRuleFileLoads`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement** the shape and the rule file.
- [ ] **Step 4: Run the tests and the full suite.** Expected: PASS.
- [ ] **Step 5: Live check (needs the owner's permission first — it installs the hook into the real `~/.kiro`):** install via `quickterm hooks install kiro-cli`, run one kiro chat in a QuickTerm pane and in an untrusted folder, read the diagnostic log's `[hook]` lines for `session_id` and confirm `kiro-cli chat --resume-id <that id>` resumes it; confirm the presence process names. Apply spec decision 21's fallbacks to the rule file if either check fails.
- [ ] **Step 6: Commit** — `feat(agents): kiro-cli rule file, hooks as a standalone file, and resume`.

### Task 8: End-to-end check and release notes

**Files:**
- Create: `docs/releases/v1.6.18.md`, `docs/releases/v1.6.18.zh-CN.md` (when the owner asks to release)

- [ ] **Step 1: Full suite** (command in Global Constraints). Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 2: Hand the Debug build to the owner** with the manual checklist from the spec's Verification section (colours, vim pane, Claude Code with hook, Codex without, close-last-window path, `content = false` removes the directory).
- [ ] **Step 3: Commit** any fixes the manual check finds, each with its own test.
