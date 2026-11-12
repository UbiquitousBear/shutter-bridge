import XCTest

/// UI tests of the screens that need no camera (I18; decision D14 (c)): History, Settings and the Staging tab's cull
/// screen, run in the iOS Simulator by CI (`app.yml`). Each test launches the Debug app with `-UITestFixture`, which
/// composes it over an in-memory catalogue seeded with three job records, four staged JPEGs of one day and their marks
/// (AppUI's `UITestFixture`), so every launch starts from the same state and nothing on the Simulator is read. The
/// "Browse → select → import → History" path needs a camera and waits for Iteration 5's review-build simulator
/// mode.
///
/// Every wait is bounded (`waitForExistence(timeout:)`), so a screen that never shows fails the test rather than
/// hanging it. Elements are found by the app's own British English wording.
final class ShutterBridgeUITests: XCTestCase {
    /// The fixture's camera, by its display name.
    private let camera = "ILCE-7CM2"
    /// Long enough for a cold Simulator launch on CI.
    private let launchTimeout: TimeInterval = 30
    private let timeout: TimeInterval = 10

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: History

    @MainActor
    func testHistoryListsTheSeededJobsNewestFirstWithTheirOutcomes() throws {
        let app = launchFixture()
        openTab("History", in: app)

        let stopped = element(in: app, labelBeginningWith: "Import from \(camera)",
                              containing: "2 failed files not imported yet")
        XCTAssertTrue(stopped.waitForExistence(timeout: timeout), "the stopped import's row, with its failures left")
        let finished = element(in: app, labelBeginningWith: "Import from \(camera)",
                               containing: "48 imported, 2 skipped")
        XCTAssertTrue(finished.waitForExistence(timeout: timeout), "the finished import's row")
        XCTAssertTrue(finished.label.contains("Finished."), "the finished import's outcome: \(finished.label)")
        let staged = element(in: app, labelBeginningWith: "Stage from \(camera)", containing: "4 staged")
        XCTAssertTrue(staged.waitForExistence(timeout: timeout), "the stage job's row")
        XCTAssertTrue(staged.label.contains("Staging."), "the stage job's place: \(staged.label)")
        // Newest first: the stopped import (an hour ago) above the finished one (three hours ago).
        XCTAssertLessThan(stopped.frame.minY, finished.frame.minY)
    }

    // MARK: Settings

    @MainActor
    func testSettingsSaysWhereStagingGoesAndOffersTheDiagnosticsExport() throws {
        let app = launchFixture()
        let settingsButton = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: launchTimeout), "the Cameras screen's Settings button")
        settingsButton.tap()

        // The fixture's iCloud Drive reads as off, so staging is on this iPhone and Settings says why.
        let location = element(in: app,
                               labelBeginningWith: "Staging folder, On My iPhone › Shutter Bridge › Staging")
        XCTAssertTrue(location.waitForExistence(timeout: timeout), "where staging goes")
        let why = app.staticTexts[
            "iCloud Drive is off or you're not signed in to iCloud, so staging is on this iPhone."]
        XCTAssertTrue(why.waitForExistence(timeout: timeout), "why staging is on this iPhone")
        // Photos access reads as allowed in the fixture, so nothing says Import to Photos stages instead.
        XCTAssertFalse(element(in: app, labelBeginningWith: "Photos access is off").exists)
        XCTAssertTrue(app.buttons["Export Diagnostics…"].waitForExistence(timeout: timeout), "the export row (I8)")

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: timeout))
        close.tap()
        XCTAssertTrue(waitForDisappearance(of: why), "Settings closes")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: timeout))
    }

    // MARK: Staging (the cull screen)

    @MainActor
    func testStagingListsTheDayAndKeepingAPhotoInTheLoupeCountsIt() throws {
        let app = launchFixture()
        openTab("Staging", in: app)

        let day = element(in: app, labelEndingWith: ": 4 staged, 1 kept, 1 rejected")
        XCTAssertTrue(day.waitForExistence(timeout: timeout), "the seeded day with its counts")
        XCTAssertTrue(app.staticTexts[camera].exists, "the camera's section")
        day.tap()

        // The loupe opens at the first photo with no mark: the third of four.
        XCTAssertTrue(app.navigationBars["3 of 4"].waitForExistence(timeout: timeout), "the loupe at the third photo")
        let keep = app.buttons["Keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: timeout))
        keep.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: timeout))
        close.tap()

        let counted = element(in: app, labelEndingWith: ": 4 staged, 2 kept, 1 rejected")
        XCTAssertTrue(counted.waitForExistence(timeout: timeout), "the keep is counted once the loupe closes")
    }

    @MainActor
    func testTheStagingTabOffersImportKeepers() throws {
        let app = launchFixture()
        openTab("Staging", in: app)
        let day = element(in: app, labelEndingWith: ": 4 staged, 1 kept, 1 rejected")
        XCTAssertTrue(day.waitForExistence(timeout: timeout), "the seeded day")
        XCTAssertTrue(app.buttons["Import Keepers"].waitForExistence(timeout: timeout), "Import keepers (I12)")
    }

    // MARK: Helpers

    /// The app over the seeded catalogue, launched afresh.
    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: launchTimeout),
                      "the tab bar, once the catalogue is open")
        return app
    }

    @MainActor
    private func openTab(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout), "the \(name) tab")
        tab.tap()
    }

    /// The first element of any type whose accessibility label starts with `prefix` (and contains `text`, when given).
    @MainActor
    private func element(in app: XCUIApplication, labelBeginningWith prefix: String,
                         containing text: String? = nil) -> XCUIElement {
        let predicate = if let text {
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", prefix, text)
        } else {
            NSPredicate(format: "label BEGINSWITH %@", prefix)
        }
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// The first element of any type whose accessibility label ends with `suffix`.
    @MainActor
    private func element(in app: XCUIApplication, labelEndingWith suffix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", suffix)).firstMatch
    }

    /// Whether `element` is gone within the timeout.
    @MainActor
    private func waitForDisappearance(of element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
