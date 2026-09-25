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
        /// A manual "Check for Updates…" resumed a staged update (Sparkle's
        /// `showUpdateFound(stage: .installing, userInitiated: true)`): the sheet opens without a
        /// click. False for the staged-on-quit state and for Sparkle terminating the app.
        let userInitiated: Bool
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
