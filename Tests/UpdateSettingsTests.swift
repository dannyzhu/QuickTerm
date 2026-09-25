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
