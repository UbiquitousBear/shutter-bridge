import Catalogue
import Foundation
import Testing
@testable import AppUI

@Suite("Staging and loupe wording")
struct CullWordingTests {
    private var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private let britain = Locale(identifier: "en_GB")

    /// 11 Nov 2026, 09:30 in London.
    private var now: Date {
        london.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9, minute: 30))!
    }

    @Test func daysAreTodayYesterdayOrTheDateWrittenOut() {
        #expect(CullWording.dayTitle("20261111", now: now, calendar: london, locale: britain) == "Today")
        #expect(CullWording.dayTitle("20261110", now: now, calendar: london, locale: britain) == "Yesterday")
        let older = CullWording.dayTitle("20261105", now: now, calendar: london, locale: britain)
        #expect(older.contains("Thursday") && older.contains("5 November 2026"))
        // A day that isn't one is shown as it came, never a crash.
        #expect(CullWording.dayTitle("2026110", now: now, calendar: london, locale: britain) == "2026110")
        #expect(CullWording.dayTitle("2026AB05", now: now, calendar: london, locale: britain) == "2026AB05")
    }

    @Test func countsAreInUnitsAndLeaveOutWhatIsNone() {
        let raw = cullFile("DSC00001.ARW"), jpg = cullFile("DSC00001.JPG")
        let single = cullFile("DSC00002.JPG", at: "20261105T140005")
        let units = CullDay.days(of: [raw, jpg, single])[0].units
        #expect(units.count == 2)
        let none = CullCounts(units: units, marks: [:])
        #expect(CullWording.countsLine(none) == "2 staged")
        let marked = CullCounts(units: units, marks: [jpg.contentKey: CullMark(decision: .reject),
                                                      single.contentKey: CullMark(decision: .keep)])
        #expect(CullWording.countsLine(marked) == "2 staged, 1 kept, 1 rejected")
        #expect(CullWording.dayLabel(title: "Today", counts: marked) == "Today: 2 staged, 1 kept, 1 rejected")
        let kept = CullCounts(units: units, marks: [single.contentKey: CullMark(decision: .keep)])
        #expect(CullWording.countsLine(kept) == "2 staged, 1 kept")
    }

    @Test func unavailableFilesAreCountedInOnesAndManys() {
        #expect(CullWording.unavailableLines(StagedUnavailable()).isEmpty)
        #expect(CullWording.unavailableLines(StagedUnavailable(inICloudDrive: 3, gone: 1, unknownPlace: 1)) == [
            "3 staged files are in iCloud Drive, which isn't available to Shutter Bridge now.",
            "1 staged file is no longer in Staging as it was staged.",
            "1 staged file can't be shown: Shutter Bridge doesn't know where its copy is.",
        ])
    }

    @Test func marksStarsAndPositionsAreSaidPlainly() {
        #expect(CullWording.position(0, of: 120) == "1 of 120")
        #expect(CullWording.position(0, of: 0) == "None")
        #expect(CullWording.decisionWord(.keep) == "Kept")
        #expect(CullWording.decisionWord(.reject) == "Rejected")
        #expect(CullWording.decisionWord(nil) == "No mark")
        #expect((0 ... 5).map(CullWording.stars) == ["No stars", "1 star", "2 stars", "3 stars", "4 stars", "5 stars"])
        #expect((0 ... 5).map(CullWording.rateAction) == ["No Stars", "1 Star", "2 Stars", "3 Stars", "4 Stars", "5 Stars"])
        #expect(CullWording.unitValue(index: 11, count: 120, mark: CullMark(decision: .keep, rating: 3))
            == "12 of 120, Kept, 3 stars")
        #expect(CullWording.unitValue(index: 0, count: 2, mark: .unmarked) == "1 of 2, No mark")
    }

    @Test func pairsAreNamedByTheFileTheyAreShownBy() {
        let units = CullDay.days(of: [
            cullFile("DSC00001.ARW"), cullFile("DSC00001.JPG"),
            cullFile("DSC00002.ARW", at: "20261105T140010"), cullFile("DSC00002.HIF", at: "20261105T140010"),
            cullFile("DSC00003.JPG", at: "20261105T140020"),
        ])[0].units
        #expect(units.map(CullWording.pairBadge) == ["RAW+JPEG", "RAW+HEIF", nil])
        #expect(units.map(CullWording.unitLabel) == ["DSC00001.JPG and its RAW", "DSC00002.HIF and its RAW",
                                                     "DSC00003.JPG"])
    }

    @Test func announcementsSayWhatHappenedAndWhereTheLoupeIs() {
        #expect(CullWording.marked(.keep, movedTo: "13 of 120") == "Kept. 13 of 120.")
        #expect(CullWording.marked(.reject, movedTo: nil) == "Rejected.")
        #expect(CullWording.marked(nil, movedTo: nil) == "Mark cleared.")
        #expect(CullWording.rated(1) == "1 star.")
        #expect(CullWording.rated(0) == "No stars.")
        #expect(CullWording.undone(index: 11, count: 120, mark: CullMark(decision: .reject))
            == "Mark undone. 12 of 120, Rejected.")
    }

    @Test func theCopyIsBritishAndNamesNoMark() {
        let all = [CullWording.title, CullWording.openStagingHint, CullWording.emptyTitle, CullWording.emptyDetail,
                   CullWording.loadFailedTitle, CullWording.loadFailedDetail, CullWording.dayHint,
                   CullWording.loupeHint, CullWording.writeFailed, CullWording.embeddedOnly,
                   CullWording.previewFailedTitle, CullWording.downloading, CullWording.zoomIn,
                   CullWording.zoomOut]
        for line in all {
            #expect(!line.contains("Sony") && !line.contains("color") && !line.contains("catalog "))
            #expect(!line.isEmpty)
        }
        // The embedded-preview line is the one Copy as JPEG uses for the same case.
        #expect(CullWording.embeddedOnly.hasSuffix("this RAW couldn't be decoded on this iPhone."))
    }
}

