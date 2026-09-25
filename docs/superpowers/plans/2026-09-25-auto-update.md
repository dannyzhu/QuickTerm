# Auto-update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** QuickTerm checks GitHub Releases for a newer version, shows it in the status bar, offers the notes and an install button in a house-style sheet, and can download and install on quit unattended.

**Architecture:** Sparkle 2.10 does the checking, verification, download and install; a custom `SPUUserDriver` ported from Ghostty mirrors every Sparkle callback into one `@Published UpdateState`; the status bar and an `NSAlert` sheet render that state; two `[updates]` config keys drive Sparkle's two automatic flags; the release script signs the DMG with EdDSA and publishes an `appcast.xml` next to it.

**Tech Stack:** Swift 5.10, AppKit + SwiftUI, Sparkle 2.10.0 via SwiftPM (xcodegen `packages:`), XCTest, bash + python3 for the release pipeline.

**Spec:** `docs/superpowers/specs/2026-09-25-auto-update-design.md` — read it first; every task below cites its sections.

## Global Constraints

- Code comments, OSLog messages and commit messages in English; commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Every user-facing string goes through the catalogs, both languages in the same commit; keys `area.subject.detail`, positional `%1$@` only, `%%` for a percent sign, every declared key must have an `L(` / `i18n(` call site (the build-phase lint `scripts/check-localization.py` rejects unused keys). A new `.strings` table goes into **both** `Resources/en.lproj` and `Resources/zh-Hans.lproj`, then `xcodegen generate`.
- Config keys: declared once in `ConfigSchema.keys` with hard-coded ZH/EN label + help pairs (the file is also compiled into the CLI target: Foundation only), a `Settings` field with the same default, a `ConfigBindings.table` entry, and the `# key = default` line plus the `[section]` header in `README.md` **and** `README.zh-CN.md` (line-parallel).
- `QuickTerm.xcodeproj/` is generated and git-ignored: run `xcodegen generate` after adding files or changing `project.yml`.
- Tests: `xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/<Class>`; **run xcodebuild outside the sandbox** (in this harness pass `dangerouslyDisableSandbox: true`; a sandboxed run hangs ~26 minutes on `NSHostingView`). One xcodebuild at a time.
- Never touch the user's running QuickTerm, `~/.config/quickterm`, `~/.claude`, `~/.codex`, `~/.gemini`, or `/usr/local/bin`. The test host (`AppDelegate.isRunningTests`) never creates an `SPUUpdater` and never reaches the network.
- Sparkle pin: `exactVersion: 2.10.0`; `SPARKLE_SHA256=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959` (the checksum in Sparkle 2.10.0's `Package.swift`). Deployment target stays 15.4.
- Feed URL: `https://github.com/dannyzhu/QuickTerm/releases/latest/download/appcast.xml`. Info.plist: `SUEnableAutomaticChecks = true`, `SUVerifyUpdateBeforeExtraction = true`; `SUPublicEDKey` only once the user has run `generate_keys` (Task 11).
- Defaults: `check = true`, `install = false`; `install` implies checking.
- The updater exists only when: not the test host, `SUPublicEDKey` present and non-empty, and (Release build, or Debug build with `--update-feed-url` / `QUICKTERM_UPDATE_FEED_URL` set).

## Review Focus

1. **Later on an available update in check-only mode must not reply to Sparkle** — the icon has to stay; Task 8's `testLaterInCheckOnlyModeHoldsTheReply` pins it. In `install = true` mode Later replies `.dismiss` (`testLaterInInstallModeDismisses`).
2. **A staged update resurfacing as `showUpdateFound(stage: .installing)` must render as "restart to finish", not "78 MB available"** — Task 4's `testAStagedUpdateMapsToInstalling`.
3. **Every Sparkle acknowledgement / reply fires exactly once** even when the bar is hidden — errors and not-found are acknowledged in the driver immediately (Task 4 `testNotFoundAndErrorAcknowledgeSparkleImmediately`), so no session is held by a view.
4. **Quitting to install must skip the "N panes open" confirmation from every entry point** (Install and Relaunch, Restart Now, Sparkle's own terminate) — Task 4 `testRelaunchRequestedFollowsTheInstallPaths` and Task 9 `testShouldConfirmQuitStandsAsideForARelaunch`.
5. **A forgotten `CURRENT_PROJECT_VERSION` bump must fail the release, not ship an invisible update** — Task 10's `update-appcast.py --self-test` covers "build not greater than the feed".

## File structure

New area `Sources/Update/`:

| File | Responsibility |
|---|---|
| `UpdateSettings.swift` | The two switches as a value type; `checksEnabled = check \|\| install`. |
| `UpdateViewModel.swift` | `UpdateViewModel` (`@Published state`) and `UpdateState` with Sparkle's reply blocks and raw values. No text. |
| `UpdateController.swift` | Owns `SPUUpdater?`, start / check / install chain, `relaunchRequested`, the not-found timer, the enabled gate. |
| `UpdateDriver.swift` | `SPUUserDriver` + `SPUUpdaterDelegate` → view model; stage-aware `showUpdateFound`; `showUpdateInFocus`; feed override; relaunch policy. |
| `UpdateSimulator.swift` | Scripted state sequences for the UI without a server (Debug/tests). |
| `ReleaseNotes.swift` | Asset URLs per language, Markdown → plain text, async loader with cache. |
| `UpdateIndicator.swift` | The status-bar item (SwiftUI) and its pure glyph mapping. |
| `UpdateSheet.swift` | The `NSAlert` per state, button semantics, dismissal on state change. |

Modified: `Sources/Config/ConfigSchema.swift`, `Sources/Config/ConfigStore.swift`, `project.yml`, `Sources/App/AppDelegate.swift`, `Sources/App/AppDelegate+Ghostty.swift`, `Sources/App/AppDelegate+Screens.swift`, `Sources/App/MainMenu.swift`, `Sources/App/InfoAlert.swift`, `Sources/Windowing/AppSession.swift`, `Sources/Windowing/MainWindowController.swift`, `Sources/Windowing/RootView.swift`, `Sources/StatusBar/StatusBarView.swift`, `Sources/StatusBar/WorkspacePill.swift`, `Resources/*/Menus.strings`, `README.md`, `README.zh-CN.md`, `scripts/make-release.sh`, `docs/porting-notes.md`. New: `Resources/*/Update.strings`, `scripts/update-appcast.py`, tests under `Tests/`.

---

### Task 1: `[updates]` config section and `UpdateSettings`

Spec §5.

**Files:**
- Modify: `Sources/Config/ConfigSchema.swift` (enum `ConfigSection` at line 19, `titleZH`/`titleEN`, `noteZH`/`noteEN`, the `keys` registry after the `notifications.diagnostic-log` entry ~line 861)
- Modify: `Sources/Config/ConfigStore.swift` (`Settings` after `notificationsDiagnosticLog` ~line 326; `ConfigBindings.table` after `agents.strip-text` ~line 429)
- Modify: `README.md` (config block, insert after the `[notifications]` block, before `[keybinds]` ~line 475), `README.zh-CN.md` (same place ~line 463)
- Create: `Sources/Update/UpdateSettings.swift`
- Test: `Tests/UpdateSettingsTests.swift`

**Interfaces:**
- Produces: `struct UpdateSettings: Equatable { var check: Bool; var install: Bool; var checksEnabled: Bool; init(check: Bool = true, install: Bool = false); init(_ settings: ConfigStore.Settings) }`, `ConfigStore.Settings.updatesCheck: Bool`, `.updatesInstall: Bool`, `ConfigSection.updates`.

- [ ] **Step 1: Write the failing test**

`Tests/UpdateSettingsTests.swift`:

```swift
import XCTest
@testable import QuickTerm

/// The two `[updates]` switches, from the file to the value type the updater consumes.
final class UpdateSettingsTests: XCTestCase {
    func testDefaultsAreCheckOnInstallOff() {
        let settings = UpdateSettings(ConfigStore.Settings())
        XCTAssertTrue(settings.check)
        XCTAssertFalse(settings.install)
        XCTAssertTrue(settings.checksEnabled)
    }

    func testInstallImpliesChecks() {
        let parsed = ConfigStore.parse("[updates]\ncheck = false\ninstall = true\n")
        let settings = UpdateSettings(parsed)
        XCTAssertFalse(settings.check)
        XCTAssertTrue(settings.install)
        XCTAssertTrue(settings.checksEnabled, "installing has to check first")
    }

    func testBothOffMeansNoChecks() {
        let parsed = ConfigStore.parse("[updates]\ncheck = false\ninstall = false\n")
        XCTAssertFalse(UpdateSettings(parsed).checksEnabled)
    }

    func testGarbageKeepsTheDefault() {
        let parsed = ConfigStore.parse("[updates]\ncheck = maybe\n")
        XCTAssertTrue(parsed.updatesCheck, "an unparsable bool keeps the registry default")
    }

    func testTheSectionIsInTheTemplate() {
        let template = ConfigStore.template
        XCTAssertTrue(template.contains("[updates]"))
        XCTAssertTrue(template.contains("# check = true"))
        XCTAssertTrue(template.contains("# install = false"))
        XCTAssertEqual(ConfigSection.allCases.firstIndex(of: .updates),
                       ConfigSection.allCases.firstIndex(of: .notifications).map { $0 + 1 },
                       "[updates] sits right after [notifications], before [keybinds]")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateSettingsTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile error `cannot find 'UpdateSettings' in scope`.

- [ ] **Step 3: Add the section to `ConfigSchema.swift`**

In `enum ConfigSection`, after `case notifications` add `case updates`. In `titleZH` add `case .updates: "更新"`; in `titleEN` add `case .updates: "Updates"`. In `noteZH`, before `case .keybinds:` add:

```swift
        case .updates:
            """
            自动更新：从 GitHub Releases 取。只检查时，状态栏右侧簇会亮一个图标，点开看说明再决定装不装。
            """
```

In `noteEN`, before `case .keybinds:` add:

```swift
        case .updates:
            """
            Auto-update from GitHub Releases. With check only, an icon in the status bar's right
            cluster says a release is out; click it for the notes and the install button.
            """
```

In the `keys` array, after the `notifications.diagnostic-log` spec (before the closing `]`) add:

```swift

        // MARK: [updates]
        // Consumed as `UpdateSettings` by `UpdateController.apply(_:)` from
        // `AppSession.applyGlobalConfig`; the controller never reads the config itself.
        ConfigKeySpec(.updates, "check", .bool, default: .bool(true),
                      labelZH: "自动检查更新", labelEN: "Check for updates",
                      helpZH: "启动时以及之后约每天一次，到 GitHub Releases 查是否有新版本；install = true 时即使关掉这一项也会检查",
                      helpEN: "at launch and about once a day, ask GitHub Releases whether a newer QuickTerm exists; install = true checks even when this is off"),
        ConfigKeySpec(.updates, "install", .bool, default: .bool(false),
                      labelZH: "自动下载安装", labelEN: "Install automatically",
                      helpZH: "发现新版本后在后台下载，退出 QuickTerm 时自动安装（隐含 check）；状态栏图标会提示「退出或重启以完成更新」",
                      helpEN: "download a found update in the background and install it when QuickTerm quits (implies check); the status bar icon then says to quit or restart to finish"),
```

- [ ] **Step 4: Add the fields and bindings to `ConfigStore.swift`**

In `struct Settings`, after `var notificationsDiagnosticLog: Bool = false` add:

```swift
        /// `[updates]` — the updater's two switches; `UpdateSettings` is built from them in
        /// `AppSession.applyGlobalConfig`.
        var updatesCheck: Bool = true
        var updatesInstall: Bool = false
```

In `ConfigBindings.table`, after the `"agents.strip-text"` line add:

```swift
        "updates.check": { v, s in v.boolValue.map { s.updatesCheck = $0 } },
        "updates.install": { v, s in v.boolValue.map { s.updatesInstall = $0 } },
```

- [ ] **Step 5: Create `Sources/Update/UpdateSettings.swift`**

```swift
import Foundation

/// The two `[updates]` switches as the updater consumes them. Built from `ConfigStore.Settings`
/// in `AppSession.applyGlobalConfig` and handed to `UpdateController.apply(_:)`; the controller
/// never reads the config file itself.
struct UpdateSettings: Equatable {
    /// `[updates] check`: look for a newer release at launch and about once a day.
    var check: Bool = true
    /// `[updates] install`: download a found update unattended and install it on quit.
    var install: Bool = false

    init(check: Bool = true, install: Bool = false) {
        self.check = check
        self.install = install
    }

    init(_ settings: ConfigStore.Settings) {
        self.init(check: settings.updatesCheck, install: settings.updatesInstall)
    }

    /// Sparkle's `automaticallyChecksForUpdates`: installing implies checking.
    var checksEnabled: Bool { check || install }
}
```

- [ ] **Step 6: Document the keys in both READMEs**

`README.md`: after the `[notifications]` block's last line (`# diagnostic-log = false …`) and its blank line, before `[keybinds]`, insert:

```
[updates]                   # auto-update from GitHub Releases; with check only, an icon in the status bar says a release is out
# check = true               # at launch and about once a day, ask GitHub Releases whether a newer QuickTerm exists; install = true checks even when this is off
# install = false            # download a found update in the background and install it when QuickTerm quits (implies check); the status bar icon then says to quit or restart to finish

```

`README.zh-CN.md`, same place:

```
[updates]                   # 自动更新：从 GitHub Releases 取；只检查时状态栏右侧会亮一个图标
# check = true               # 启动时以及之后约每天一次，到 GitHub Releases 查是否有新版本；install = true 时即使关掉这一项也会检查
# install = false            # 发现新版本后在后台下载，退出 QuickTerm 时自动安装（隐含 check）；状态栏图标会提示「退出或重启以完成更新」

```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateSettingsTests -only-testing:QuickTermTests/ConfigSchemaTests -only-testing:QuickTermTests/ConfigStoreTests -only-testing:QuickTermTests/ConfigHotReloadTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, 0 failures (`testEveryKeyIsDocumented`, `testEveryKeyHasABinding`, `testTemplateRoundTrips` and the hot-reload sweep all cover the new keys automatically).

- [ ] **Step 8: Commit**

```bash
git add Sources/Config/ConfigSchema.swift Sources/Config/ConfigStore.swift Sources/Update/UpdateSettings.swift Tests/UpdateSettingsTests.swift README.md README.zh-CN.md
git commit -m "feat(config): the [updates] section with check and install switches

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Sparkle package and Info.plist keys

Spec §5 (Info.plist), §7 (dependency pinning).

**Files:**
- Modify: `project.yml`

**Interfaces:**
- Produces: `import Sparkle` compiles in the `QuickTerm` and `QuickTermTests` targets; `Bundle.main` carries `SUFeedURL`, `SUEnableAutomaticChecks`, `SUVerifyUpdateBeforeExtraction`.

- [ ] **Step 1: Declare the package and link it**

In `project.yml`, after the top-level `settings:` block (before `targets:`) add:

```yaml
# Sparkle is the updater (docs/superpowers/specs/2026-09-25-auto-update-design.md). An exact
# version: QuickTerm.xcodeproj (and SwiftPM's Package.resolved inside it) is git-ignored, so the
# pin here is the only pin. scripts/make-release.sh carries the same version for the CLI tools.
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.10.0
```

In the `QuickTerm` target's `dependencies:` list, after the `- sdk: UniformTypeIdentifiers.framework` line add:

```yaml
      - package: Sparkle
```

In the `QuickTermTests` target's `dependencies:` list, after `- target: QuickTerm` add:

```yaml
      # @testable import QuickTerm exposes Sparkle types (UpdateState carries SUAppcastItem).
      - package: Sparkle
        embed: false
```

- [ ] **Step 2: Add the Sparkle keys to the app's Info.plist properties**

In the `QuickTerm` target's `info.properties`, after the `NSAppTransportSecurity` entry add:

```yaml
        # Sparkle (auto-update). The feed is the appcast attached to the latest GitHub release;
        # SUPublicEDKey is added once the EdDSA key pair exists (the updater stays off until then).
        SUFeedURL: "https://github.com/dannyzhu/QuickTerm/releases/latest/download/appcast.xml"
        SUEnableAutomaticChecks: true
        SUVerifyUpdateBeforeExtraction: true
```

- [ ] **Step 3: Generate and build**

Run: `xcodegen generate && xcodebuild build -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -derivedDataPath build/plan-check 2>&1 | grep -E "error:|Multiple commands|BUILD"`
Expected: `** BUILD SUCCEEDED **`. If the log says `Multiple commands produce …/Sparkle.framework`, change the app target's entry to `- package: Sparkle` + `embed: false` and rebuild.

- [ ] **Step 4: Verify exactly one framework copy and the plist keys**

Run: `find build/plan-check/Build/Products/Debug/QuickTerm.app/Contents/Frameworks -maxdepth 1 -name 'Sparkle.framework' | wc -l; /usr/libexec/PlistBuddy -c 'Print SUFeedURL' -c 'Print SUEnableAutomaticChecks' build/plan-check/Build/Products/Debug/QuickTerm.app/Contents/Info.plist`
Expected: `1`, the feed URL, `true`.

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "build: add Sparkle 2.10.0 and the updater's Info.plist keys

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `UpdateViewModel` and `UpdateState`

Spec §2 (view model row), §4 (states). Ported from `vendor/ghostty/macos/Sources/Features/Update/UpdateViewModel.swift` (MIT) with the presentation stripped out and Sparkle's stage carried in.

**Files:**
- Create: `Sources/Update/UpdateViewModel.swift`
- Test: `Tests/UpdateStateTests.swift`

**Interfaces:**
- Produces (used by every later task):
  - `final class UpdateViewModel: ObservableObject { @Published var state: UpdateState }`
  - `enum UpdateState: Equatable { idle, checking(Checking), updateAvailable(UpdateAvailable), downloading(Downloading), extracting(Extracting), installing(Installing), notFound(NotFound), error(Failure) }` with `isIdle`, `isInstallable`, `cancel()`, `confirm()`.
  - `UpdateState.Checking(cancel:)`; `UpdateAvailable(appcastItem: SUAppcastItem, stage: .notDownloaded|.downloaded, userInitiated: Bool, reply:)` with `version`, `contentLength`, `date`; `Downloading(cancel:version:expectedLength:progress:)` with `fraction: Double?`; `Extracting(version:progress:)`; `Installing(isAutoUpdate:version:restart:later:skip:)`; `NotFound()`; `Failure(error:kind:retry:dismiss:)` with `Failure.kind(domain:code:) -> Kind` (`.translocated` for `SUSparkleErrorDomain` codes 1003 / 1005).

- [ ] **Step 1: Write the failing test**

`Tests/UpdateStateTests.swift`:

```swift
import Sparkle
import XCTest
@testable import QuickTerm

/// The state enum's own rules: which states the install chain may push through, what cancel and
/// confirm reply, and the two error kinds.
final class UpdateStateTests: XCTestCase {
    private func available(stage: UpdateState.UpdateAvailable.Stage = .notDownloaded,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void = { _ in }) -> UpdateState {
        .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: stage,
                               userInitiated: false, reply: reply))
    }

    func testInstallableStates() {
        XCTAssertFalse(UpdateState.idle.isInstallable)
        XCTAssertTrue(UpdateState.checking(.init(cancel: {})).isInstallable)
        XCTAssertTrue(available().isInstallable)
        XCTAssertTrue(UpdateState.downloading(.init(cancel: {}, version: nil, expectedLength: nil, progress: 0)).isInstallable)
        XCTAssertTrue(UpdateState.extracting(.init(version: nil, progress: 0)).isInstallable)
        XCTAssertTrue(UpdateState.installing(.init(isAutoUpdate: true, version: "9.9.9", restart: {}, later: {}, skip: nil)).isInstallable)
        XCTAssertFalse(UpdateState.notFound(.init()).isInstallable)
    }

    func testConfirmInstallsOnlyAnAvailableUpdate() {
        var choice: SPUUserUpdateChoice?
        available { choice = $0 }.confirm()
        XCTAssertEqual(choice, .install)
        var restarted = false
        UpdateState.installing(.init(isAutoUpdate: true, version: nil, restart: { restarted = true }, later: {}, skip: nil)).confirm()
        XCTAssertFalse(restarted, "confirm never restarts on its own; Restart Now is a click")
    }

    func testCancelRepliesDismissOrCancels() {
        var choice: SPUUserUpdateChoice?
        available { choice = $0 }.cancel()
        XCTAssertEqual(choice, .dismiss)
        var cancelled = false
        UpdateState.downloading(.init(cancel: { cancelled = true }, version: nil, expectedLength: nil, progress: 0)).cancel()
        XCTAssertTrue(cancelled)
        var dismissed = false
        UpdateState.error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: { dismissed = true })).cancel()
        XCTAssertTrue(dismissed)
    }

    func testDownloadFraction() {
        XCTAssertNil(UpdateState.Downloading(cancel: {}, version: nil, expectedLength: nil, progress: 10).fraction)
        XCTAssertEqual(UpdateState.Downloading(cancel: {}, version: nil, expectedLength: 200, progress: 50).fraction!, 0.25, accuracy: 0.001)
        XCTAssertEqual(UpdateState.Downloading(cancel: {}, version: nil, expectedLength: 200, progress: 500).fraction!, 1, "never over 100 %")
    }

    func testFailureKind() {
        XCTAssertEqual(UpdateState.Failure.kind(domain: "SUSparkleErrorDomain", code: 1005), .translocated)
        XCTAssertEqual(UpdateState.Failure.kind(domain: "SUSparkleErrorDomain", code: 1003), .translocated)
        XCTAssertEqual(UpdateState.Failure.kind(domain: "SUSparkleErrorDomain", code: 2000), .other)
        XCTAssertEqual(UpdateState.Failure.kind(domain: "NSURLErrorDomain", code: 1005), .other)
    }

    func testEqualityIgnoresClosures() {
        XCTAssertEqual(available(), available())
        XCTAssertNotEqual(available(stage: .downloaded), available(stage: .notDownloaded))
        XCTAssertEqual(UpdateState.extracting(.init(version: nil, progress: 0.5)), .extracting(.init(version: "1", progress: 0.5)))
        XCTAssertNotEqual(UpdateState.idle, UpdateState.notFound(.init()))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateStateTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile errors (`UpdateState` not found).

- [ ] **Step 3: Create `Sources/Update/UpdateViewModel.swift`**

```swift
import Combine
import Foundation
import Sparkle

// Ported from Ghostty (macos/Sources/Features/Update/UpdateViewModel.swift, MIT) and adapted:
// the model carries Sparkle's reply blocks and raw values only. Text, icons and colours live in
// the views, which read the catalogs at render time so a language change re-labels them.

/// What the updater is doing right now: one `@Published` value that every screen's status bar and
/// the update sheet observe.
final class UpdateViewModel: ObservableObject {
    @Published var state: UpdateState = .idle
}

enum UpdateState: Equatable {
    case idle
    case checking(Checking)
    case updateAvailable(UpdateAvailable)
    case downloading(Downloading)
    case extracting(Extracting)
    case installing(Installing)
    case notFound(NotFound)
    case error(Failure)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// The states the "say yes to everything" install chain may push through.
    var isInstallable: Bool {
        switch self {
        case .checking, .updateAvailable, .downloading, .extracting, .installing: return true
        default: return false
        }
    }

    /// Closes the current Sparkle question without installing anything.
    func cancel() {
        switch self {
        case .checking(let checking): checking.cancel()
        case .updateAvailable(let available): available.reply(.dismiss)
        case .downloading(let downloading): downloading.cancel()
        case .installing(let installing): installing.later()
        case .error(let failure): failure.dismiss()
        case .idle, .extracting, .notFound: break
        }
    }

    /// Says yes to the question an available update asks; every other state has nothing to
    /// confirm (a restart is always an explicit click, see `UpdateController.requestRelaunch`).
    func confirm() {
        if case .updateAvailable(let available) = self { available.reply(.install) }
    }

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.notFound, .notFound):
            return true
        case (.updateAvailable(let l), .updateAvailable(let r)):
            return l.version == r.version && l.stage == r.stage
        case (.downloading(let l), .downloading(let r)):
            return l.progress == r.progress && l.expectedLength == r.expectedLength
        case (.extracting(let l), .extracting(let r)):
            return l.progress == r.progress
        case (.installing(let l), .installing(let r)):
            return l.isAutoUpdate == r.isAutoUpdate && l.version == r.version
        case (.error(let l), .error(let r)):
            return l.kind == r.kind && l.error.localizedDescription == r.error.localizedDescription
        default:
            return false
        }
    }

    struct Checking {
        let cancel: () -> Void
    }

    struct UpdateAvailable {
        /// Sparkle's `SPUUserUpdateState.stage` minus `.installing`, which is `UpdateState.installing`.
        enum Stage: Equatable { case notDownloaded, downloaded }
        let appcastItem: SUAppcastItem
        let stage: Stage
        /// A manual "Check for Updates…" found it: the sheet opens without a click.
        let userInitiated: Bool
        let reply: @Sendable (SPUUserUpdateChoice) -> Void

        var version: String { appcastItem.displayVersionString }
        var contentLength: UInt64 { appcastItem.contentLength }
        var date: Date? { appcastItem.date }
    }

    struct Downloading {
        let cancel: () -> Void
        let version: String?
        let expectedLength: UInt64?
        let progress: UInt64

        /// 0…1 once Sparkle has told us the length.
        var fraction: Double? {
            guard let expectedLength, expectedLength > 0 else { return nil }
            return min(1, Double(progress) / Double(expectedLength))
        }
    }

    struct Extracting {
        let version: String?
        let progress: Double
    }

    struct Installing {
        /// Staged by Sparkle's automatic driver (`willInstallUpdateOnQuit`) or resurfaced by a
        /// scheduled check while staged: a plain quit installs it. False while Sparkle is
        /// terminating the app on the interactive path.
        let isAutoUpdate: Bool
        let version: String?
        /// Terminate and relaunch through the installer now.
        let restart: () -> Void
        /// Close the question and keep the update staged (Sparkle's install on quit).
        let later: () -> Void
        /// Un-stage and forget this version; only there when Sparkle handed us a reply block.
        let skip: (() -> Void)?
    }

    struct NotFound {
        let id = UUID()
    }

    struct Failure {
        enum Kind: Equatable { case translocated, other }
        let error: any Error
        let kind: Kind
        let retry: () -> Void
        let dismiss: () -> Void

        /// Sparkle refuses to update an app running translocated or from a read-only volume
        /// (`SURunningFromDiskImageError` = 1003, `SURunningTranslocated` = 1005 in
        /// `SUSparkleErrorDomain`); a retry there can never succeed.
        static func kind(domain: String, code: Int) -> Kind {
            domain == "SUSparkleErrorDomain" && (code == 1003 || code == 1005) ? .translocated : .other
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateStateTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Update/UpdateViewModel.swift Tests/UpdateStateTests.swift
git commit -m "feat(update): the update state model, ported from Ghostty

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `UpdateController` and `UpdateDriver`

Spec §2, §3, §4 (rules), §8 (gate, quit path). Ported from Ghostty's `UpdateController.swift`, `UpdateDriver.swift`, `UpdateDelegate.swift` (MIT).

**Files:**
- Create: `Sources/Update/UpdateController.swift`, `Sources/Update/UpdateDriver.swift`
- Test: `Tests/UpdateControllerTests.swift`

**Interfaces:**
- Consumes: Task 1 `UpdateSettings`, Task 3 `UpdateViewModel` / `UpdateState`.
- Produces:
  - `@MainActor final class UpdateController` with `init(enabled: Bool, feedOverride: URL? = nil, hostBundle: Bundle = .main)`, `let viewModel: UpdateViewModel`, `private(set) var updater: SPUUpdater?`, `private(set) var settings: UpdateSettings`, `private(set) var relaunchRequested: Bool`, `var canCheckForUpdates: Bool`, `var showSheet: () -> Void` (wired by Task 8), `func apply(_:)`, `func start()`, `func checkForUpdates()`, `func installUpdate()`, `func requestRelaunch(_ restart: () -> Void)`, `func noteInstallerTerminating()`, `func clearNotFound(_ id: UUID? = nil)`, `static func isEnabled(isRunningTests:hasPublicKey:isDebugBuild:feedOverride:) -> Bool`, `static var isDebugBuild: Bool`, `static func hasPublicKey(in:) -> Bool`, `static var notFoundClearDelay: TimeInterval`, `static let logger`.
  - `final class UpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate` with `init(viewModel:feedOverride:)`, `weak var controller`, `static func foundState(item:stage:userInitiated:reply:) -> UpdateState`.

- [ ] **Step 1: Write the failing test**

`Tests/UpdateControllerTests.swift`:

```swift
import Sparkle
import XCTest
@testable import QuickTerm

/// The controller without a Sparkle updater (the test host never has one): the gate, the stored
/// settings, the relaunch flag, the not-found timer and the driver's callback mapping.
@MainActor
final class UpdateControllerTests: XCTestCase {
    private var controller: UpdateController!
    private var driver: UpdateDriver!

    override func setUp() {
        super.setUp()
        controller = UpdateController(enabled: false)
        driver = UpdateDriver(viewModel: controller.viewModel, feedOverride: nil)
        driver.controller = controller
    }

    override func tearDown() {
        UpdateController.notFoundClearDelay = 5
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: The gate

    func testTheGateIsPure() {
        let feed = URL(string: "https://example.invalid/appcast.xml")
        XCTAssertFalse(UpdateController.isEnabled(isRunningTests: true, hasPublicKey: true, isDebugBuild: false, feedOverride: nil))
        XCTAssertFalse(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: false, isDebugBuild: false, feedOverride: nil))
        XCTAssertTrue(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: true, isDebugBuild: false, feedOverride: nil))
        XCTAssertFalse(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: true, isDebugBuild: true, feedOverride: nil))
        XCTAssertTrue(UpdateController.isEnabled(isRunningTests: false, hasPublicKey: true, isDebugBuild: true, feedOverride: feed))
    }

    func testDisabledControllerHasNoUpdaterAndStoresSettings() {
        XCTAssertNil(controller.updater)
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.apply(UpdateSettings(check: false, install: true))
        XCTAssertEqual(controller.settings, UpdateSettings(check: false, install: true))
        controller.start()
        controller.checkForUpdates()
        XCTAssertTrue(controller.viewModel.state.isIdle, "nothing to do without an updater")
    }

    // MARK: relaunchRequested

    func testRelaunchRequestedFollowsTheInstallPaths() {
        var replies: [SPUUserUpdateChoice] = []
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded,
                                                            userInitiated: true, reply: { replies.append($0) }))
        XCTAssertFalse(controller.relaunchRequested)
        controller.installUpdate()
        XCTAssertTrue(controller.relaunchRequested, "Install and Relaunch asks for a relaunch")
        XCTAssertEqual(replies, [.install], "the chain confirmed the available state")
        controller.viewModel.state = .downloading(.init(cancel: {}, version: "9", expectedLength: 10, progress: 1))
        XCTAssertTrue(controller.relaunchRequested, "still set through the download")
        controller.viewModel.state = .idle
        XCTAssertFalse(controller.relaunchRequested, "cancelled: cleared")

        var restarted = false
        controller.viewModel.state = .installing(.init(isAutoUpdate: true, version: "9", restart: { restarted = true }, later: {}, skip: nil))
        XCTAssertFalse(controller.relaunchRequested, "a staged update alone asks for nothing")
        if case .installing(let installing) = controller.viewModel.state { controller.requestRelaunch(installing.restart) }
        XCTAssertTrue(restarted)
        XCTAssertTrue(controller.relaunchRequested, "Restart Now asks for a relaunch")

        controller.viewModel.state = .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {}))
        XCTAssertFalse(controller.relaunchRequested, "an error clears it")
        controller.noteInstallerTerminating()
        XCTAssertTrue(controller.relaunchRequested, "Sparkle terminating the app sets it")
    }

    // MARK: not found

    func testNotFoundClearsItselfAfterTheDelay() {
        UpdateController.notFoundClearDelay = 0.05
        controller.viewModel.state = .notFound(.init())
        spin(0.2)
        XCTAssertTrue(controller.viewModel.state.isIdle)
    }

    func testAClickClearsNotFoundEarlyAndOnlyThatInstance() {
        UpdateController.notFoundClearDelay = 10
        controller.viewModel.state = .notFound(.init())
        controller.clearNotFound(UUID())
        XCTAssertFalse(controller.viewModel.state.isIdle, "a stale id is ignored")
        controller.clearNotFound()
        XCTAssertTrue(controller.viewModel.state.isIdle)
    }

    // MARK: the driver

    func testNotFoundAndErrorAcknowledgeSparkleImmediately() {
        var acknowledged = 0
        driver.showUpdateNotFoundWithError(NSError(domain: "SUSparkleErrorDomain", code: 1001)) { acknowledged += 1 }
        XCTAssertEqual(acknowledged, 1)
        guard case .notFound = controller.viewModel.state else { return XCTFail("expected notFound") }
        driver.showUpdaterError(NSError(domain: "SUSparkleErrorDomain", code: 1005)) { acknowledged += 1 }
        XCTAssertEqual(acknowledged, 2)
        guard case .error(let failure) = controller.viewModel.state else { return XCTFail("expected error") }
        XCTAssertEqual(failure.kind, .translocated)
        failure.dismiss()
        XCTAssertTrue(controller.viewModel.state.isIdle)
    }

    func testAStagedUpdateMapsToInstalling() {
        var replies: [SPUUserUpdateChoice] = []
        let state = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .installing, userInitiated: false) { replies.append($0) }
        guard case .installing(let installing) = state else { return XCTFail("expected installing, got \(state)") }
        XCTAssertTrue(installing.isAutoUpdate)
        installing.restart(); installing.later(); installing.skip?()
        XCTAssertEqual(replies, [.install, .dismiss, .skip])
    }

    func testADownloadedUpdateKeepsItsStage() {
        let downloaded = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .downloaded, userInitiated: true) { _ in }
        guard case .updateAvailable(let available) = downloaded else { return XCTFail("expected updateAvailable") }
        XCTAssertEqual(available.stage, .downloaded)
        XCTAssertTrue(available.userInitiated)
        let fresh = UpdateDriver.foundState(item: SUAppcastItem.empty(), stage: .notDownloaded, userInitiated: false) { _ in }
        guard case .updateAvailable(let a) = fresh else { return XCTFail() }
        XCTAssertEqual(a.stage, .notDownloaded)
    }

    func testDownloadProgressAccumulatesAndKeepsTheVersion() {
        controller.viewModel.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: .notDownloaded, userInitiated: false, reply: { _ in }))
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 30)
        driver.showDownloadDidReceiveData(ofLength: 30)
        guard case .downloading(let d) = controller.viewModel.state else { return XCTFail() }
        XCTAssertEqual(d.progress, 60)
        XCTAssertEqual(d.fraction!, 0.6, accuracy: 0.001)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.5)
        guard case .extracting(let e) = controller.viewModel.state else { return XCTFail() }
        XCTAssertEqual(e.progress, 0.5)
    }

    func testReadyToInstallRepliesInstallAndMarksTheRelaunch() {
        var choice: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { choice = $0 })
        XCTAssertEqual(choice, .install)
        XCTAssertTrue(controller.relaunchRequested)
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        guard case .installing(let i) = controller.viewModel.state else { return XCTFail() }
        XCTAssertFalse(i.isAutoUpdate)
    }

    func testPermissionRequestIsAnsweredFromTheSettings() {
        controller.apply(UpdateSettings(check: false, install: false))
        var response: SUUpdatePermissionResponse?
        driver.show(SPUUpdatePermissionRequest(systemProfile: [])) { response = $0 }
        XCTAssertEqual(response?.automaticUpdateChecks, false)
        XCTAssertEqual(response?.sendSystemProfile, false)
        XCTAssertTrue(controller.viewModel.state.isIdle, "no UI for a question the config answers")
    }

    func testRelaunchPolicyAndFeedOverride() {
        let feed = URL(string: "https://example.invalid/e2e/appcast.xml")!
        let overridden = UpdateDriver(viewModel: UpdateViewModel(), feedOverride: feed)
        let stock = UpdateDriver(viewModel: UpdateViewModel(), feedOverride: nil)
        XCTAssertEqual(overridden.feedURLOverrideString, feed.absoluteString)
        XCTAssertNil(stock.feedURLOverrideString, "nil = Sparkle reads SUFeedURL")
        XCTAssertFalse(overridden.shouldRelaunch, "the E2E tester relaunches by hand")
        XCTAssertTrue(stock.shouldRelaunch)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateControllerTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile errors (`UpdateController` / `UpdateDriver` not found).

- [ ] **Step 3: Create `Sources/Update/UpdateController.swift`**

```swift
import AppKit
import Combine
import OSLog
import Sparkle

// Ported from Ghostty (macos/Sources/Features/Update/UpdateController.swift, MIT) and adapted.

/// Owns the Sparkle updater and the view model every status bar observes.
///
/// `updater` is nil when updating is off for this process (`isEnabled`): the test host, a build
/// without a public key, or a Debug build without the feed override. Everything else still works —
/// settings are stored, the view model idles, the simulator can drive the UI — so the app never has
/// two code paths.
@MainActor
final class UpdateController {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.danny.quickterm",
                               category: "updates")
    /// How long "You're up to date" stays on the bar before the state goes idle again.
    static var notFoundClearDelay: TimeInterval = 5

    let viewModel: UpdateViewModel
    private(set) var updater: SPUUpdater?
    private let driver: UpdateDriver
    private(set) var settings = UpdateSettings()
    private(set) var started = false
    /// A relaunch through the installer was asked for (Install and Relaunch, Restart Now, or Sparkle
    /// terminating the app to install): the quit confirmation stands aside (`AppDelegate`).
    private(set) var relaunchRequested = false
    /// Opens the update sheet for the current state; wired by the app once the sheet exists.
    var showSheet: () -> Void = {}
    private var installCancellable: AnyCancellable?
    private var stateCancellable: AnyCancellable?
    private var notFoundClearTask: DispatchWorkItem?

    init(enabled: Bool, feedOverride: URL? = nil, hostBundle: Bundle = .main) {
        let viewModel = UpdateViewModel()
        self.viewModel = viewModel
        self.driver = UpdateDriver(viewModel: viewModel, feedOverride: feedOverride)
        if enabled {
            updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle,
                                 userDriver: driver, delegate: driver)
        }
        driver.controller = self
        stateCancellable = viewModel.$state.sink { [weak self] state in self?.stateDidChange(state) }
    }

    /// The gate, as a pure function.
    static func isEnabled(isRunningTests: Bool, hasPublicKey: Bool, isDebugBuild: Bool,
                          feedOverride: URL?) -> Bool {
        if isRunningTests || !hasPublicKey { return false }
        return !isDebugBuild || feedOverride != nil
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// `SUPublicEDKey` present and non-empty: without it Sparkle's `start()` fails, which would
    /// put an error icon on every user's bar at every launch.
    static func hasPublicKey(in bundle: Bundle) -> Bool {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    /// The config is the source of truth over Sparkle's persisted preferences: both flags are
    /// written on every apply, checks first (Sparkle drops a downloads=true while checks is false).
    func apply(_ settings: UpdateSettings) {
        self.settings = settings
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = settings.checksEnabled
        updater.automaticallyDownloadsUpdates = settings.install
    }

    /// Once, at the end of `applicationDidFinishLaunching`.
    func start() {
        guard let updater, !started else { return }
        started = true
        do {
            try updater.start()
        } catch {
            Self.logger.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
            viewModel.state = .error(.init(
                error: error, kind: .other,
                retry: { [weak self] in
                    self?.viewModel.state = .idle
                    self?.started = false
                    self?.start()
                },
                dismiss: { [weak self] in self?.viewModel.state = .idle }))
            return
        }
        apply(settings)
        // Sparkle's own scheduler checks at launch only when a day has passed since the last check;
        // this is what makes "at launch" true and what brings an unhandled update back after a
        // relaunch. Dispatched: start() finishes its own setup asynchronously.
        if settings.checksEnabled {
            DispatchQueue.main.async { [weak self] in self?.updater?.checkForUpdatesInBackground() }
        }
    }

    /// Check for Updates… (menu item, engine keybind action).
    func checkForUpdates() {
        guard let updater else { return }
        switch viewModel.state {
        case .idle, .updateAvailable, .installing:
            // With an update on screen Sparkle routes this to showUpdateInFocus (the sheet).
            updater.checkForUpdates()
        default:
            // Checking, downloading, not found, error: close it and check afresh. The settle delay
            // is Ghostty's: one run-loop tick is not enough for Sparkle to end the session.
            installCancellable?.cancel()
            viewModel.state.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.updater?.checkForUpdates()
            }
        }
    }

    /// Install and Relaunch: says yes to every step from here to the installer.
    func installUpdate() {
        guard viewModel.state.isInstallable, installCancellable == nil else { return }
        relaunchRequested = true
        // The sink runs at once with the current state, so the first confirm needs no extra call.
        installCancellable = viewModel.$state.sink { [weak self] state in
            guard let self else { return }
            guard state.isInstallable else {
                self.installCancellable = nil
                return
            }
            state.confirm()
        }
    }

    /// Restart Now on a staged update.
    func requestRelaunch(_ restart: () -> Void) {
        relaunchRequested = true
        restart()
    }

    /// Sparkle is about to terminate the app to install (`showReady` / `showInstallingUpdate`).
    func noteInstallerTerminating() {
        relaunchRequested = true
    }

    private func stateDidChange(_ state: UpdateState) {
        switch state {
        case .idle, .notFound, .error, .updateAvailable:
            relaunchRequested = false
        case .checking, .downloading, .extracting, .installing:
            break
        }
        notFoundClearTask?.cancel()
        notFoundClearTask = nil
        if case .notFound(let notFound) = state {
            let task = DispatchWorkItem { [weak self] in self?.clearNotFound(notFound.id) }
            notFoundClearTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.notFoundClearDelay, execute: task)
        }
    }

    /// The 5 s timer, or a click on the bar during "up to date": back to idle. `id` guards a
    /// timer that outlived its own not-found (a second check meanwhile).
    func clearNotFound(_ id: UUID? = nil) {
        guard case .notFound(let notFound) = viewModel.state else { return }
        if let id, id != notFound.id { return }
        viewModel.state = .idle
    }
}
```

- [ ] **Step 4: Create `Sources/Update/UpdateDriver.swift`**

```swift
import AppKit
import Sparkle

// Ported from Ghostty (macos/Sources/Features/Update/UpdateDriver.swift + UpdateDelegate.swift,
// MIT) and adapted: no SPUStandardUserDriver fallback and no terminal-window observers; a
// stage-aware showUpdateFound; showUpdateInFocus opens the sheet; errors and not-found are
// acknowledged at once so no Sparkle session is ever held by a view.

/// Mirrors every Sparkle callback into the view model.
final class UpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    let viewModel: UpdateViewModel
    /// Debug-only feed override (`--update-feed-url`); nil = Sparkle reads `SUFeedURL`.
    let feedOverride: URL?
    weak var controller: UpdateController?

    init(viewModel: UpdateViewModel, feedOverride: URL?) {
        self.viewModel = viewModel
        self.feedOverride = feedOverride
        super.init()
    }

    /// The version an in-flight state is about, for the download / extraction states.
    private var versionInFlight: String? {
        switch viewModel.state {
        case .updateAvailable(let a): return a.version
        case .downloading(let d): return d.version
        case .extracting(let e): return e.version
        case .installing(let i): return i.version
        default: return nil
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        // SUEnableAutomaticChecks is set, so Sparkle should never ask; if it does, the config answers.
        let checks = controller?.settings.checksEnabled ?? true
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: checks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        viewModel.state = .checking(.init(cancel: cancellation))
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        viewModel.state = Self.foundState(item: appcastItem, stage: state.stage,
                                          userInitiated: state.userInitiated, reply: reply)
    }

    /// Pure, so tests need no `SPUUserUpdateState`. A staged update (`.installing`) is the
    /// "quit or restart to finish" state, not a fresh "78 MB available".
    static func foundState(item: SUAppcastItem, stage: SPUUserUpdateStage, userInitiated: Bool,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) -> UpdateState {
        switch stage {
        case .installing:
            return .installing(.init(isAutoUpdate: true, version: item.displayVersionString,
                                     restart: { reply(.install) }, later: { reply(.dismiss) },
                                     skip: { reply(.skip) }))
        case .downloaded:
            return .updateAvailable(.init(appcastItem: item, stage: .downloaded,
                                          userInitiated: userInitiated, reply: reply))
        default:
            return .updateAvailable(.init(appcastItem: item, stage: .notDownloaded,
                                          userInitiated: userInitiated, reply: reply))
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The feed carries no releaseNotesLink; notes are fetched by ReleaseNotes.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        viewModel.state = .notFound(.init())
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        UpdateController.logger.error("updater error \(nsError.domain, privacy: .public)/\(nsError.code): \(error.localizedDescription, privacy: .public)")
        acknowledgement()
        viewModel.state = .error(.init(
            error: error,
            kind: UpdateState.Failure.kind(domain: nsError.domain, code: nsError.code),
            retry: { [weak self] in
                self?.viewModel.state = .idle
                DispatchQueue.main.async { self?.controller?.checkForUpdates() }
            },
            dismiss: { [weak self] in self?.viewModel.state = .idle }))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        viewModel.state = .downloading(.init(cancel: cancellation, version: versionInFlight,
                                             expectedLength: nil, progress: 0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case .downloading(let d) = viewModel.state else { return }
        viewModel.state = .downloading(.init(cancel: d.cancel, version: d.version,
                                             expectedLength: expectedContentLength, progress: 0))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case .downloading(let d) = viewModel.state else { return }
        viewModel.state = .downloading(.init(cancel: d.cancel, version: d.version,
                                             expectedLength: d.expectedLength, progress: d.progress + length))
    }

    func showDownloadDidStartExtractingUpdate() {
        viewModel.state = .extracting(.init(version: versionInFlight, progress: 0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.state = .extracting(.init(version: versionInFlight, progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        // The user already said Install and Relaunch; nothing to ask again.
        controller?.noteInstallerTerminating()
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        controller?.noteInstallerTerminating()
        viewModel.state = .installing(.init(isAutoUpdate: false, version: versionInFlight,
                                            restart: retryTerminatingApplication, later: {}, skip: nil))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        viewModel.state = .idle
    }

    func showUpdateInFocus() {
        controller?.showSheet()
    }

    func dismissUpdateInstallation() {
        viewModel.state = .idle
    }

    // MARK: SPUUpdaterDelegate

    /// nil = Sparkle reads `SUFeedURL` from the Info.plist.
    var feedURLOverrideString: String? { feedOverride?.absoluteString }

    /// Under the E2E feed override Sparkle installs and quits; the tester relaunches by hand with
    /// the same arguments (Sparkle's relaunch carries neither arguments nor environment).
    var shouldRelaunch: Bool { feedOverride == nil }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverrideString
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(isAutoUpdate: true, version: item.displayVersionString,
                                            restart: immediateInstallHandler, later: {}, skip: nil))
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        shouldRelaunch
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateControllerTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Update/UpdateController.swift Sources/Update/UpdateDriver.swift Tests/UpdateControllerTests.swift
git commit -m "feat(update): Sparkle controller and user driver, ported from Ghostty

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `UpdateSimulator`

Spec §2 (simulator row), §11. Ported from Ghostty's `UpdateSimulator.swift` (MIT), adapted to the new `UpdateState` shapes, with a delay scale so tests run it in milliseconds.

**Files:**
- Create: `Sources/Update/UpdateSimulator.swift`
- Test: `Tests/UpdateSimulatorTests.swift`

**Interfaces:**
- Consumes: Task 3 `UpdateViewModel` / `UpdateState`.
- Produces: `enum UpdateSimulator: String, CaseIterable { happyPath, notFound, error, slowDownload, cancelDuringDownload, cancelDuringChecking, staged, autoUpdate }`, `static var delayScale: Double`, `func simulate(with viewModel: UpdateViewModel)`.

- [ ] **Step 1: Write the failing test**

`Tests/UpdateSimulatorTests.swift`:

```swift
import XCTest
@testable import QuickTerm

/// The scripted scenarios really walk the state machine (they are what the UI is checked against
/// without a server).
@MainActor
final class UpdateSimulatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UpdateSimulator.delayScale = 0.01   // 2 s steps become 20 ms
    }

    override func tearDown() {
        UpdateSimulator.delayScale = 1
        super.tearDown()
    }

    private func wait(until predicate: @escaping () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    func testHappyPathReachesInstallingAfterAnInstall() {
        let model = UpdateViewModel()
        UpdateSimulator.happyPath.simulate(with: model)
        XCTAssertTrue(wait { if case .updateAvailable = model.state { return true }; return false })
        model.state.confirm()
        XCTAssertTrue(wait { if case .downloading = model.state { return true }; return false })
        XCTAssertTrue(wait { if case .extracting = model.state { return true }; return false })
        XCTAssertTrue(wait { if case .installing = model.state { return true }; return false })
    }

    func testNotFoundAndErrorScenarios() {
        let model = UpdateViewModel()
        UpdateSimulator.notFound.simulate(with: model)
        XCTAssertTrue(wait { if case .notFound = model.state { return true }; return false })
        let other = UpdateViewModel()
        UpdateSimulator.error.simulate(with: other)
        XCTAssertTrue(wait { if case .error = other.state { return true }; return false })
    }

    func testStagedAndAutoUpdateScenarios() {
        let staged = UpdateViewModel()
        UpdateSimulator.staged.simulate(with: staged)
        guard case .installing(let i) = staged.state else { return XCTFail("staged goes straight to installing") }
        XCTAssertTrue(i.isAutoUpdate)
        XCTAssertNotNil(i.skip, "a staged update offers Skip")
        let auto = UpdateViewModel()
        UpdateSimulator.autoUpdate.simulate(with: auto)
        guard case .installing(let a) = auto.state else { return XCTFail() }
        XCTAssertNil(a.skip, "Sparkle's willInstallUpdateOnQuit hands over no reply block")
    }

    func testEveryScenarioIsNamedForTheEnvironmentVariable() {
        XCTAssertEqual(UpdateSimulator(rawValue: "happyPath"), .happyPath)
        XCTAssertEqual(UpdateSimulator.allCases.count, 8)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateSimulatorTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile error (`UpdateSimulator` not found).

- [ ] **Step 3: Create `Sources/Update/UpdateSimulator.swift`**

```swift
import Foundation
import Sparkle

// Ported from Ghostty (macos/Sources/Features/Update/UpdateSimulator.swift, MIT) and adapted.

/// Scripted update scenarios for exercising the indicator and the sheet without a server.
///
/// A Debug build runs one at launch when `QUICKTERM_UPDATE_SIMULATE=<case>` is set (see
/// `AppDelegate`); tests run them with `delayScale` near zero.
enum UpdateSimulator: String, CaseIterable {
    /// checking → available → (confirm) → download → extract → installing
    case happyPath
    /// checking → not found
    case notFound
    /// checking → error with a retry that runs the happy path
    case error
    /// happy path with a 20-step download for the progress ring
    case slowDownload
    /// available → download 5 steps → cancelled → idle
    case cancelDuringDownload
    /// checking → cancelled → idle
    case cancelDuringChecking
    /// a staged update resurfacing (`showUpdateFound` with stage .installing): Restart / Later / Skip
    case staged
    /// Sparkle's automatic driver staged it (`willInstallUpdateOnQuit`): Restart / Later
    case autoUpdate

    /// Multiplies every delay; tests set it to ~0.01.
    static var delayScale: Double = 1

    func simulate(with viewModel: UpdateViewModel) {
        switch self {
        case .happyPath: Self.check(viewModel) { Self.offer(viewModel, steps: 10) }
        case .notFound: Self.check(viewModel) { viewModel.state = .notFound(.init()) }
        case .error:
            Self.check(viewModel) {
                viewModel.state = .error(.init(
                    error: NSError(domain: "UpdateSimulator", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Failed to check for updates"]),
                    kind: .other,
                    retry: { UpdateSimulator.happyPath.simulate(with: viewModel) },
                    dismiss: { viewModel.state = .idle }))
            }
        case .slowDownload: Self.check(viewModel) { Self.offer(viewModel, steps: 20) }
        case .cancelDuringDownload:
            Self.check(viewModel) {
                Self.offer(viewModel, steps: 5, thenCancel: true)
            }
        case .cancelDuringChecking:
            viewModel.state = .checking(.init(cancel: { viewModel.state = .idle }))
            Self.after(1) { viewModel.state = .idle }
        case .staged:
            viewModel.state = .installing(.init(
                isAutoUpdate: true, version: "9.9.9",
                restart: { viewModel.state = .idle },
                later: {},
                skip: { viewModel.state = .idle }))
        case .autoUpdate:
            viewModel.state = .installing(.init(
                isAutoUpdate: true, version: "9.9.9",
                restart: { viewModel.state = .idle },
                later: {},
                skip: nil))
        }
    }

    private static func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * delayScale, execute: body)
    }

    private static func check(_ viewModel: UpdateViewModel, then next: @escaping () -> Void) {
        viewModel.state = .checking(.init(cancel: { viewModel.state = .idle }))
        after(2, next)
    }

    /// An available 9.9.9 whose Install starts a scripted download.
    private static func offer(_ viewModel: UpdateViewModel, steps: Int, thenCancel: Bool = false) {
        viewModel.state = .updateAvailable(.init(
            appcastItem: SUAppcastItem.empty(), stage: .notDownloaded, userInitiated: true,
            reply: { choice in
                guard choice == .install else { viewModel.state = .idle; return }
                download(viewModel, steps: steps, thenCancel: thenCancel)
            }))
    }

    private static func download(_ viewModel: UpdateViewModel, steps: Int, thenCancel: Bool) {
        let total = UInt64(steps * 100)
        viewModel.state = .downloading(.init(cancel: { viewModel.state = .idle }, version: "9.9.9",
                                             expectedLength: nil, progress: 0))
        for i in 1...steps {
            after(Double(i) * 0.3) {
                guard case .downloading(let d) = viewModel.state else { return }
                viewModel.state = .downloading(.init(cancel: d.cancel, version: d.version,
                                                     expectedLength: total, progress: UInt64(i * 100)))
                if i == steps {
                    after(0.5) {
                        if thenCancel { viewModel.state = .idle } else { extract(viewModel) }
                    }
                }
            }
        }
    }

    private static func extract(_ viewModel: UpdateViewModel) {
        viewModel.state = .extracting(.init(version: "9.9.9", progress: 0))
        for j in 1...5 {
            after(Double(j) * 0.3) {
                viewModel.state = .extracting(.init(version: "9.9.9", progress: Double(j) / 5))
                if j == 5 {
                    after(0.5) {
                        viewModel.state = .installing(.init(isAutoUpdate: false, version: "9.9.9",
                                                            restart: { viewModel.state = .idle },
                                                            later: {}, skip: nil))
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateSimulatorTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Update/UpdateSimulator.swift Tests/UpdateSimulatorTests.swift
git commit -m "feat(update): scripted update scenarios for the UI, ported from Ghostty

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `ReleaseNotes`

Spec §6.

**Files:**
- Create: `Sources/Update/ReleaseNotes.swift`
- Test: `Tests/ReleaseNotesTests.swift`

**Interfaces:**
- Consumes: `AppLanguage` (`.en` / `.zh`, `Sources/Config/ConfigSchema.swift`).
- Produces: `enum ReleaseNotes` with `static func isValidVersion(_:) -> Bool`, `static func assetURL(version:language:) -> URL?`, `static func releasePageURL(version:) -> URL?`, `static func candidateURLs(version:language:) -> [URL]`, `static func plainText(fromMarkdown:) -> String`, and `@MainActor final class ReleaseNotes.Loader { var session: URLSession; var timeout: TimeInterval; func notes(version:language:fallback:) async -> String? }`.

- [ ] **Step 1: Write the failing test**

`Tests/ReleaseNotesTests.swift`:

```swift
import XCTest
@testable import QuickTerm

/// Where the notes come from and how Markdown is flattened for the house text area.
final class ReleaseNotesTests: XCTestCase {
    func testAssetURLsFollowTheReleaseLayout() {
        XCTAssertEqual(ReleaseNotes.assetURL(version: "1.6.8", language: .en)?.absoluteString,
                       "https://github.com/dannyzhu/QuickTerm/releases/download/v1.6.8/QuickTerm-1.6.8-notes.md")
        XCTAssertEqual(ReleaseNotes.assetURL(version: "1.6.8", language: .zh)?.absoluteString,
                       "https://github.com/dannyzhu/QuickTerm/releases/download/v1.6.8/QuickTerm-1.6.8-notes.zh-CN.md")
        XCTAssertEqual(ReleaseNotes.releasePageURL(version: "1.6.8")?.absoluteString,
                       "https://github.com/dannyzhu/QuickTerm/releases/tag/v1.6.8")
    }

    func testAVersionThatIsNotThreeNumbersGetsNoURL() {
        for bad in ["1.6", "v1.6.8", "1.6.8/../x", "", "abc", "1.6.8 "] {
            XCTAssertFalse(ReleaseNotes.isValidVersion(bad), bad)
            XCTAssertNil(ReleaseNotes.assetURL(version: bad, language: .en), bad)
        }
        XCTAssertTrue(ReleaseNotes.isValidVersion("1.6.8"))
    }

    func testTheUILanguageComesFirstThenTheOther() {
        let zh = ReleaseNotes.candidateURLs(version: "1.6.8", language: .zh)
        XCTAssertEqual(zh.map(\.lastPathComponent), ["QuickTerm-1.6.8-notes.zh-CN.md", "QuickTerm-1.6.8-notes.md"])
        let en = ReleaseNotes.candidateURLs(version: "1.6.8", language: .en)
        XCTAssertEqual(en.map(\.lastPathComponent), ["QuickTerm-1.6.8-notes.md", "QuickTerm-1.6.8-notes.zh-CN.md"])
    }

    func testMarkdownIsFlattened() {
        let markdown = """
        ## QuickTerm 1.6.8

        Universal binary. **Signed** and `notarized`.

        ### Fixes
        - Cmd-clicking a [link](https://example.com/x) works.
        - Second item
          - nested

        ```bash
        # keep me
        make-release.sh --notarize
        ```
        """
        let plain = ReleaseNotes.plainText(fromMarkdown: markdown)
        XCTAssertEqual(plain, """
        QuickTerm 1.6.8

        Universal binary. Signed and notarized.

        Fixes
        • Cmd-clicking a link (https://example.com/x) works.
        • Second item
          • nested

        # keep me
        make-release.sh --notarize
        """)
    }

    @MainActor
    func testTheLoaderFallsBackWithoutTouchingTheNetworkForABadVersion() async {
        let loader = ReleaseNotes.Loader()
        let text = await loader.notes(version: "not-a-version", language: .en, fallback: "## Fallback\n- ok")
        XCTAssertEqual(text, "Fallback\n• ok")
        let none = await loader.notes(version: "not-a-version", language: .en, fallback: nil)
        XCTAssertNil(none)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/ReleaseNotesTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile error (`ReleaseNotes` not found).

- [ ] **Step 3: Create `Sources/Update/ReleaseNotes.swift`**

```swift
import Foundation

/// The release notes an update sheet shows: fetched from the release's own assets in the UI
/// language and flattened from Markdown to plain text for the house scrollable text area.
enum ReleaseNotes {
    static let repository = "dannyzhu/QuickTerm"
    private static let versionPattern = #"^\d+\.\d+\.\d+$"#

    /// Only a three-part version is ever put into a URL.
    static func isValidVersion(_ version: String) -> Bool {
        version.range(of: versionPattern, options: .regularExpression) != nil
    }

    /// `QuickTerm-<ver>-notes.md` / `-notes.zh-CN.md`, uploaded by make-release.sh next to the DMG
    /// (same host as the update itself, unlike raw.githubusercontent.com).
    static func assetURL(version: String, language: AppLanguage) -> URL? {
        guard isValidVersion(version) else { return nil }
        let suffix = language == .zh ? "-notes.zh-CN.md" : "-notes.md"
        return URL(string: "https://github.com/\(repository)/releases/download/v\(version)/QuickTerm-\(version)\(suffix)")
    }

    static func releasePageURL(version: String) -> URL? {
        guard isValidVersion(version) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")
    }

    /// The UI language first, then the other one.
    static func candidateURLs(version: String, language: AppLanguage) -> [URL] {
        let other: AppLanguage = language == .zh ? .en : .zh
        return [assetURL(version: version, language: language),
                assetURL(version: version, language: other)].compactMap { $0 }
    }

    /// Headings lose their `#`, list markers become `•`, inline code and emphasis lose their
    /// markers, links become `text (url)`, fenced code is kept verbatim.
    static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                lines.append(raw)
                continue
            }
            var line = raw
            if let heading = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(heading)
            }
            if let marker = line.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
                let indent = String(line[marker].prefix { $0 == " " || $0 == "\t" })
                line = indent + "• " + String(line[marker.upperBound...])
            }
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)",
                                             options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetches and caches the notes per version; a failure never blocks the sheet.
    @MainActor
    final class Loader {
        var session: URLSession = .shared
        var timeout: TimeInterval = 10
        private var cache: [String: String] = [:]

        /// The notes in `language`, else the other language, else `fallback` (the appcast's
        /// description), else nil.
        func notes(version: String, language: AppLanguage, fallback: String?) async -> String? {
            let key = "\(version)|\(language.rawValue)"
            if let hit = cache[key] { return hit }
            for url in ReleaseNotes.candidateURLs(version: version, language: language) {
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let plain = ReleaseNotes.plainText(fromMarkdown: text)
                cache[key] = plain
                return plain
            }
            if let fallback, !fallback.isEmpty { return ReleaseNotes.plainText(fromMarkdown: fallback) }
            return nil
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/ReleaseNotesTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `Executed 5 tests, with 0 failures`. If `testMarkdownIsFlattened` differs only in trailing whitespace of the nested bullet line, trim per line in `plainText` before joining.

- [ ] **Step 5: Commit**

```bash
git add Sources/Update/ReleaseNotes.swift Tests/ReleaseNotesTests.swift
git commit -m "feat(update): release notes from the release assets, flattened for the sheet

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: The status-bar indicator and the app wiring

Spec §2 (ownership), §4 (indicator rules), §8 (gate), §9 (strings).

**Files:**
- Create: `Sources/Update/UpdateIndicator.swift`, `Resources/en.lproj/Update.strings`, `Resources/zh-Hans.lproj/Update.strings`
- Modify: `Sources/Windowing/AppSession.swift` (properties ~line 21-26, `init` ~line 77, `applyGlobalConfig` ~line 209), `Sources/App/AppDelegate.swift` (`LaunchOverrides` ~line 60-118, `applicationDidFinishLaunching` ~line 187-222), `Sources/Windowing/MainWindowController.swift` (~line 23, ~line 350), `Sources/Windowing/RootView.swift` (~line 249, ~line 277), `Sources/StatusBar/StatusBarView.swift` (line 4, ~line 12, ~line 21, ~line 205), `Sources/StatusBar/WorkspacePill.swift` (line 9)
- Test: `Tests/UpdateIndicatorTests.swift`

**Interfaces:**
- Consumes: Task 3 `UpdateState`, Task 4 `UpdateController`, Task 1 `UpdateSettings`.
- Produces: `struct UpdateIndicatorGlyph: Equatable { symbol: String?; ring: Double?; tone: Tone (.foreground/.accent/.alert); tooltipKey: String; tooltipArguments: [String]; init?(state:) }`, `struct UpdateIndicator: View { model: UpdateViewModel; onClick: () -> Void }`, `AppSession.updates: UpdateController` (init parameter `updates:`), `AppDelegate.LaunchOverrides.updateFeed` / `.updateFeedURL`, `StatusBarView(model:stats:updates:onSelectWorkspace:onRenameWorkspace:onToggleMute:onUpdateClick:)`, `RootView(model:ghostty:stats:updates:action:onScrollingDrop:onSelectWorkspace:onRenameWorkspace:onPanelChoose:onUpdateClick:)`.

- [ ] **Step 1: Write the failing test**

`Tests/UpdateIndicatorTests.swift`:

```swift
import Sparkle
import SwiftUI
import XCTest
@testable import QuickTerm

/// The status-bar item: which glyph each state gets, and that it hides when idle and fits the bar.
@MainActor
final class UpdateIndicatorTests: XCTestCase {
    private func available(stage: UpdateState.UpdateAvailable.Stage = .notDownloaded) -> UpdateState {
        .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: stage, userInitiated: false, reply: { _ in }))
    }

    func testIdleHasNoGlyph() {
        XCTAssertNil(UpdateIndicatorGlyph(state: .idle))
    }

    func testGlyphsPerState() throws {
        let checking = try XCTUnwrap(UpdateIndicatorGlyph(state: .checking(.init(cancel: {}))))
        XCTAssertEqual(checking.symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(checking.tone, .foreground)
        XCTAssertEqual(checking.tooltipKey, "update.bar.checking")

        let found = try XCTUnwrap(UpdateIndicatorGlyph(state: available()))
        XCTAssertEqual(found.symbol, "arrow.down.circle")
        XCTAssertEqual(found.tone, .accent)
        XCTAssertEqual(found.tooltipKey, "update.bar.available")

        XCTAssertEqual(UpdateIndicatorGlyph(state: available(stage: .downloaded))?.tooltipKey, "update.bar.downloaded")

        let downloading = try XCTUnwrap(UpdateIndicatorGlyph(state: .downloading(.init(cancel: {}, version: "9.9.9", expectedLength: 200, progress: 50))))
        XCTAssertNil(downloading.symbol)
        XCTAssertEqual(downloading.ring!, 0.25, accuracy: 0.001)
        XCTAssertEqual(downloading.tooltipArguments, ["9.9.9", "25"])

        let staged = try XCTUnwrap(UpdateIndicatorGlyph(state: .installing(.init(isAutoUpdate: true, version: "9.9.9", restart: {}, later: {}, skip: nil))))
        XCTAssertEqual(staged.symbol, "power.circle")
        XCTAssertEqual(staged.tooltipKey, "update.bar.installing")

        XCTAssertEqual(UpdateIndicatorGlyph(state: .notFound(.init()))?.symbol, "checkmark.circle")

        let failed = try XCTUnwrap(UpdateIndicatorGlyph(state: .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {}))))
        XCTAssertEqual(failed.symbol, "exclamationmark.triangle")
        XCTAssertEqual(failed.tone, .alert)
    }

    func testEveryTooltipKeyExistsInBothCatalogs() {
        let states: [UpdateState] = [
            .checking(.init(cancel: {})), available(), available(stage: .downloaded),
            .downloading(.init(cancel: {}, version: nil, expectedLength: nil, progress: 0)),
            .extracting(.init(version: nil, progress: 0)),
            .installing(.init(isAutoUpdate: true, version: nil, restart: {}, later: {}, skip: nil)),
            .notFound(.init()),
            .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {})),
        ]
        for state in states {
            let key = UpdateIndicatorGlyph(state: state)!.tooltipKey
            XCTAssertNotNil(Localization.shared.catalog(.en).strings[key], key)
            XCTAssertNotNil(Localization.shared.catalog(.zh).strings[key], key)
        }
    }

    func testTheItemHidesWhenIdleAndFitsTheBarOtherwise() {
        let model = UpdateViewModel()
        func host() -> NSView {
            NSHostingView(rootView: UpdateIndicator(model: model, onClick: {})
                .environmentObject(ThemeManager())
                .environmentObject(Localization.shared))
        }
        XCTAssertEqual(host().fittingSize.width, 0, "idle draws nothing")
        model.state = available()
        let visible = host().fittingSize
        XCTAssertGreaterThan(visible.width, 0)
        XCTAssertLessThanOrEqual(visible.height, StatusBarView.height)
        model.state = .downloading(.init(cancel: {}, version: "9.9.9", expectedLength: 10, progress: 5))
        XCTAssertLessThanOrEqual(host().fittingSize.height, StatusBarView.height, "the ring fits too")
    }

    func testTheLaunchOverrideParsesTheFeedURL() {
        let fromArgument = AppDelegate.LaunchOverrides(
            arguments: ["QuickTerm", "--update-feed-url", "https://example.invalid/appcast.xml"], environment: [:])
        XCTAssertEqual(fromArgument.updateFeedURL?.absoluteString, "https://example.invalid/appcast.xml")
        let fromEnvironment = AppDelegate.LaunchOverrides(
            arguments: ["QuickTerm"], environment: ["QUICKTERM_UPDATE_FEED_URL": "https://example.invalid/env.xml"])
        XCTAssertEqual(fromEnvironment.updateFeedURL?.absoluteString, "https://example.invalid/env.xml")
        XCTAssertNil(AppDelegate.LaunchOverrides(arguments: ["QuickTerm"], environment: [:]).updateFeedURL)
        XCTAssertEqual(AppDelegate.LaunchOverrides.switches.count, 4)
    }

    func testTheSessionOwnsTheControllerAndAppliesTheConfig() throws {
        let session = try XCTUnwrap((NSApp.delegate as? AppDelegate)?.session)
        XCTAssertNil(session.updates.updater, "the test host never has a Sparkle updater")
        let before = session.settings
        defer { session.apply(before) }
        session.apply(ConfigStore.parse("[updates]\ncheck = false\ninstall = true\n"))
        XCTAssertEqual(session.updates.settings, UpdateSettings(check: false, install: true))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateIndicatorTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile errors (`UpdateIndicatorGlyph`, `session.updates`, `updateFeedURL` missing).

- [ ] **Step 3: Create the strings table in both languages**

`Resources/en.lproj/Update.strings`:

```
/* QuickTerm — English (base) UI strings for the updater (Sources/Update/).
 *
 * ONE AREA = ONE TABLE. Every `<Area>.strings` inside a `.lproj` is loaded and merged at
 * runtime; a key declared in two tables fails LocalizationTests. English is the development
 * language: every key MUST exist here. Rules (scripts/check-localization.py,
 * Tests/LocalizationTests.swift): whole sentences only; positional %1$@ only, a literal percent
 * sign is %%; keys lowercase, dot separated, area first. NSAlert renders values verbatim.
 */

/* MARK: - status-bar indicator (Sources/Update/UpdateIndicator.swift); %1$@ = version, %2$@ = percent */

"update.bar.checking" = "Checking for updates…";
"update.bar.available" = "QuickTerm %1$@ is available";
"update.bar.downloaded" = "QuickTerm %1$@ is downloaded";
"update.bar.downloading" = "Downloading %1$@: %2$@%%";
"update.bar.extracting" = "Preparing %1$@…";
"update.bar.installing" = "Quit or restart to finish updating to %1$@";
"update.bar.up-to-date" = "You're up to date";
"update.bar.error" = "Update failed";
```

`Resources/zh-Hans.lproj/Update.strings`:

```
/* QuickTerm — Simplified Chinese UI strings for the updater (Sources/Update/).
 *
 * Same key set as en.lproj/Update.strings (Tests/LocalizationTests.swift pins that). Positional
 * arguments (%1$@, %2$@ …) may be reordered; the SET of indices must match the English value.
 */

/* MARK: - status-bar indicator (Sources/Update/UpdateIndicator.swift) */

"update.bar.checking" = "正在检查更新…";
"update.bar.available" = "QuickTerm %1$@ 可用";
"update.bar.downloaded" = "QuickTerm %1$@ 已下载";
"update.bar.downloading" = "正在下载 %1$@：%2$@%%";
"update.bar.extracting" = "正在准备 %1$@…";
"update.bar.installing" = "退出或重启以完成更新到 %1$@";
"update.bar.up-to-date" = "已是最新版本";
"update.bar.error" = "更新失败";
```

- [ ] **Step 4: Create `Sources/Update/UpdateIndicator.swift`**

```swift
import SwiftUI

/// What the status bar draws for one update state: a glyph or a progress ring, its colour and its
/// tooltip. Pure, so the mapping is testable without a view.
struct UpdateIndicatorGlyph: Equatable {
    enum Tone: Equatable { case foreground, accent, alert }

    var symbol: String?
    /// 0…1 draws a ring instead of a symbol.
    var ring: Double?
    var tone: Tone
    var tooltipKey: String
    var tooltipArguments: [String]

    init?(state: UpdateState) {
        switch state {
        case .idle:
            return nil
        case .checking:
            self.init(symbol: "arrow.triangle.2.circlepath", tone: .foreground, key: "update.bar.checking")
        case .updateAvailable(let available):
            self.init(symbol: "arrow.down.circle", tone: .accent,
                      key: available.stage == .downloaded ? "update.bar.downloaded" : "update.bar.available",
                      arguments: [available.version])
        case .downloading(let downloading):
            let fraction = downloading.fraction ?? 0
            self.init(ring: fraction, tone: .accent, key: "update.bar.downloading",
                      arguments: [downloading.version ?? "", String(Int((fraction * 100).rounded()))])
        case .extracting(let extracting):
            self.init(ring: extracting.progress, tone: .accent, key: "update.bar.extracting",
                      arguments: [extracting.version ?? ""])
        case .installing(let installing):
            self.init(symbol: "power.circle", tone: .accent, key: "update.bar.installing",
                      arguments: [installing.version ?? ""])
        case .notFound:
            self.init(symbol: "checkmark.circle", tone: .foreground, key: "update.bar.up-to-date")
        case .error:
            self.init(symbol: "exclamationmark.triangle", tone: .alert, key: "update.bar.error")
        }
    }

    private init(symbol: String? = nil, ring: Double? = nil, tone: Tone, key: String,
                 arguments: [String] = []) {
        self.symbol = symbol
        self.ring = ring
        self.tone = tone
        self.tooltipKey = key
        self.tooltipArguments = arguments
    }
}

/// The updater's item in the status bar's right cluster: hidden when idle, otherwise one glyph in
/// the bar's monochrome style, or a progress ring. Text is read through `i18n` at render time so
/// a language change re-labels it.
struct UpdateIndicator: View {
    @ObservedObject var model: UpdateViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject private var i18n: Localization
    let onClick: () -> Void

    var body: some View {
        if let glyph = UpdateIndicatorGlyph(state: model.state) {
            let label = i18n.string(glyph.tooltipKey, glyph.tooltipArguments)
            Button { onClick() } label: {
                Group {
                    if let fraction = glyph.ring {
                        ProgressRing(fraction: fraction)
                    } else if let symbol = glyph.symbol {
                        Image(systemName: symbol)
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(colour(glyph.tone))
            .help(label)
            .accessibilityLabel(label)
        }
    }

    private func colour(_ tone: UpdateIndicatorGlyph.Tone) -> Color {
        switch tone {
        case .foreground: theme.foreground
        case .accent: theme.accent
        case .alert: theme.alert
        }
    }
}

/// A 12 pt ring: the track at 30 % and the arc from twelve o'clock.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 1.5).opacity(0.3)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}
```

- [ ] **Step 5: Give the session the controller**

`Sources/Windowing/AppSession.swift`: after `let stats = SystemStatsService()` add:

```swift
    /// The updater (Sparkle behind a custom driver). Created by AppDelegate before the session, so
    /// the gate decides once; every screen's status bar observes `updates.viewModel`.
    let updates: UpdateController
```

Change the initializer signature and body:

```swift
    init(screens: ScreenRegistry, themeManager: ThemeManager, stateURL: URL? = nil,
         controlSocketPath: String? = nil, updates: UpdateController = UpdateController(enabled: false)) {
        self.screens = screens
        self.themeManager = themeManager
        self.updates = updates
```

In `applyGlobalConfig`, right after `NoticeCenter.shared.settings = NoticeSettings(settings)` add:

```swift
        // The updater's two switches, same pattern: one reload, one push. Writes Sparkle's flags
        // when the updater exists, stores them otherwise.
        updates.apply(UpdateSettings(settings))
```

- [ ] **Step 6: Create the controller at launch and start it**

`Sources/App/AppDelegate.swift`, in `LaunchOverrides`: add the property after `controlSocket`:

```swift
        /// `--update-feed-url` / `QUICKTERM_UPDATE_FEED_URL` (Debug builds only, for the E2E test)
        var updateFeed: String?
```

Add the fourth switch to `switches`:

```swift
            ("--update-feed-url", "QUICKTERM_UPDATE_FEED_URL", \.updateFeed),
```

After `var controlSocketPath: String? { Self.expand(controlSocket) }` add:

```swift
        var updateFeedURL: URL? { updateFeed.flatMap { URL(string: $0) } }
```

In `applicationDidFinishLaunching`, replace the `let session = AppSession(` construction with:

```swift
        // The updater: the gate decides once per launch (docs/superpowers/specs/2026-09-25-auto-update-design.md §8).
        // A Debug build only updates against an explicit feed override, so a build in DerivedData is
        // never replaced by a release DMG; Release builds ignore the override.
        let feedOverride: URL? = UpdateController.isDebugBuild ? overrides.updateFeedURL : nil
        let updates = UpdateController(
            enabled: UpdateController.isEnabled(
                isRunningTests: Self.isRunningTests,
                hasPublicKey: UpdateController.hasPublicKey(in: .main),
                isDebugBuild: UpdateController.isDebugBuild,
                feedOverride: feedOverride),
            feedOverride: feedOverride)
        let session = AppSession(
            screens: screens, themeManager: themeManager,
            stateURL: overrides.stateURL,
            controlSocketPath: overrides.controlSocketPath,
            updates: updates)
```

At the end of `applicationDidFinishLaunching`, after `NSApp.activate(ignoringOtherApps: true)` add:

```swift
        // Last: the updater. It re-applies the settings loadInitialConfig() stored and, when checks
        // are on, checks once now (Sparkle's own scheduler would wait for the daily interval).
        session.updates.start()
        #if DEBUG
        // QUICKTERM_UPDATE_SIMULATE=happyPath|notFound|error|slowDownload|cancelDuringDownload|
        // cancelDuringChecking|staged|autoUpdate drives the indicator and the sheet without a server.
        if let scenario = ProcessInfo.processInfo.environment["QUICKTERM_UPDATE_SIMULATE"].flatMap(UpdateSimulator.init(rawValue:)),
           !Self.isRunningTests {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { scenario.simulate(with: session.updates.viewModel) }
        }
        #endif
```

- [ ] **Step 7: Thread the view model into the bar**

`Sources/Windowing/MainWindowController.swift`: after `var stats: SystemStatsService { session.stats }` add:

```swift
    /// The updater's state, injected into RootView next to `stats`.
    var updates: UpdateController { session.updates }
```

In the `RootView(` construction, change `model: model, ghostty: ghostty, stats: stats,` to `model: model, ghostty: ghostty, stats: stats, updates: updates.viewModel,` and after the `onPanelChoose:` argument add:

```swift
            onUpdateClick: { [weak self] in self?.session.updates.showSheet() })
```

(keep `onPanelChoose: { … }` followed by a comma).

`Sources/Windowing/RootView.swift`: after `let stats: SystemStatsService` add `let updates: UpdateViewModel`; after `let onPanelChoose: (Int) -> Void` add:

```swift
    /// A click on the update indicator in the status bar
    let onUpdateClick: () -> Void
```

In `content`, change the `StatusBarView(` call to:

```swift
                StatusBarView(
                    model: model, stats: stats, updates: updates,
                    onSelectWorkspace: onSelectWorkspace,
                    onRenameWorkspace: onRenameWorkspace,
                    onToggleMute: { [weak stats] in stats?.toggleMute() },
                    onUpdateClick: onUpdateClick)
```

`Sources/StatusBar/StatusBarView.swift`: line 4 becomes `/// Left: logo + workspace pills. Center: clock. Right: update indicator (when there is one), cpu, network, volume, battery.` After `@ObservedObject var stats: SystemStatsService` add `@ObservedObject var updates: UpdateViewModel`; after `let onToggleMute: () -> Void` add `let onUpdateClick: () -> Void`. In `rightSection`, make the update item the **first** child of `HStack(spacing: 14)`:

```swift
    private var rightSection: some View {
        HStack(spacing: 14) {
            // Leftmost on purpose: the four system items keep their places when it comes and goes.
            UpdateIndicator(model: updates, onClick: onUpdateClick)
            HStack(spacing: 3) {
```

`Sources/StatusBar/WorkspacePill.swift` line 9: change `on the right cpu / network / volume / battery.` to `on the right the update indicator (when there is one), cpu / network / volume / battery.`

- [ ] **Step 8: Regenerate, lint and run the tests**

Run: `xcodegen generate && python3 scripts/check-localization.py && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateIndicatorTests -only-testing:QuickTermTests/LocalizationTests -only-testing:QuickTermTests/ConfigHotReloadTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`. If `check-localization.py` reports a key with no call site, the `i18n.string(glyph.tooltipKey, …)` indirection is invisible to the scanner: add a doc comment block in `UpdateIndicator.swift` listing the keys as literal calls the scanner sees, e.g. a private static `keys` array of `"update.bar.checking"` … referenced through `L(` is not needed — the scanner matches the string literal inside `i18n(`/`L(` only, so add:

```swift
    /// Every key the glyph mapping can produce, spelled out for the catalog lint and the tests.
    static let tooltipKeys: [String] = [
        L("update.bar.checking"), L("update.bar.available"), L("update.bar.downloaded"),
        L("update.bar.downloading", "", ""), L("update.bar.extracting", ""),
        L("update.bar.installing", ""), L("update.bar.up-to-date"), L("update.bar.error"),
    ]
```

inside `UpdateIndicatorGlyph` (evaluated lazily, never at startup cost worth noting).

- [ ] **Step 9: Commit**

```bash
git add Sources/Update/UpdateIndicator.swift Resources/en.lproj/Update.strings Resources/zh-Hans.lproj/Update.strings Sources/Windowing/AppSession.swift Sources/App/AppDelegate.swift Sources/Windowing/MainWindowController.swift Sources/Windowing/RootView.swift Sources/StatusBar/StatusBarView.swift Sources/StatusBar/WorkspacePill.swift Tests/UpdateIndicatorTests.swift
git commit -m "feat(update): the status-bar indicator, the session-owned controller and the launch gate

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `UpdateSheet`

Spec §4 (sheet rules, buttons), §3 (Later / Skip / Cancel semantics), §6 (notes in the sheet), §9 (strings).

**Files:**
- Create: `Sources/Update/UpdateSheet.swift`
- Modify: `Sources/App/InfoAlert.swift` (return the text view), `Sources/Windowing/AppSession.swift` (own the sheet, wire `showSheet`), `Resources/en.lproj/Update.strings`, `Resources/zh-Hans.lproj/Update.strings` (sheet keys)
- Test: `Tests/UpdateSheetTests.swift`

**Interfaces:**
- Consumes: Task 3 `UpdateState`, Task 4 `UpdateController` (`installUpdate`, `requestRelaunch`, `settings`, `showSheet`), Task 6 `ReleaseNotes.Loader`, `NSAlert.setScrollableBody(_:intro:width:minLines:maxLines:)` from `Sources/App/InfoAlert.swift`.
- Produces: `@MainActor final class UpdateSheet { init(controller:notes:currentVersion:); func present(); func dismiss(); static func buttons(for:installMode:) -> [Button]; static func makeAlert(for:currentVersion:language:) -> Built? }`, `UpdateSheet.Button { kind: Kind (.install/.later/.skip/.restart/.cancel/.retry/.ok), keyEquivalent: String }`, `AppSession.updateSheet`.

- [ ] **Step 1: Write the failing test**

`Tests/UpdateSheetTests.swift`:

```swift
import AppKit
import Sparkle
import XCTest
@testable import QuickTerm

/// The sheet's buttons per state, what each one replies, and that a state change takes it down.
@MainActor
final class UpdateSheetTests: XCTestCase {
    private var controller: UpdateController!
    private var sheet: UpdateSheet!

    override func setUp() {
        super.setUp()
        controller = UpdateController(enabled: false)
        sheet = UpdateSheet(controller: controller, notes: ReleaseNotes.Loader(), currentVersion: "1.6.7")
    }

    private func available(userInitiated: Bool = false, stage: UpdateState.UpdateAvailable.Stage = .notDownloaded,
                           reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void = { _ in }) -> UpdateState {
        .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), stage: stage, userInitiated: userInitiated, reply: reply))
    }

    private func kinds(_ state: UpdateState, install: Bool = false) -> [UpdateSheet.Button.Kind] {
        UpdateSheet.buttons(for: state, installMode: install).map(\.kind)
    }

    func testButtonsPerState() {
        XCTAssertEqual(kinds(.checking(.init(cancel: {}))), [.cancel])
        XCTAssertEqual(kinds(available()), [.install, .later, .skip])
        XCTAssertEqual(kinds(available(stage: .downloaded)), [.install, .later, .skip])
        XCTAssertEqual(kinds(.downloading(.init(cancel: {}, version: nil, expectedLength: nil, progress: 0))), [.cancel])
        XCTAssertEqual(kinds(.extracting(.init(version: nil, progress: 0))), [.ok])
        XCTAssertEqual(kinds(.installing(.init(isAutoUpdate: true, version: nil, restart: {}, later: {}, skip: {}))), [.restart, .later, .skip])
        XCTAssertEqual(kinds(.installing(.init(isAutoUpdate: true, version: nil, restart: {}, later: {}, skip: nil))), [.restart, .later])
        XCTAssertEqual(kinds(.error(.init(error: NSError(domain: "SUSparkleErrorDomain", code: 1005), kind: .translocated, retry: {}, dismiss: {}))), [.ok])
        XCTAssertEqual(kinds(.error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {}))), [.retry, .ok])
        XCTAssertTrue(kinds(.idle).isEmpty)
        XCTAssertTrue(kinds(.notFound(.init())).isEmpty)
    }

    func testTheFirstButtonIsReturnAndLaterOrCancelIsEscape() {
        let buttons = UpdateSheet.buttons(for: available(), installMode: false)
        XCTAssertEqual(buttons.map(\.keyEquivalent), ["\r", "\u{1b}", ""])
        XCTAssertEqual(UpdateSheet.buttons(for: .checking(.init(cancel: {})), installMode: false).map(\.keyEquivalent), ["\u{1b}"])
        let failed = UpdateSheet.buttons(for: .error(.init(error: NSError(domain: "x", code: 1), kind: .other, retry: {}, dismiss: {})), installMode: false)
        XCTAssertEqual(failed.map(\.keyEquivalent), ["\r", "\u{1b}"])
    }

    func testMakeAlertUsesTheCatalogAndTheScrollableBody() throws {
        let built = try XCTUnwrap(UpdateSheet.makeAlert(for: available(), currentVersion: "1.6.7", language: .en))
        XCTAssertEqual(built.alert.buttons.map(\.title), [L("update.sheet.button.install"), L("update.sheet.button.later"), L("update.sheet.button.skip")])
        XCTAssertNotNil(built.body, "the notes area exists before the notes arrive")
        XCTAssertEqual(built.body?.string, L("update.sheet.notes.loading"))
        let staged = try XCTUnwrap(UpdateSheet.makeAlert(for: .installing(.init(isAutoUpdate: true, version: "1.6.8", restart: {}, later: {}, skip: nil)), currentVersion: "1.6.7", language: .en))
        XCTAssertEqual(staged.alert.messageText, L("update.sheet.installing.title", "1.6.8"))
        XCTAssertNil(UpdateSheet.makeAlert(for: .idle, currentVersion: "1.6.7", language: .en))
        XCTAssertNil(UpdateSheet.makeAlert(for: .notFound(.init()), currentVersion: "1.6.7", language: .en))
    }

    func testLaterInCheckOnlyModeHoldsTheReply() {
        var replies: [SPUUserUpdateChoice] = []
        let state = available { replies.append($0) }
        controller.apply(UpdateSettings(check: true, install: false))
        controller.viewModel.state = state
        sheet.perform(.later, for: state)
        XCTAssertTrue(replies.isEmpty, "no reply: Sparkle keeps the session, the icon stays")
        guard case .updateAvailable = controller.viewModel.state else { return XCTFail("state untouched") }
    }

    func testLaterInInstallModeDismisses() {
        var replies: [SPUUserUpdateChoice] = []
        let state = available { replies.append($0) }
        controller.apply(UpdateSettings(check: true, install: true))
        controller.viewModel.state = state
        sheet.perform(.later, for: state)
        XCTAssertEqual(replies, [.dismiss], "the scheduler downloads and stages it unattended")
    }

    func testInstallGoesThroughTheControllerAndSkipReplies() {
        var replies: [SPUUserUpdateChoice] = []
        let state = available { replies.append($0) }
        controller.viewModel.state = state
        sheet.perform(.install, for: state)
        XCTAssertEqual(replies, [.install])
        XCTAssertTrue(controller.relaunchRequested)
        controller.viewModel.state = .idle
        let again = available { replies.append($0) }
        controller.viewModel.state = again
        sheet.perform(.skip, for: again)
        XCTAssertEqual(replies.last, .skip)
    }

    func testRestartNowAsksForTheRelaunch() {
        var restarted = false
        let state = UpdateState.installing(.init(isAutoUpdate: true, version: "1.6.8", restart: { restarted = true }, later: {}, skip: nil))
        controller.viewModel.state = state
        sheet.perform(.restart, for: state)
        XCTAssertTrue(restarted)
        XCTAssertTrue(controller.relaunchRequested)
    }

    func testAStateChangeTakesTheSheetDown() {
        controller.viewModel.state = .checking(.init(cancel: {}))
        sheet.present()
        XCTAssertTrue(sheet.isPresented)
        controller.viewModel.state = .idle
        XCTAssertFalse(sheet.isPresented)
    }

    func testAManualFindOpensTheSheetByItself() {
        controller.viewModel.state = available(userInitiated: true)
        XCTAssertTrue(sheet.isPresented)
        sheet.dismiss()
        controller.viewModel.state = .idle
        controller.viewModel.state = available(userInitiated: false)
        XCTAssertFalse(sheet.isPresented, "a scheduled find only lights the icon")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateSheetTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile errors (`UpdateSheet` not found).

- [ ] **Step 3: Let `setScrollableBody` hand back its text view**

`Sources/App/InfoAlert.swift`: change the signature to

```swift
    @MainActor @discardableResult
    func setScrollableBody(_ text: String, intro: String? = nil, width: CGFloat = 546,
                           minLines: Int = 7, maxLines: Int = 26) -> NSTextView? {
```

return `nil` from the `guard let layout … else { return nil }`, and end both branches (`accessoryView = scroll` and `accessoryView = stack`) with `return textView`. Existing callers ignore the result.

- [ ] **Step 4: Add the sheet strings to both tables**

Append to `Resources/en.lproj/Update.strings`:

```

/* MARK: - the sheet (Sources/Update/UpdateSheet.swift); %1$@ = version unless said otherwise */

"update.sheet.checking.title" = "Checking for updates…";
"update.sheet.available.title" = "QuickTerm %1$@ is available";
/* %1$@ = the running version, %2$@ = the new version, %3$@ = its size, %4$@ = its release date */
"update.sheet.available.intro" = "You have %1$@. Version %2$@, %3$@, released %4$@.";
/* %1$@ = the running version, %2$@ = the new version, %3$@ = its size */
"update.sheet.available.intro-undated" = "You have %1$@. Version %2$@, %3$@.";
"update.sheet.downloaded.intro" = "Version %1$@ is already downloaded.";
/* %1$@ = the release page URL */
"update.sheet.notes.github" = "Full notes on GitHub: %1$@";
"update.sheet.notes.loading" = "Loading release notes…";
"update.sheet.notes.unavailable" = "The release notes could not be loaded.";
"update.sheet.downloading.title" = "Downloading QuickTerm %1$@…";
"update.sheet.extracting.title" = "Preparing QuickTerm %1$@…";
"update.sheet.installing.title" = "QuickTerm %1$@ is ready";
"update.sheet.installing.intro" = "Quit or restart QuickTerm to finish the update. Restart Now installs it and brings QuickTerm back.";
"update.sheet.error.title" = "Update failed";
"update.sheet.translocated.title" = "QuickTerm can't update from here";
"update.sheet.translocated.intro" = "Move QuickTerm to the Applications folder, then check for updates again.";
"update.sheet.button.install" = "Install and Relaunch";
"update.sheet.button.later" = "Later";
"update.sheet.button.skip" = "Skip This Version";
"update.sheet.button.restart" = "Restart Now";
"update.sheet.button.retry" = "Retry";
```

Append to `Resources/zh-Hans.lproj/Update.strings`:

```

/* MARK: - the sheet (Sources/Update/UpdateSheet.swift) */

"update.sheet.checking.title" = "正在检查更新…";
"update.sheet.available.title" = "QuickTerm %1$@ 可用";
"update.sheet.available.intro" = "当前 %1$@。新版本 %2$@，%3$@，发布于 %4$@。";
"update.sheet.available.intro-undated" = "当前 %1$@。新版本 %2$@，%3$@。";
"update.sheet.downloaded.intro" = "版本 %1$@ 已下载完成。";
"update.sheet.notes.github" = "完整说明见 GitHub：%1$@";
"update.sheet.notes.loading" = "正在加载更新说明…";
"update.sheet.notes.unavailable" = "更新说明加载失败。";
"update.sheet.downloading.title" = "正在下载 QuickTerm %1$@…";
"update.sheet.extracting.title" = "正在准备 QuickTerm %1$@…";
"update.sheet.installing.title" = "QuickTerm %1$@ 已就绪";
"update.sheet.installing.intro" = "退出或重启 QuickTerm 即可完成更新。「现在重启」会立即安装并重新打开 QuickTerm。";
"update.sheet.error.title" = "更新失败";
"update.sheet.translocated.title" = "QuickTerm 无法从当前位置更新";
"update.sheet.translocated.intro" = "请把 QuickTerm 移到「应用程序」文件夹，再重新检查更新。";
"update.sheet.button.install" = "立即更新并重启";
"update.sheet.button.later" = "稍后";
"update.sheet.button.skip" = "跳过此版本";
"update.sheet.button.restart" = "现在重启";
"update.sheet.button.retry" = "重试";
```

- [ ] **Step 5: Create `Sources/Update/UpdateSheet.swift`**

```swift
import AppKit
import Combine

/// The window behind a click on the update indicator (and behind a manual check that found
/// something): the house info alert, one per state, taken down when the state moves on.
///
/// A sheet on the key window when there is one, `runModal` otherwise — the same rule the
/// workspace-title prompt follows. The text is read through `L()` when the alert is built.
@MainActor
final class UpdateSheet {
    struct Button: Equatable {
        enum Kind: Equatable { case install, later, skip, restart, cancel, retry, ok }
        let kind: Kind
        let keyEquivalent: String

        var titleKey: String {
            switch kind {
            case .install: "update.sheet.button.install"
            case .later: "update.sheet.button.later"
            case .skip: "update.sheet.button.skip"
            case .restart: "update.sheet.button.restart"
            case .cancel: "window.button.cancel"
            case .retry: "update.sheet.button.retry"
            case .ok: "window.button.ok"
            }
        }
    }

    /// An alert ready to present: its buttons in order, the progress bar and the notes area when
    /// the state has them.
    struct Built {
        let alert: NSAlert
        let buttons: [Button]
        let progress: NSProgressIndicator?
        let body: NSTextView?
    }

    private unowned let controller: UpdateController
    private let notes: ReleaseNotes.Loader
    private let currentVersion: String
    private var built: Built?
    private var presentedState: UpdateState?
    private var hostWindow: NSWindow?
    private var runningModal = false
    private var stateCancellable: AnyCancellable?

    init(controller: UpdateController, notes: ReleaseNotes.Loader = .init(),
         currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") {
        self.controller = controller
        self.notes = notes
        self.currentVersion = currentVersion
        stateCancellable = controller.viewModel.$state.dropFirst().sink { [weak self] state in
            self?.stateDidChange(state)
        }
    }

    var isPresented: Bool { built != nil }

    /// A click on the indicator, or Sparkle's showUpdateInFocus.
    func present() {
        present(controller.viewModel.state)
    }

    // MARK: Buttons

    /// The buttons a state gets, first = default (Return). Pure, so the table is testable.
    static func buttons(for state: UpdateState, installMode: Bool) -> [Button] {
        switch state {
        case .idle, .notFound:
            return []
        case .checking, .downloading:
            return [Button(kind: .cancel, keyEquivalent: "\u{1b}")]
        case .updateAvailable:
            return [Button(kind: .install, keyEquivalent: "\r"),
                    Button(kind: .later, keyEquivalent: "\u{1b}"),
                    Button(kind: .skip, keyEquivalent: "")]
        case .extracting:
            return [Button(kind: .ok, keyEquivalent: "\r")]
        case .installing(let installing):
            var buttons = [Button(kind: .restart, keyEquivalent: "\r"),
                           Button(kind: .later, keyEquivalent: "\u{1b}")]
            if installing.skip != nil { buttons.append(Button(kind: .skip, keyEquivalent: "")) }
            return buttons
        case .error(let failure):
            if failure.kind == .translocated { return [Button(kind: .ok, keyEquivalent: "\r")] }
            return [Button(kind: .retry, keyEquivalent: "\r"), Button(kind: .ok, keyEquivalent: "\u{1b}")]
        }
    }

    /// What a button does. Later in check-only mode deliberately replies nothing: Sparkle keeps
    /// the session open and the icon stays; in install mode it replies dismiss so the scheduler
    /// downloads and stages the update unattended.
    func perform(_ kind: Button.Kind, for state: UpdateState) {
        switch (kind, state) {
        case (.install, .updateAvailable):
            controller.installUpdate()
        case (.later, .updateAvailable(let available)):
            if controller.settings.install { available.reply(.dismiss) }
        case (.skip, .updateAvailable(let available)):
            available.reply(.skip)
        case (.restart, .installing(let installing)):
            controller.requestRelaunch(installing.restart)
        case (.later, .installing(let installing)):
            installing.later()
        case (.skip, .installing(let installing)):
            installing.skip?()
        case (.cancel, .checking(let checking)):
            checking.cancel()
        case (.cancel, .downloading(let downloading)):
            downloading.cancel()
        case (.retry, .error(let failure)):
            failure.retry()
        case (.ok, .error(let failure)):
            failure.dismiss()
        default:
            break
        }
    }

    // MARK: Building

    static func makeAlert(for state: UpdateState, currentVersion: String, language: AppLanguage) -> Built? {
        let buttons = buttons(for: state, installMode: false)
        guard !buttons.isEmpty else { return nil }
        let alert = NSAlert()
        alert.alertStyle = .informational
        var progress: NSProgressIndicator?
        var body: NSTextView?

        switch state {
        case .checking:
            alert.messageText = L("update.sheet.checking.title")
        case .updateAvailable(let available):
            alert.messageText = L("update.sheet.available.title", available.version)
            let size = ByteCountFormatter.string(fromByteCount: Int64(available.contentLength), countStyle: .file)
            var intro: String
            if available.stage == .downloaded {
                intro = L("update.sheet.downloaded.intro", available.version)
            } else if let date = available.date {
                intro = L("update.sheet.available.intro", currentVersion, available.version, size,
                          date.formatted(date: .abbreviated, time: .omitted))
            } else {
                intro = L("update.sheet.available.intro-undated", currentVersion, available.version, size)
            }
            if let page = ReleaseNotes.releasePageURL(version: available.version) {
                intro += "\n" + L("update.sheet.notes.github", page.absoluteString)
            }
            body = alert.setScrollableBody(L("update.sheet.notes.loading"), intro: intro, minLines: 6)
        case .downloading(let downloading):
            alert.messageText = L("update.sheet.downloading.title", downloading.version ?? "")
            progress = Self.progressIndicator(fraction: downloading.fraction)
            alert.accessoryView = progress
        case .extracting(let extracting):
            alert.messageText = L("update.sheet.extracting.title", extracting.version ?? "")
            progress = Self.progressIndicator(fraction: extracting.progress)
            alert.accessoryView = progress
        case .installing(let installing):
            alert.messageText = L("update.sheet.installing.title", installing.version ?? "")
            alert.informativeText = L("update.sheet.installing.intro")
        case .error(let failure):
            if failure.kind == .translocated {
                alert.messageText = L("update.sheet.translocated.title")
                alert.informativeText = L("update.sheet.translocated.intro")
            } else {
                alert.messageText = L("update.sheet.error.title")
                alert.setScrollableBody(failure.error.localizedDescription, minLines: 3, maxLines: 8)
            }
            alert.alertStyle = .warning
        case .idle, .notFound:
            return nil
        }

        for button in buttons {
            alert.addButton(withTitle: L(button.titleKey)).keyEquivalent = button.keyEquivalent
        }
        return Built(alert: alert, buttons: buttons, progress: progress, body: body)
    }

    private static func progressIndicator(fraction: Double?) -> NSProgressIndicator {
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.isIndeterminate = fraction == nil
        indicator.doubleValue = (fraction ?? 0) * 100
        if fraction == nil { indicator.startAnimation(nil) }
        return indicator
    }

    // MARK: Presenting

    private func present(_ state: UpdateState) {
        dismiss()
        guard let built = Self.makeAlert(for: state, currentVersion: currentVersion,
                                         language: Localization.shared.language) else { return }
        self.built = built
        presentedState = state
        if case .updateAvailable(let available) = state { loadNotes(for: available, into: built.body) }

        let buttons = built.buttons
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.built?.alert === built.alert else { return }
            self.built = nil
            self.presentedState = nil
            self.hostWindow = nil
            guard let index = Self.buttonIndex(response), buttons.indices.contains(index) else { return }
            self.perform(buttons[index].kind, for: state)
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            hostWindow = window
            built.alert.beginSheetModal(for: window) { respond($0) }
        } else {
            runningModal = true
            let response = built.alert.runModal()
            runningModal = false
            respond(response)
        }
    }

    private static func buttonIndex(_ response: NSApplication.ModalResponse) -> Int? {
        switch response {
        case .alertFirstButtonReturn: 0
        case .alertSecondButtonReturn: 1
        case .alertThirdButtonReturn: 2
        default: nil
        }
    }

    /// Takes the current alert down without replying to anything.
    func dismiss() {
        guard let built else { return }
        if let hostWindow {
            hostWindow.endSheet(built.alert.window, returnCode: .abort)
        } else if runningModal {
            NSApp.stopModal(withCode: .abort)
        }
        self.built = nil
        presentedState = nil
        hostWindow = nil
    }

    private func stateDidChange(_ state: UpdateState) {
        if let built, let presentedState, Self.sameCase(presentedState, state) {
            // Same question, new progress: update in place.
            switch state {
            case .downloading(let d):
                built.progress?.isIndeterminate = d.fraction == nil
                built.progress?.doubleValue = (d.fraction ?? 0) * 100
            case .extracting(let e):
                built.progress?.doubleValue = e.progress * 100
            default:
                break
            }
            self.presentedState = state
            return
        }
        dismiss()
        // A manual check that found something opens without a click; a scheduled one only lights
        // the icon.
        if case .updateAvailable(let available) = state, available.userInitiated {
            present(state)
        }
    }

    private static func sameCase(_ a: UpdateState, _ b: UpdateState) -> Bool {
        switch (a, b) {
        case (.checking, .checking), (.updateAvailable, .updateAvailable), (.downloading, .downloading),
             (.extracting, .extracting), (.installing, .installing), (.error, .error):
            return true
        default:
            return false
        }
    }

    private func loadNotes(for available: UpdateState.UpdateAvailable, into body: NSTextView?) {
        guard let body else { return }
        let version = available.version
        let fallback = available.appcastItem.itemDescription
        let language = Localization.shared.language
        Task { @MainActor [weak self, weak body] in
            let text = await self?.notes.notes(version: version, language: language, fallback: fallback)
            guard let body else { return }
            body.string = text ?? L("update.sheet.notes.unavailable")
        }
    }
}
```

`makeAlert` takes `language` only to make the dependency explicit for tests; `L()` reads `Localization.shared` itself.

- [ ] **Step 6: Own the sheet in the session and wire the click**

`Sources/Windowing/AppSession.swift`: after `let updates: UpdateController` add:

```swift
    /// The sheet behind the indicator; built lazily because it reads the bundle version.
    private(set) lazy var updateSheet = UpdateSheet(controller: updates)
```

At the end of `init`, add:

```swift
        updates.showSheet = { [weak self] in self?.updateSheet.present() }
```

- [ ] **Step 7: Regenerate, lint and run the tests**

Run: `xcodegen generate && python3 scripts/check-localization.py && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateSheetTests -only-testing:QuickTermTests/LocalizationTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`. `testAStateChangeTakesTheSheetDown` and `testAManualFindOpensTheSheetByItself` present a real sheet on the test host's window; if `NSApp.keyWindow` is nil there and `runModal` would block, the test host's main window is visible, so `NSApp.windows.first(where: { $0.isVisible })` is the host — keep that order in `present`.

- [ ] **Step 8: Commit**

```bash
git add Sources/Update/UpdateSheet.swift Sources/App/InfoAlert.swift Sources/Windowing/AppSession.swift Resources/en.lproj/Update.strings Resources/zh-Hans.lproj/Update.strings Tests/UpdateSheetTests.swift
git commit -m "feat(update): the update sheet with install, later, skip and restart

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Menu item, engine stub, menu validation and the quit bypass

Spec §1 goal 4, §8 (quit path), §10.

**Files:**
- Modify: `Sources/App/MainMenu.swift` (~line 42, after About), `Resources/en.lproj/Menus.strings` (~line 29), `Resources/zh-Hans.lproj/Menus.strings` (~line 16), `Sources/App/AppDelegate+Ghostty.swift` (line 7), `Sources/App/AppDelegate+Screens.swift` (`validateMenuItem` ~line 155), `Sources/App/AppDelegate.swift` (`shouldConfirmQuit` ~line 241, `applicationShouldTerminate` ~line 243)
- Test: `Tests/UpdateMenuTests.swift`

**Interfaces:**
- Consumes: Task 4 `UpdateController.checkForUpdates()`, `.canCheckForUpdates`, `.relaunchRequested`; Task 7 `AppSession.updates`.
- Produces: `@objc func AppDelegate.checkForUpdates(_ sender: Any?)` (already called with `nil` by `Ghostty.App.swift:884-889`), `static func AppDelegate.shouldConfirmQuit(openPaneCount: Int, relaunchRequested: Bool) -> Bool`.

- [ ] **Step 1: Write the failing test**

`Tests/UpdateMenuTests.swift`:

```swift
import AppKit
import XCTest
@testable import QuickTerm

/// The menu item, its validation without an updater, and the quit confirmation standing aside for
/// a relaunch.
@MainActor
final class UpdateMenuTests: XCTestCase {
    func testShouldConfirmQuitStandsAsideForARelaunch() {
        XCTAssertTrue(AppDelegate.shouldConfirmQuit(openPaneCount: 3, relaunchRequested: false))
        XCTAssertFalse(AppDelegate.shouldConfirmQuit(openPaneCount: 3, relaunchRequested: true))
        XCTAssertFalse(AppDelegate.shouldConfirmQuit(openPaneCount: 0, relaunchRequested: false))
    }

    func testTheAppMenuCarriesCheckForUpdatesAfterAbout() throws {
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let about = try XCTUnwrap(titles.firstIndex(of: L("menu.app.about")))
        XCTAssertEqual(titles[about + 1], L("menu.app.check-updates"))
        let item = appMenu.items[about + 1]
        XCTAssertEqual(item.action, #selector(AppDelegate.checkForUpdates(_:)))
        XCTAssertTrue(item.target === NSApp.delegate)
    }

    func testTheItemIsDisabledWithoutAnUpdater() throws {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let item = NSMenuItem(title: "x", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        XCTAssertFalse(delegate.validateMenuItem(item), "the test host has no Sparkle updater")
        // Calling it anyway is harmless.
        delegate.checkForUpdates(nil)
        XCTAssertTrue(delegate.session.updates.viewModel.state.isIdle)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateMenuTests 2>&1 | grep -E "error:|Test Case|\*\* TEST"`
Expected: compile error on `shouldConfirmQuit(openPaneCount:relaunchRequested:)` and `#selector(AppDelegate.checkForUpdates(_:))` (not `@objc`).

- [ ] **Step 3: The menu item and its strings**

`Sources/App/MainMenu.swift`, right after the `menu.app.about` item (before `appMenu.addItem(.separator())`):

```swift
        // Apple's convention: right under About. Validated through canCheckForUpdates (greyed out
        // without an updater, i.e. in the test host and in a Debug build without a feed override).
        let updatesItem = appMenu.addItem(withTitle: L("menu.app.check-updates"),
                                          action: #selector(AppDelegate.checkForUpdates(_:)),
                                          keyEquivalent: "")
        updatesItem.target = delegate
```

`Resources/en.lproj/Menus.strings`, after `"menu.app.about" = …;`:

```
"menu.app.check-updates" = "Check for Updates…";
```

`Resources/zh-Hans.lproj/Menus.strings`, after `"menu.app.about" = …;`:

```
"menu.app.check-updates" = "检查更新…";
```

- [ ] **Step 4: Replace the stub and validate the item**

`Sources/App/AppDelegate+Ghostty.swift` line 7 becomes:

```swift
    /// Check for Updates…: the menu item and the engine's `check_for_updates` keybind action
    /// (Ghostty.App.swift calls this with nil) both land here.
    @objc func checkForUpdates(_ sender: Any?) { session?.updates.checkForUpdates() }
```

`Sources/App/AppDelegate+Screens.swift`, in `validateMenuItem`, add a case before `default:`:

```swift
        case #selector(checkForUpdates(_:)):
            return session?.updates.canCheckForUpdates ?? false
```

- [ ] **Step 5: The quit bypass**

`Sources/App/AppDelegate.swift`: replace the static and its use:

```swift
    /// Quit semantics (from the user, 2026-09-04): with panes open, confirm; with none, quit
    /// straight away. A relaunch the user asked the updater for (Install and Relaunch, Restart
    /// Now) is Sparkle terminating the app on their behalf: no confirmation in front of it.
    /// Both the Cmd+Q menu item and the engine's quit action go through here.
    static func shouldConfirmQuit(openPaneCount: Int, relaunchRequested: Bool) -> Bool {
        !relaunchRequested && openPaneCount > 0
    }
```

and in `applicationShouldTerminate`:

```swift
        guard Self.shouldConfirmQuit(openPaneCount: open,
                                     relaunchRequested: session?.updates.relaunchRequested ?? false)
        else { return .terminateNow }
```

Search the tests for the old spelling: `grep -rn "shouldConfirmQuit(openPaneCount:" Tests` and add `relaunchRequested: false` to every existing call.

- [ ] **Step 6: Regenerate, lint and run the tests**

Run: `xcodegen generate && python3 scripts/check-localization.py && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/UpdateMenuTests -only-testing:QuickTermTests/LocalizationTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Sources/App/MainMenu.swift Resources/en.lproj/Menus.strings Resources/zh-Hans.lproj/Menus.strings Sources/App/AppDelegate+Ghostty.swift Sources/App/AppDelegate+Screens.swift Sources/App/AppDelegate.swift Tests/UpdateMenuTests.swift
git commit -m "feat(update): Check for Updates… in the app menu, and no quit confirmation in front of a relaunch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: The release pipeline

Spec §7 (one-time setup, pinning, per-release steps, operational rules), §6 (notes assets), §8, §10 (READMEs, porting notes).

**Files:**
- Create: `scripts/update-appcast.py`
- Modify: `scripts/make-release.sh` (rewritten below), `README.md`, `README.zh-CN.md`, `docs/porting-notes.md`
- Test: `python3 scripts/update-appcast.py --self-test`, `bash -n scripts/make-release.sh`, a dry run of `scripts/make-release.sh` (ad-hoc identity, no upload)

**Interfaces:**
- Consumes: the DMG, `.sha256`, `docs/releases/v<ver>.md` and `v<ver>.zh-CN.md`.
- Produces: `build/appcast.xml`, release assets `QuickTerm-<ver>.dmg`, `QuickTerm-<ver>.dmg.sha256`, `QuickTerm-<ver>-notes.md`, `QuickTerm-<ver>-notes.zh-CN.md`, `appcast.xml`; Task 6 reads the notes assets, Sparkle reads `appcast.xml` at `releases/latest/download/appcast.xml`.

- [ ] **Step 1: Write the appcast script with its self-test**

`scripts/update-appcast.py`:

```python
#!/usr/bin/env python3
"""Build the Sparkle appcast for one QuickTerm release.

    update-appcast.py --out build/appcast.xml --version 1.6.8 --build 24 --min-system 15.4.0 \
        --dmg-url https://github.com/dannyzhu/QuickTerm/releases/download/v1.6.8/QuickTerm-1.6.8.dmg \
        --length 81586712 --signature <edSignature> --notes docs/releases/v1.6.8.md \
        --notes-link https://github.com/dannyzhu/QuickTerm/releases/tag/v1.6.8 \
        (--previous build/appcast-previous.xml | --first-release)
    update-appcast.py --self-test

Rules (docs/superpowers/specs/2026-09-25-auto-update-design.md §7): the new build number must be
strictly greater than every build already in the feed (a forgotten CURRENT_PROJECT_VERSION bump
would otherwise publish an update no client is ever offered); an item with the same build is
replaced; a version string may not reappear under another build; the feed keeps the newest 15
items; pubDate is in the one shape Sparkle parses; the description carries the English notes as
Markdown text declared plain-text (QuickTerm's own driver flattens it, nothing else renders it).
Written with ElementTree, so no CDATA and no hand escaping.
"""

import argparse
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PUBDATE = "%a, %d %b %Y %H:%M:%S %z"
KEEP = 15
ET.register_namespace("sparkle", SPARKLE)


def q(name):
    return "{%s}%s" % (SPARKLE, name)


def empty_feed():
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "QuickTerm"
    ET.SubElement(channel, "link").text = "https://github.com/dannyzhu/QuickTerm"
    ET.SubElement(channel, "description").text = "QuickTerm updates"
    return ET.ElementTree(rss)


def build_of(item):
    element = item.find(q("version"))
    try:
        return int(element.text.strip()) if element is not None and element.text else None
    except ValueError:
        return None


def pubdate_of(item):
    element = item.find("pubDate")
    try:
        return datetime.strptime(element.text.strip(), PUBDATE) if element is not None and element.text else None
    except ValueError:
        return None


def merge(tree, version, build, min_system, dmg_url, length, signature, notes, notes_link, now):
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("error: the appcast has no <channel>")
    for item in channel.findall("item"):
        other = build_of(item)
        short = item.find(q("shortVersionString"))
        if other is not None and other > build:
            raise SystemExit("error: build %d is not greater than build %d already in the feed: "
                             "bump CURRENT_PROJECT_VERSION" % (build, other))
        if other is not None and other == build:
            channel.remove(item)
            continue
        if short is not None and short.text == version:
            raise SystemExit("error: version %s is already in the feed as build %s" % (version, other))
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "QuickTerm %s" % version
    ET.SubElement(item, "pubDate").text = now.strftime(PUBDATE)
    ET.SubElement(item, q("version")).text = str(build)
    ET.SubElement(item, q("shortVersionString")).text = version
    ET.SubElement(item, q("minimumSystemVersion")).text = min_system
    ET.SubElement(item, q("fullReleaseNotesLink")).text = notes_link
    ET.SubElement(item, "description", {q("descriptionFormat"): "plain-text"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": dmg_url,
        "length": str(length),
        "type": "application/x-apple-diskimage",
        q("edSignature"): signature,
    })
    children = list(channel)
    first_item = next((i for i, child in enumerate(children) if child.tag == "item"), len(children))
    channel.insert(first_item, item)
    # Newest first; an unparsable date counts as oldest; ties keep document order.
    oldest = datetime.min.replace(tzinfo=timezone.utc)
    ranked = sorted(enumerate(channel.findall("item")),
                    key=lambda pair: (pubdate_of(pair[1]) or oldest, -pair[0]), reverse=True)
    for _, old in ranked[KEEP:]:
        channel.remove(old)
    return tree


def write(tree, path):
    ET.indent(tree, space="  ")
    tree.write(path, xml_declaration=True, encoding="utf-8")


def self_test():
    def fixture(builds):
        tree = empty_feed()
        now = datetime(2026, 9, 1, tzinfo=timezone.utc)
        for i, build in enumerate(builds):
            merge(tree, "1.0.%d" % build, build, "15.4.0", "https://x/%d.dmg" % build, 1, "sig",
                  "notes %d" % build, "https://x/%d" % build, now + timedelta(days=i))
        return tree

    tree = fixture([23])
    merge(tree, "1.6.8", 24, "15.4.0", "https://x/24.dmg", 5, "s24", "## Notes", "https://x/24",
          datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc))
    items = tree.getroot().find("channel").findall("item")
    assert [build_of(i) for i in items] == [24, 23], "newest first"
    assert items[0].find("pubDate").text == "Wed, 30 Sep 2026 12:00:00 +0000", items[0].find("pubDate").text
    assert items[0].find("description").get(q("descriptionFormat")) == "plain-text"
    assert items[0].find("enclosure").get(q("edSignature")) == "s24"
    # Same build again: replaced, not duplicated.
    merge(tree, "1.6.8", 24, "15.4.0", "https://x/24b.dmg", 6, "s24b", "n", "https://x/24",
          datetime(2026, 10, 1, tzinfo=timezone.utc))
    items = tree.getroot().find("channel").findall("item")
    assert [build_of(i) for i in items] == [24, 23] and items[0].find("enclosure").get("length") == "6"
    # A build that is not greater fails.
    try:
        merge(fixture([23, 24]), "1.6.9", 24 - 2, "15.4.0", "https://x/22.dmg", 1, "s", "n", "https://x/22",
              datetime.now(timezone.utc))
        raise AssertionError("a lower build must fail")
    except SystemExit as error:
        assert "not greater" in str(error), error
    # The same version under another build fails.
    try:
        merge(fixture([23]), "1.0.23", 30, "15.4.0", "https://x/30.dmg", 1, "s", "n", "https://x/30",
              datetime.now(timezone.utc))
        raise AssertionError("a reused version must fail")
    except SystemExit as error:
        assert "already in the feed" in str(error), error
    # Pruning keeps the newest 15, and an unparsable date does not crash.
    big = fixture(list(range(1, 17)))
    channel = big.getroot().find("channel")
    channel.findall("item")[-1].find("pubDate").text = "not a date"
    merge(big, "2.0.0", 100, "15.4.0", "https://x/100.dmg", 1, "s", "n", "https://x/100",
          datetime(2027, 1, 1, tzinfo=timezone.utc))
    builds = [build_of(i) for i in channel.findall("item")]
    assert len(builds) == KEEP and builds[0] == 100 and 1 not in builds, builds
    # Round trip through a file.
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "appcast.xml")
        write(tree, path)
        again = ET.parse(path)
        assert [build_of(i) for i in again.getroot().find("channel").findall("item")] == [24, 23]
        assert "sparkle:version" in open(path, encoding="utf-8").read()
    print("update-appcast.py: self-test OK")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--out")
    parser.add_argument("--version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--min-system", default="15.4.0")
    parser.add_argument("--dmg-url")
    parser.add_argument("--length", type=int)
    parser.add_argument("--signature")
    parser.add_argument("--notes", help="path to the English release notes (Markdown)")
    parser.add_argument("--notes-link")
    parser.add_argument("--previous", help="the feed published with the previous release")
    parser.add_argument("--first-release", action="store_true", help="accept a missing --previous")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    required = ["out", "version", "build", "dmg_url", "length", "signature", "notes", "notes_link"]
    missing = [name for name in required if getattr(args, name) in (None, "")]
    if missing:
        parser.error("missing: " + ", ".join("--" + name.replace("_", "-") for name in missing))
    if args.previous and os.path.exists(args.previous):
        tree = ET.parse(args.previous)
    elif args.first_release:
        tree = empty_feed()
    else:
        raise SystemExit("error: no previous appcast at %r; pass --first-release for the very first one" % args.previous)
    with open(args.notes, encoding="utf-8") as handle:
        notes = handle.read()
    merge(tree, args.version, args.build, args.min_system, args.dmg_url, args.length, args.signature,
          notes, args.notes_link, datetime.now(timezone.utc))
    write(tree, args.out)
    print("appcast: %s" % args.out)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the self-test**

Run: `python3 scripts/update-appcast.py --self-test`
Expected: `update-appcast.py: self-test OK`.

- [ ] **Step 3: Rewrite `scripts/make-release.sh`**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# Release packaging: Release build → sign → (optional) notarize → DMG → appcast → (optional) upload
# to a GitHub Release. See docs/superpowers/specs/2026-09-25-auto-update-design.md §7.
#
# Usage: scripts/make-release.sh [--notarize] [--upload] [--first-release]
#   --notarize       Developer ID notarization: notarize and staple the .app first, then sign,
#                    notarize and staple the DMG (needs SIGN_IDENTITY + NOTARY_PROFILE)
#   --upload         Publish to the GitHub Release for tag v<version> (requires --notarize, a clean
#                    working tree, the tag pushed and pointing at HEAD, both release-notes files
#                    committed in the tag, and `gh auth login`). The release is created as a draft
#                    with every asset and published in one step, so the update feed never points at
#                    a release without its appcast.
#   --first-release  Accept that no previous release carries an appcast.xml (the first updater
#                    release only)
# Environment variables:
#   SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)"; unset = ad-hoc ("-"): no Sparkle
#                     signing and no appcast, downloaders clear Gatekeeper as the README says
#   NOTARY_PROFILE    The keychain profile saved by `xcrun notarytool store-credentials <name>`
#   E2E_BUNDLE_ID     Build under another bundle identifier (the end-to-end update test only)
#   E2E_BUILD_NUMBER  Build under another CFBundleVersion (the end-to-end update test only)
#
# Single source of truth for the version: MARKETING_VERSION / CURRENT_PROJECT_VERSION in
# project.yml (read back from the built Info.plist). Output: build/QuickTerm-<version>.dmg,
# .dmg.sha256, build/appcast.xml, build/QuickTerm-<version>-notes(.zh-CN).md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
fail() { echo "error: $*" >&2; exit 1; }

REPO="dannyzhu/QuickTerm"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
# The Sparkle version pinned in project.yml, and the checksum of its SwiftPM zip (from Sparkle's
# Package.swift for that tag). The CLI tools (sign_update, generate_keys) come from the same zip.
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"

NOTARIZE=0; UPLOAD=0; FIRST_RELEASE=""   # non-empty = --first-release
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --upload) UPLOAD=1 ;;
    --first-release) FIRST_RELEASE=1 ;;
    *) fail "unknown argument: ${arg} (available: --notarize --upload --first-release)" ;;
  esac
