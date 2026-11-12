import XCTest

/// The Photos lookup check (W6-lookup; backlog section 3.1), run by CI in the iOS Simulator (`app.yml`), which grants
/// the app full Photos access first. The test launches the Debug app with `-PhotosLookupCheck` (and `-UITestFixture`,
/// so the app behind the check is the seeded one): it saves two JPEGs through the app's Photos destination, one into
/// the library only and one also into an album it creates, then runs `SystemPhotoLibrary.findAsset` with the query the
/// engine builds for each, for a name never saved and for the right name 30 s outside the ±1 s window (AppUI's
/// `PhotosLookupCheck`). Its report is one text, "Photos lookup check finished: key=value; …", which this test reads.
///
/// Every wait is bounded, so a check that never finishes fails the test rather than hanging it.
final class PhotosLookupCheckUITests: XCTestCase {
    /// Long enough for a cold Simulator launch on CI.
    private let launchTimeout: TimeInterval = 30
    /// The saves and lookups take a second or two in the Simulator; a stuck library fails here.
    private let checkTimeout: TimeInterval = 90

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFindAssetFindsWhatTheAppSavedWithAndWithoutAnAlbumAndNothingElse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixture", "-PhotosLookupCheck"]
        app.launch()

        let report = app.staticTexts["photos-lookup-check"]
        XCTAssertTrue(report.waitForExistence(timeout: launchTimeout), "the check's report")
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Photos lookup check finished: "), object: report)
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: checkTimeout), .completed,
                       "the check finishes; the report reads: \(report.label)")

        let label = report.label
        let values = Self.entries(of: label)
        let expected: [(String, String)] = [
            // Granted by app.yml before the tests; anything else and nothing is saved.
            ("access", "authorised"),
            ("save.libraryOnly", "saved"),
            ("save.inAlbum", "saved"),
            ("album", "created"),
            ("album.holdsAsset", "yes"),
            // Found as the asset the save returned, library-wide, with and without an album.
            ("lookup.libraryOnly", "found"),
            ("lookup.inAlbum", "found"),
            // A name never saved, and the right name outside the ±1 s window.
            ("lookup.neverSaved", "not found"),
            ("lookup.outsideWindow", "not found"),
            ("verdict", "pass"),
        ]
        for (key, value) in expected {
            XCTAssertEqual(values[key], value, "\(key) in the report: \(label)")
        }
    }

    /// The report's entries by key: after "finished: ", "key=value" pairs separated by "; ".
    private static func entries(of label: String) -> [String: String] {
        guard let start = label.range(of: "finished: ") else { return [:] }
        var values: [String: String] = [:]
        for entry in label[start.upperBound...].components(separatedBy: "; ") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, values[parts[0]] == nil { values[parts[0]] = parts[1] }
        }
        return values
    }
}