@Suite("Loupe gestures and zoom")
struct LoupeGestureTests {
    @Test func aSwipeIsReadAlongItsLongerAxis() {
        #expect(LoupeSwipe.of(translationX: -80, translationY: 10) == .next)
        #expect(LoupeSwipe.of(translationX: 80, translationY: -10) == .previous)
        #expect(LoupeSwipe.of(translationX: 5, translationY: -120) == .keep)
        #expect(LoupeSwipe.of(translationX: -5, translationY: 120) == .reject)
    }

    @Test func shortAndDiagonalDragsAreNothing() {
        #expect(LoupeSwipe.of(translationX: -30, translationY: 0) == nil)
        #expect(LoupeSwipe.of(translationX: 0, translationY: 60) == nil)
        #expect(LoupeSwipe.of(translationX: 100, translationY: 100) == nil)
    }

    @Test func aQuickFlickCountsByWhereItWouldEnd() {
        #expect(LoupeSwipe.of(translationX: -20, translationY: 0, predictedX: -200, predictedY: 5) == .next)
        #expect(LoupeSwipe.of(translationX: 0, translationY: 30, predictedX: 0, predictedY: 300) == .reject)
    }

    @Test func zoomGoesToThePreviewsOwnPixelsWithinBounds() {
        // A 2,868-pixel-wide preview fitted 430 points wide on a 3× screen is 100 % at about 2.2×.
        let scale = LoupeZoom.maximumScale(pixelWidth: 2_868, pixelHeight: 1_912, fittingWidth: 430,
                                           fittingHeight: 800, displayScale: 3)
        #expect(abs(scale - 2_868.0 / 1_290.0) < 0.001)
        // A small preview still zooms to the minimum; a huge one stops at the ceiling.
        #expect(LoupeZoom.maximumScale(pixelWidth: 320, pixelHeight: 214, fittingWidth: 430, fittingHeight: 800,
                                       displayScale: 3) == LoupeZoom.minimumMaximum)
        #expect(LoupeZoom.maximumScale(pixelWidth: 60_000, pixelHeight: 40_000, fittingWidth: 430,
                                       fittingHeight: 800, displayScale: 3) == LoupeZoom.ceiling)
        // A portrait preview is limited by the height it fits: 4,000 × 6,000 into 430 × 600 points is 400 points wide.
        let portrait = LoupeZoom.maximumScale(pixelWidth: 4_000, pixelHeight: 6_000, fittingWidth: 430,
                                              fittingHeight: 600, displayScale: 3)
        #expect(abs(portrait - 4_000.0 / 1_200.0) < 0.001)
        #expect(LoupeZoom.maximumScale(pixelWidth: 0, pixelHeight: 0, fittingWidth: 0, fittingHeight: 0,
                                       displayScale: 0) == LoupeZoom.minimumMaximum)
        #expect(LoupeZoom.clamped(0.5, maximum: 3) == 1)
        #expect(LoupeZoom.clamped(5, maximum: 3) == 3)
        #expect(LoupeZoom.clamped(.nan, maximum: 3) == 1)
    }
}