done
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$NOTARIZE" = 1 ] && { [ "$IDENTITY" = "-" ] || [ -z "${NOTARY_PROFILE:-}" ]; }; then
  fail "--notarize requires SIGN_IDENTITY (Developer ID) and NOTARY_PROFILE"
fi
# Once an appcast is published every client is offered the DMG automatically, so an unnotarized
# upload is no longer a manual-download inconvenience but a Gatekeeper block for everyone.
[ "$UPLOAD" = 1 ] && [ "$NOTARIZE" = 0 ] && fail "--upload requires --notarize"
if [ -n "${E2E_BUNDLE_ID:-}${E2E_BUILD_NUMBER:-}" ] && [ "$UPLOAD" = 1 ]; then
  fail "E2E_BUNDLE_ID / E2E_BUILD_NUMBER builds are never uploaded"
fi
grep -q "exactVersion: $SPARKLE_VERSION" "$ROOT/project.yml" \
  || fail "project.yml pins a different Sparkle than SPARKLE_VERSION=$SPARKLE_VERSION in this script"

# ── 0. Preflight checks
cd "$ROOT"
[ -d vendor/ghostty/macos/GhosttyKit.xcframework ] || fail "missing GhosttyKit.xcframework, run scripts/build-ghosttykit.sh first"
find Themes -path '*/backgrounds/*' -type f | grep -q . || fail "missing theme wallpapers, run scripts/fetch-themes.sh first"
if [ "$UPLOAD" = 1 ]; then
  git diff --quiet --ignore-submodules=dirty && git diff --cached --quiet --ignore-submodules=dirty \
    || fail "uncommitted changes in the working tree, --upload requires a clean HEAD"
  command -v gh >/dev/null || fail "missing gh CLI (brew install gh && gh auth login)"
