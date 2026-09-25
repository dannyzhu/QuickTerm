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
