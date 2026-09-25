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