fi

# Sparkle's CLI tools: the SwiftPM artifacts of a previous build, else a checksummed download.
SPARKLE_BIN=""
if [ "$IDENTITY" != "-" ]; then
  DERIVED="$ROOT/build/release"
  SPARKLE_BIN="$(find "$DERIVED/SourcePackages/artifacts" -type f -name sign_update -perm -u+x 2>/dev/null | head -1 || true)"
  SPARKLE_BIN="${SPARKLE_BIN:+$(dirname "$SPARKLE_BIN")}"
  if [ -z "$SPARKLE_BIN" ]; then
    TOOLS="$ROOT/.tools/sparkle-$SPARKLE_VERSION"
    if [ ! -x "$TOOLS/bin/sign_update" ]; then
      mkdir -p "$TOOLS"
      ZIPF="$TOOLS/Sparkle-for-Swift-Package-Manager.zip"
      curl -fL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip" -o "$ZIPF"
      echo "$SPARKLE_SHA256  $ZIPF" | shasum -a 256 -c - >/dev/null || fail "Sparkle tools zip checksum mismatch"
      (cd "$TOOLS" && unzip -qo "$ZIPF" && rm -f "$ZIPF")
    fi
    SPARKLE_BIN="$TOOLS/bin"
  fi
  [ -x "$SPARKLE_BIN/sign_update" ] && [ -x "$SPARKLE_BIN/generate_keys" ] || fail "Sparkle tools not found under $SPARKLE_BIN"
  # The public key in project.yml must be the one whose private half sits in this Mac's Keychain,
  # or every client rejects the signature; and the Keychain must be reachable now, not after a
  # 10-minute build.
  PUBLIC_KEY="$(sed -n 's/^ *SUPublicEDKey: *"\{0,1\}\([A-Za-z0-9+/=]*\)"\{0,1\}.*/\1/p' project.yml | head -1)"
  [ -n "$PUBLIC_KEY" ] || fail "project.yml has no SUPublicEDKey: run generate_keys once and add the public key"
  KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]')"
  [ "$KEYCHAIN_KEY" = "$PUBLIC_KEY" ] || fail "SUPublicEDKey in project.yml does not match the key in the login Keychain (generate_keys -p)"
  SCRATCH="$(mktemp)"; echo probe > "$SCRATCH"
  "$SPARKLE_BIN/sign_update" "$SCRATCH" >/dev/null || fail "sign_update cannot sign (Keychain locked? run it once by hand and click Always Allow)"
  rm -f "$SCRATCH"
