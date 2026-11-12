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
        let all = [CullWording.title, CullWording.emptyTitle, CullWording.emptyDetail,
                   CullWording.loadFailedTitle, CullWording.loadFailedDetail, CullWording.dayHint,
                   CullWording.loupeHint, CullWording.writeFailed, CullWording.embeddedOnly,
                   CullWording.previewFailedTitle, CullWording.downloading, CullWording.zoomIn,
                   CullWording.zoomInPreview, CullWording.zoomOut, CullWording.refreshFailed,
                   CullWording.nextPhoto, CullWording.previousPhoto]
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

    @Test func zoomReachesTheOriginalsOwnPixelsWhenItCanBeDecoded() {
        // An α7C II frame (7008 × 4672) shown by a screen-sized preview, fitted 393 points wide on a 3× screen: its
        // 100 % is the original's, about 5.9×, not the preview's 2,556 pixels (about 2.2×).
        let decodable = LoadedPreview(image: "", pixelSize: PixelSize(width: 2_556, height: 1_704), quality: .final,
                                      fullPixelSize: PixelSize(width: 7_008, height: 4_672))
        let scale = LoupeZoom.maximumScale(for: decodable, fittingWidth: 393, fittingHeight: 700, displayScale: 3)
        #expect(abs(scale - 7_008.0 / 1_179.0) < 0.001)
        // A portrait frame fitted by its height (400 of 430 points wide) still reaches the original's 100 %.
        let portrait = LoadedPreview(image: "", pixelSize: PixelSize(width: 1_704, height: 2_556), quality: .final,
                                     fullPixelSize: PixelSize(width: 4_672, height: 7_008))
        let upright = LoupeZoom.maximumScale(for: portrait, fittingWidth: 430, fittingHeight: 600, displayScale: 3)
        #expect(abs(upright - 4_672.0 / 1_200.0) < 0.001)
        // A RAW shown by its embedded preview has only the preview's pixels.
        let embedded = LoadedPreview(image: "", pixelSize: PixelSize(width: 2_556, height: 1_704),
                                     quality: .embeddedOnly)
        #expect(abs(LoupeZoom.maximumScale(for: embedded, fittingWidth: 393, fittingHeight: 700, displayScale: 3)
            - 2_556.0 / 1_179.0) < 0.001)
        #expect(LoupeZoom.maximumScale(for: Optional<LoadedPreview<String>>.none, fittingWidth: 393, fittingHeight: 700,
                                       displayScale: 3) == LoupeZoom.minimumMaximum)
    }

    @Test func theVisibleRegionFollowsTheZoomAndThePan() throws {
        // 3:2 fitted into 300 × 400 points: 300 × 200, centred.
        #expect(LoupeZoom.visibleRegion(scale: 1, offsetX: 0, offsetY: 0, fittingWidth: 300, fittingHeight: 400,
                                        aspect: 1.5) == .whole)
        // At 2× the middle half of each side.
        let middle = try #require(LoupeZoom.visibleRegion(scale: 2, offsetX: 0, offsetY: 0, fittingWidth: 300,
                                                          fittingHeight: 400, aspect: 1.5))
        #expect(abs(middle.x - 0.25) < 1e-9 && abs(middle.width - 0.5) < 1e-9)
        // 400 points of a 400-point-high photo: all its height.
        #expect(abs(middle.y) < 1e-9 && abs(middle.height - 1) < 1e-9)
        // Panned right by 150 points (the photo moves right): its left quarter-to-half is shown.
        let left = try #require(LoupeZoom.visibleRegion(scale: 2, offsetX: 150, offsetY: 0, fittingWidth: 300,
                                                        fittingHeight: 400, aspect: 1.5))
        #expect(abs(left.x) < 1e-9 && abs(left.width - 0.5) < 1e-9)
        // Panned right off the photo altogether: nothing.
        #expect(LoupeZoom.visibleRegion(scale: 2, offsetX: 1_000, offsetY: 0, fittingWidth: 300, fittingHeight: 400,
                                        aspect: 1.5) == nil)
    }

    @Test func theOriginalIsDecodedOnlyPastThePreviewsOwnPixels() {
        let preview = LoadedPreview(image: "", pixelSize: PixelSize(width: 2_358, height: 1_572), quality: .final,
                                    fullPixelSize: PixelSize(width: 7_008, height: 4_672))
        // 2,358 pixels fitted 393 points wide at 3× is the preview's 100 % at 2×.
        func region(at scale: Double) -> LoupeRegion? {
            LoupeZoom.detailRegion(for: preview, scale: scale, offsetX: 0, offsetY: 0, fittingWidth: 393,
                                   fittingHeight: 700, displayScale: 3)
        }
        #expect(region(at: 1) == nil)
        #expect(region(at: 2) == nil)
        let deep = region(at: 5)
        #expect(deep != nil)
        #expect(abs((deep?.width ?? 0) - 0.2) < 1e-9)
    }

    @Test func aRegionIsClippedToThePhoto() {
        #expect(LoupeRegion(x: -0.5, y: 0.5, width: 1, height: 1).clipped
            == LoupeRegion(x: 0, y: 0.5, width: 0.5, height: 0.5))
        #expect(LoupeRegion(x: 1, y: 0, width: 1, height: 1).clipped == nil)
        #expect(LoupeRegion(x: .nan, y: 0, width: 1, height: 1).clipped == nil)
    }
}
