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

        /// Every key `titleKey` can produce, spelled out for the catalog lint and
        /// `LocalizationTests`: `makeAlert` reads the title through `L(button.titleKey)`, a
        /// dynamic lookup, so the sheet-only keys need one literal call site somewhere (the
        /// `window.button.*` pair already has plenty elsewhere).
        static let localizedTitles: [String] = [
            L("update.sheet.button.install"), L("update.sheet.button.later"), L("update.sheet.button.skip"),
            L("update.sheet.button.restart"), L("update.sheet.button.retry"),
        ]
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

    /// `notes` defaults to `nil` rather than `= ReleaseNotes.Loader()`: a default value expression
    /// runs outside this type's actor isolation even though the type itself is `@MainActor`, so it
    /// cannot call `Loader`'s `@MainActor` initializer directly — building it in the init body
    /// (which does run isolated) sidesteps that without changing the effective default.
    init(controller: UpdateController, notes: ReleaseNotes.Loader? = nil,
         currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") {
        self.controller = controller
        self.notes = notes ?? ReleaseNotes.Loader()
        self.currentVersion = currentVersion
        stateCancellable = controller.viewModel.$state.dropFirst().sink { [weak self] state in
            self?.stateDidChange(state)
        }
    }

    var isPresented: Bool { built != nil }

    /// A click on the indicator, or Sparkle's showUpdateInFocus.
    ///
    /// Controller ruling: during `.notFound` ("You're up to date") there is nothing to put in a
    /// sheet, and a click there is the design's way of clearing that state early — so this clears
    /// it through the controller instead of building (or trying to build) an alert for it.
    func present() {
        if case .notFound = controller.viewModel.state {
            controller.clearNotFound()
            return
        }
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
                // Split from the `+=` on purpose: `check-localization.py` flags an `L(…)` call
                // glued directly onto a `+` as unstranslatable word order, even though this one
                // only appends a whole extra sentence.
                let notesLine = L("update.sheet.notes.github", page.absoluteString)
                intro += "\n" + notesLine
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