fi

# ── 1. Release build (wipe old products: a failed build must never pass off a stale .app as new)
DERIVED="$ROOT/build/release"
BUILD_LOG="$ROOT/build/release-build.log"
mkdir -p "$ROOT/build"
rm -rf "$DERIVED/Build/Products"
xcodegen generate >/dev/null
echo "▶ Release build… (log: ${BUILD_LOG})"
# generic destination: builds for ARCHS_STANDARD (arm64 x86_64); without it Xcode falls back to
# "My Mac" and builds the native arch only. xcodebuild also fetches the Sparkle SwiftPM binary
# package (network; the same proxy note as for Zig applies).
if ! xcodebuild -project QuickTerm.xcodeproj -scheme QuickTerm -configuration Release \
     -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO \
     ${E2E_BUNDLE_ID:+PRODUCT_BUNDLE_IDENTIFIER="$E2E_BUNDLE_ID"} \
     ${E2E_BUILD_NUMBER:+CURRENT_PROJECT_VERSION="$E2E_BUILD_NUMBER"} \
     -derivedDataPath "$DERIVED" build >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20 >&2
  fail "build failed (BUILD FAILED), see $BUILD_LOG"
fi
APP="$DERIVED/Build/Products/Release/QuickTerm.app"
[ -d "$APP" ] || fail "build did not produce $APP"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"
case "$MIN_SYSTEM" in *.*.*) ;; *) MIN_SYSTEM="$MIN_SYSTEM.0" ;; esac
TAG="v$VERSION"
ARCHS_BUILT="$(lipo -archs "$APP/Contents/MacOS/QuickTerm")"
for want in ${RELEASE_ARCHS:-arm64 x86_64}; do
  case " $ARCHS_BUILT " in *" $want "*) ;; *) fail "build is missing arch ${want} (got: ${ARCHS_BUILT}). Run GHOSTTYKIT_TARGET=universal scripts/build-ghosttykit.sh first" ;; esac
done
echo "version ${VERSION} build ${BUILD_NUMBER} (archs: ${ARCHS_BUILT})"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
[ "$(find "$APP/Contents/Frameworks" -maxdepth 1 -name 'Sparkle.framework' | wc -l | tr -d ' ')" = 1 ] \
  || fail "expected exactly one Contents/Frameworks/Sparkle.framework"
EMBEDDED_SPARKLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SPARKLE_FW/Resources/Info.plist")"
[ "$EMBEDDED_SPARKLE" = "$SPARKLE_VERSION" ] || fail "embedded Sparkle is $EMBEDDED_SPARKLE, expected $SPARKLE_VERSION"
if [ "$IDENTITY" != "-" ]; then
  [ -n "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST" 2>/dev/null)" ] || fail "built app carries no SUPublicEDKey"
  [ -n "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$PLIST" 2>/dev/null)" ] || fail "built app carries no SUFeedURL"
fi

NOTES_EN="$ROOT/docs/releases/$TAG.md"
NOTES_ZH="$ROOT/docs/releases/$TAG.zh-CN.md"
if [ "$UPLOAD" = 1 ]; then
  git rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null || fail "missing local tag ${TAG}: git tag $TAG"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TAG^{commit}")" ] || fail "HEAD is not the commit that tag $TAG points at"
  git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || fail "tag $TAG not pushed: git push origin $TAG"
  # Both notes files, in the tag: the app fetches them from the release assets by version.
  git cat-file -e "$TAG:docs/releases/$TAG.md" 2>/dev/null || fail "docs/releases/$TAG.md is not committed in $TAG"
  git cat-file -e "$TAG:docs/releases/$TAG.zh-CN.md" 2>/dev/null || fail "docs/releases/$TAG.zh-CN.md is not committed in $TAG"
fi

# ── 2. Sign: nested code first, then the app. The deprecated --deep would sign in the wrong order
#      and hand the app's entitlements to everything inside.
echo "▶ Signing (${IDENTITY})…"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  ENTITLEMENTS="$ROOT/QuickTerm.entitlements"
  [ -f "$ENTITLEMENTS" ] || fail "missing $ENTITLEMENTS (needed for a hardened-runtime signature)"
  # Loose Mach-O files (the bundled CLI): hardened runtime + timestamp, no entitlements of their
  # own (re-signing without --entitlements drops the get-task-allow Xcode embedded).
  while IFS= read -r -d '' nested; do
    file "$nested" | grep -q "Mach-O" || continue
    echo "  signing nested code: ${nested#"$APP"/}"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
  done < <(find "$APP/Contents/SharedSupport" "$APP/Contents/Helpers" -type f -perm -u+x -print0 2>/dev/null)
  # Sparkle's nested code, by bundle path and inside-out (Sparkle's sandboxing guide): the XPC
  # services keep their entitlements. The unsandboxed app does not use them, but notarization
  # still wants them signed.
  for bundle in \
      "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
      "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
      "$SPARKLE_FW/Versions/B/Autoupdate" \
      "$SPARKLE_FW/Versions/B/Updater.app" \
      "$SPARKLE_FW"; do
    [ -e "$bundle" ] || fail "Sparkle layout changed, missing $bundle"
    echo "  signing Sparkle: ${bundle#"$APP"/}"
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$bundle"
  done
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

# ── 3. Notarize and staple the .app itself (Apple's recommended order: app, then DMG)
if [ "$NOTARIZE" = 1 ]; then
  ZIP="$ROOT/build/QuickTerm-$VERSION-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "▶ Notarizing .app…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

# ── 4. DMG (drag-to-Applications layout)
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/build/QuickTerm-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"
echo "▶ Packaging DMG…"
hdiutil create -volname "QuickTerm $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
if [ "$IDENTITY" != "-" ]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  echo "▶ Notarizing DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# ── 5. Checksum (file name only, so downloaders can just run
#      `shasum -a 256 -c QuickTerm-<version>.dmg.sha256` in the same directory)
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"

# ── 6. Appcast: EdDSA-sign the final DMG and merge the item into the previous release's feed
APPCAST="$ROOT/build/appcast.xml"
NOTES_EN_ASSET="$ROOT/build/QuickTerm-$VERSION-notes.md"
NOTES_ZH_ASSET="$ROOT/build/QuickTerm-$VERSION-notes.zh-CN.md"
rm -f "$APPCAST" "$NOTES_EN_ASSET" "$NOTES_ZH_ASSET"
if [ "$IDENTITY" != "-" ]; then
  echo "▶ Appcast…"
  SIGNED="$("$SPARKLE_BIN/sign_update" "$DMG")"     # sparkle:edSignature="…" length="…"
  ED_SIGNATURE="$(printf '%s' "$SIGNED" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  ED_LENGTH="$(printf '%s' "$SIGNED" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
  [ -n "$ED_SIGNATURE" ] && [ -n "$ED_LENGTH" ] || fail "could not parse sign_update output: $SIGNED"
  [ "$ED_LENGTH" = "$(stat -f %z "$DMG")" ] || fail "sign_update length differs from the DMG size"
  PREVIOUS="$ROOT/build/appcast-previous.xml"; rm -f "$PREVIOUS"
  PREV_TAG=""
  if command -v gh >/dev/null; then
    PREV_TAG="$(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 30 --json tagName -q '.[].tagName' 2>/dev/null | grep -vx "$TAG" | head -1 || true)"
  fi
  if [ -n "$PREV_TAG" ]; then
    curl -fsSL "https://github.com/$REPO/releases/download/$PREV_TAG/appcast.xml" -o "$PREVIOUS" || rm -f "$PREVIOUS"
  fi
  if [ ! -f "$PREVIOUS" ] && [ -z "$FIRST_RELEASE" ]; then
    if [ "$UPLOAD" = 1 ]; then
      fail "the previous release (${PREV_TAG:-none}) has no appcast.xml; pass --first-release only for the very first updater release"
    fi
    echo "warning: no previous appcast (${PREV_TAG:-none}); the dry run starts an empty feed"
    FIRST_RELEASE=1
  fi
  [ -f "$NOTES_EN" ] || fail "missing $NOTES_EN (the English notes are the appcast description)"
  python3 "$ROOT/scripts/update-appcast.py" --out "$APPCAST" --version "$VERSION" --build "$BUILD_NUMBER" \
    --min-system "$MIN_SYSTEM" --dmg-url "https://github.com/$REPO/releases/download/$TAG/QuickTerm-$VERSION.dmg" \
    --length "$ED_LENGTH" --signature "$ED_SIGNATURE" --notes "$NOTES_EN" \
    --notes-link "https://github.com/$REPO/releases/tag/$TAG" \
    ${FIRST_RELEASE:+--first-release} ${PREVIOUS:+--previous "$PREVIOUS"}
  grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST" || fail "appcast does not carry build $BUILD_NUMBER"
  [ -f "$NOTES_EN" ] && cp "$NOTES_EN" "$NOTES_EN_ASSET"
  [ -f "$NOTES_ZH" ] && cp "$NOTES_ZH" "$NOTES_ZH_ASSET"
  echo "OK: $APPCAST"
fi

# ── 7. GitHub Release (draft with every asset, then published in one step)
if [ "$UPLOAD" = 1 ]; then
  ASSETS=("$DMG" "$DMG.sha256" "$NOTES_EN_ASSET" "$NOTES_ZH_ASSET" "$APPCAST")
  for asset in "${ASSETS[@]}"; do [ -f "$asset" ] || fail "missing release asset $asset"; done
  if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "${ASSETS[@]}" -R "$REPO" --clobber
  else
    gh release create "$TAG" "${ASSETS[@]}" -R "$REPO" --draft --verify-tag --title "QuickTerm $VERSION" --notes-file "$NOTES_EN"
    gh release edit "$TAG" -R "$REPO" --draft=false
  fi
  echo "published: $(gh release view "$TAG" -R "$REPO" --json url -q .url)"
  # The live feed must advertise exactly this build, signature and size.
  sleep 5
  LIVE="$(curl -fsSL "$FEED_URL")" || fail "the live feed at $FEED_URL is unreachable"
  printf '%s' "$LIVE" | grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" || fail "live feed lacks build $BUILD_NUMBER"
  printf '%s' "$LIVE" | grep -q "sparkle:edSignature=\"$ED_SIGNATURE\"" || fail "live feed lacks this DMG's signature"
  printf '%s' "$LIVE" | grep -q "length=\"$ED_LENGTH\"" || fail "live feed lacks this DMG's length"
  echo "feed OK: $FEED_URL"
fi
```

- [ ] **Step 4: Syntax-check and dry-run**

Run: `bash -n scripts/make-release.sh && echo syntax OK`
Expected: `syntax OK`.

Run (ad-hoc identity, no Sparkle steps, universal kit required): `scripts/make-release.sh 2>&1 | tail -5`
Expected: ends with `OK: …/build/QuickTerm-1.6.7.dmg (…)`, the Sparkle framework count check passes, no `appcast` line (ad-hoc skips it). Delete the produced DMG afterwards if it could be mistaken for the published one: `rm -f build/QuickTerm-1.6.7.dmg build/QuickTerm-1.6.7.dmg.sha256`.

- [ ] **Step 5: README, both languages, line-parallel**

`README.md`, in `## Install`, after the numbered step 2 add a step 3:

```
3. From the first updater-enabled release on, QuickTerm keeps itself up to date: it checks GitHub Releases about once a day and shows an icon in the status bar when a newer version is out (see `[updates]` under Configuration). Versions up to 1.6.7 have no updater — install this one by hand once.
```

`README.zh-CN.md`, same place:

```
3. 从第一个带更新器的版本起，QuickTerm 会自己保持最新：大约每天到 GitHub Releases 查一次，有新版本时状态栏亮一个图标（见「配置」里的 `[updates]`）。1.6.7 及更早版本没有更新器——这一次请手动安装。
```

`README.md`, in `### How the engine is configured`, after the bullet about `~/.config/ghostty/config` add a sentence at the end of that bullet: ` The engine's own `auto-update` and `auto-update-channel` keys are ignored: QuickTerm's `[updates]` section decides.` `README.zh-CN.md`: ` 引擎自己的 `auto-update` / `auto-update-channel` 两个键不生效：由 QuickTerm 的 `[updates]` 节决定。`

`README.md`, immediately before the `## Configuration` heading, add:

```
### Releasing

One-time, on the release Mac: run Sparkle's `generate_keys` (from `.tools/sparkle-2.10.0/bin` after a first `scripts/make-release.sh`, or the SwiftPM artifacts), put the printed public key into `project.yml` as `SUPublicEDKey`, back the private key up with `generate_keys -x <file>` to offline storage, and run `sign_update` once by hand so the Keychain prompt is answered with *Always Allow*.

Per release: bump `MARKETING_VERSION` **and** `CURRENT_PROJECT_VERSION` in `project.yml` (Sparkle compares the build number; the script refuses a build that is not greater than the feed's), write `docs/releases/v<version>.md` and `docs/releases/v<version>.zh-CN.md`, commit, tag `v<version>`, push the tag, then `SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/make-release.sh --notarize --upload`. The script publishes the DMG, its checksum, both notes files and `appcast.xml` as one draft-then-published release and verifies the live feed. If a release has to be pulled, re-run the appcast step against the release that becomes latest — the feed URL always follows the newest release.

```

`README.zh-CN.md`, immediately before `## 配置`:

```
### 发版

一次性（在发版的 Mac 上）：运行 Sparkle 的 `generate_keys`（第一次跑过 `scripts/make-release.sh` 后在 `.tools/sparkle-2.10.0/bin`，或 SwiftPM 的 artifacts 里），把打印出的公钥填进 `project.yml` 的 `SUPublicEDKey`，用 `generate_keys -x <文件>` 把私钥备份到离线位置，再手动跑一次 `sign_update`，在钥匙串提示里选「始终允许」。

每次发版：在 `project.yml` 里同时升 `MARKETING_VERSION` **和** `CURRENT_PROJECT_VERSION`（Sparkle 比的是构建号；构建号不大于 feed 里已有的，脚本会拒绝），写好 `docs/releases/v<版本>.md` 与 `docs/releases/v<版本>.zh-CN.md`，提交、打 `v<版本>` tag、推送 tag，然后 `SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/make-release.sh --notarize --upload`。脚本把 DMG、校验和、两份说明和 `appcast.xml` 作为一个「先草稿、再发布」的 release 一次发出，并回读线上 feed 校验。如果某个 release 要撤下，就对新的最新 release 重跑 appcast 那一步——feed 地址永远跟着最新的 release。

```

- [ ] **Step 6: Porting notes**

Append to `docs/porting-notes.md`:

```

## Auto-update: Sparkle behind Ghostty's driver, in QuickTerm's own UI (2026-09-25)

Upstream's `Features/Update` (controller, `SPUUserDriver`, delegate, view model, simulator) is
ported into `Sources/Update/` with the presentation replaced: no titlebar pill, no popover, no
xib — the status bar's right cluster gets an indicator and a click opens the house `NSAlert`
sheet. What changed against upstream, and why:

- `UpdateDriver` drops the `SPUStandardUserDriver` fallback and the terminal-window observers;
  `showUpdateFound` branches on `SPUUserUpdateState.stage` (a staged update is "quit or restart to
  finish", not "78 MB available"); `showUpdateInFocus` opens the sheet (without it Sparkle keeps
  `canCheckForUpdates` false while an update is on screen); errors and not-found are acknowledged
  at once so no Sparkle session is ever held by a view.
- `UpdateController.updater` is optional: the test host, a build without `SUPublicEDKey` and a
  Debug build without `--update-feed-url` have no Sparkle at all and one code path.
- "Later" in check-only mode replies nothing (the reply block is retained), so the icon stays; in
  install mode it replies dismiss so the automatic driver stages the update on the next check.
- The quit confirmation stands aside on `relaunchRequested`, set by every path that asks Sparkle
  to terminate the app.
- Release notes come from two release assets (`QuickTerm-<v>-notes.md` / `-notes.zh-CN.md`),
  not from the appcast; `docs/releases/v<v>.zh-CN.md` is required from now on.
- The design and its review are in `docs/superpowers/specs/2026-09-25-auto-update-design.md`.
```

- [ ] **Step 7: Run the documentation tests and commit**

Run: `xcodegen generate && xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' -only-testing:QuickTermTests/ConfigSchemaTests 2>&1 | grep -E "error:|failed|Executed|\*\* TEST"`
Expected: `** TEST SUCCEEDED **` (both READMEs still carry every key line).

```bash
git add scripts/update-appcast.py scripts/make-release.sh README.md README.zh-CN.md docs/porting-notes.md
git commit -m "release: EdDSA-signed DMG, appcast and bilingual notes assets on every release

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: The public key, the full suite and the end-to-end update

Spec §7 (one-time setup), §11 (end to end). **Blocked on the user for the key**: everything before the key can be done; the E2E needs it.

**Files:**
- Modify: `project.yml` (`SUPublicEDKey`), `docs/superpowers/specs/2026-09-25-auto-update-design.md` (record the E2E outcome under §11)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Ask the user for the public key**

The user runs, on the release Mac, from the tools directory `scripts/make-release.sh` sets up (`.tools/sparkle-2.10.0/bin`, created by a first run with `SIGN_IDENTITY` set — it fails at the "no SUPublicEDKey" preflight after downloading the tools, which is fine) or from `build/release/SourcePackages/artifacts/sparkle/Sparkle/bin`:

```bash
.tools/sparkle-2.10.0/bin/generate_keys
```

It prints the public key. The user also runs `generate_keys -x ~/Desktop/quickterm-sparkle-private.key` and moves that file to offline storage. The user pastes only the **public** key into the chat. The private key never leaves their Keychain.

- [ ] **Step 2: Put the public key into `project.yml`**

Under the app target's `info.properties`, next to `SUFeedURL`, add `SUPublicEDKey: "<the pasted key>"`. Run `xcodegen generate`.

- [ ] **Step 3: Run the whole suite**

Run (outside the sandbox): `xcodebuild test -project QuickTerm.xcodeproj -scheme QuickTerm -destination 'platform=macOS' 2>&1 | grep -E "Test Case .* failed|Executed .* tests|\*\* TEST"`
Expected: `** TEST SUCCEEDED **`, 0 failures (the 3 Documents-privacy skips are normal).

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "build: the Sparkle public key

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 5: End to end, per spec §11**

1. Build the older app: `SIGN_IDENTITY="Developer ID Application: Hangzhou Wujie Tongshun Technology Co., Ltd (PS7PJY4CYN)" E2E_BUNDLE_ID=dev.danny.quickterm.e2e E2E_BUILD_NUMBER=9001 scripts/make-release.sh --first-release` (never `--upload`; the E2E variables make the script add the `UPDATE_E2E` compilation condition, so this Release build honours `--update-feed-url`, spec §8), then copy it out before the second build wipes it, into `/Applications` under its own name so it runs untranslocated and never touches the installed QuickTerm: `ditto build/release/Build/Products/Release/QuickTerm.app "/Applications/QuickTerm E2E.app"` (the DMG it produced is not needed).
2. Build the newer one: same command with `E2E_BUILD_NUMBER=9002`; keep `build/QuickTerm-1.6.7.dmg` as the e2e DMG (`mv build/QuickTerm-1.6.7.dmg build/e2e-new.dmg`) and `build/appcast.xml` (it was written with `--first-release` against build 9002; edit its enclosure `url` to the pre-release asset URL below before uploading).
3. Publish a temporary pre-release on the repository the user chooses (`gh release create e2e-$(date +%Y%m%d) --prerelease --title "e2e" --notes "temporary" build/e2e-new.dmg build/appcast.xml`); pre-releases are excluded from `releases/latest`.
4. Launch the older app as a second instance: `open -n "/Applications/QuickTerm E2E.app" --args --update-feed-url https://github.com/<repo>/releases/download/e2e-<date>/appcast.xml --state-file /tmp/e2e-state.json --control-socket /tmp/e2e.sock --config-file /tmp/e2e-config.toml`. Both apps are the Release builds from steps 1-2; no Debug build and no hand signing is involved.
5. Walk: **Check for Updates…** → icon → sheet → **Install and Relaunch** → the app quits without relaunching (override) → `open -n "/Applications/QuickTerm E2E.app" --args …` again with the same arguments → `About QuickTerm` shows build 9002 and the scratch layout is restored. Then, with `install = true` in `/tmp/e2e-config.toml`, the staged path: the icon turns to `power.circle` after the background download; **Restart Now** and a plain quit both install it. `log stream --level info --predicate 'subsystem == "dev.danny.quickterm.e2e" AND category == "updates"'` shows every state transition.
6. Record in the spec's §11 whether Sparkle's Gatekeeper scan accepted the unnotarized e2e DMG; if it did not, notarize the e2e DMG (`--notarize`) and repeat.
7. Teardown: `defaults delete dev.danny.quickterm.e2e`, `gh release delete e2e-<date> --yes --cleanup-tag`, `rm -rf "/Applications/QuickTerm E2E.app" build/e2e-new.dmg /tmp/e2e-*`.

- [ ] **Step 6: Commit the spec's E2E record and update the project memory**

```bash
git add docs/superpowers/specs/2026-09-25-auto-update-design.md
git commit -m "docs: record the end-to-end update run

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Memory (`~/.claude/projects/-Users-Danny-Documents-workspace-quickterm/memory/quickterm-project.md`): a bullet with the release checklist changes (bump both numbers, two notes files, `--notarize --upload` now also publishes the appcast) and where the Sparkle tools live.
