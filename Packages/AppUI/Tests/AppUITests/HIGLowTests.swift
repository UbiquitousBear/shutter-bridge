import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Testing
@testable import AppUI

// The HIG review's low items (20–32) that are plain Swift: the system formatters for sizes and times, the haptic
// rules, the strips in compact height, the discovery failure and the wording polish. The SwiftUI side (launch shell,
// glass day headers, close buttons, selection mark, landscape) is compiled and run by CI's Xcode job.

/// A formatted size or time with its spaces made plain and its letters lower case, so a check holds on Linux and on
/// iOS whichever space (U+0020, U+00A0, U+202F) and unit case ("kB" or "KB") the formatter's data uses.
private func plain(_ text: String) -> String {
    String(text.map { $0 == "\u{00A0}" || $0 == "\u{202F}" ? " " : $0 }).lowercased()
}

private let britishEnglish = Locale(identifier: "en_GB")
private let german = Locale(identifier: "de_DE")

@Suite("Sizes, rates and times through the system formatters (item 27)")
struct SystemFormatterTests {
    @Test func sizesAreDecimalUnitsInTheRegionsNotation() {
        #expect(plain(ByteWording.size(42_349_999, locale: britishEnglish)) == "42.3 mb")
        #expect(plain(ByteWording.size(42_349_999, locale: german)) == "42,3 mb")   // a decimal comma, not "."
        #expect(plain(ByteWording.size(1_240_000_000, locale: britishEnglish)) == "1.24 gb")
        #expect(plain(ByteWording.size(1_240_000_000, locale: german)) == "1,24 gb")
        // The file style's decimal units, as the bench measured: 10^6 bytes is 1 MB, not 976.6 KB.
        #expect(plain(ByteWording.size(1_000_000, locale: britishEnglish)) == "1 mb")
        let small = plain(ByteWording.size(512, locale: britishEnglish))
        #expect(small.hasPrefix("512") && small.contains("byte"))
        // Zero is a digit, never "Zero KB".
        let zero = plain(ByteWording.size(0, locale: britishEnglish))
        #expect(zero.hasPrefix("0") && !zero.contains("zero"))
    }

    @Test func progressAndRateAreBuiltFromTheSameSizes() {
        #expect(ByteWording.progress(1_200_000_000, of: 4_500_000_000, locale: britishEnglish)
            == "\(ByteWording.size(1_200_000_000, locale: britishEnglish)) of "
            + "\(ByteWording.size(4_500_000_000, locale: britishEnglish))")
        #expect(plain(ByteWording.rate(megabytesPerSecond: 41.83, locale: britishEnglish)) == "41.8 mb/s")
        #expect(plain(ByteWording.rate(megabytesPerSecond: 41.83, locale: german)) == "41,8 mb/s")
        // VoiceOver hears words, not "/s".
        #expect(plain(ByteWording.rateSpoken(megabytesPerSecond: 41.83, locale: britishEnglish))
            == "41.8 mb per second")
        // A rate that isn't a number yet reads as nothing per second rather than trapping.
        #expect(plain(ByteWording.rate(megabytesPerSecond: .nan, locale: britishEnglish)).hasPrefix("0"))
    }

    @Test func timeLeftIsRoundedUpNeverZero() {
        #expect(ByteWording.roundedTimeLeft(.seconds(0)) == .seconds(1))
        #expect(ByteWording.roundedTimeLeft(.seconds(0.2)) == .seconds(1))
        #expect(ByteWording.roundedTimeLeft(.seconds(40)) == .seconds(40))
        #expect(ByteWording.roundedTimeLeft(.seconds(59.5)) == .seconds(60))
        #expect(ByteWording.roundedTimeLeft(.seconds(150)) == .seconds(180))
        #expect(ByteWording.roundedTimeLeft(.seconds(3_900)) == .seconds(3_900))
        #expect(ByteWording.roundedTimeLeft(.seconds(3_901)) == .seconds(3_960))
    }

    @Test func timeLeftUsesTheSystemsUnits() {
        let forty = ByteWording.timeLeft(.seconds(40), locale: britishEnglish)
        #expect(forty.hasPrefix("About ") && forty.hasSuffix(" left") && forty.contains("40"))
        #expect(!forty.contains(" s left"))   // not the app's own "s", which VoiceOver may read as a letter
        // 150 s shows as 3 minutes, as the rounding says.
        #expect(ByteWording.timeLeft(.seconds(150), locale: britishEnglish)
            == ByteWording.timeLeft(.seconds(180), locale: britishEnglish))
        #expect(ByteWording.timeLeft(.seconds(150), locale: britishEnglish)
            != ByteWording.timeLeft(.seconds(120), locale: britishEnglish))
        // At most two units: hours and minutes, no seconds.
        let longer = ByteWording.timeLeft(.seconds(3_900), locale: britishEnglish)
        #expect(longer.contains("1") && longer.contains("5") && !plain(longer).contains("sec"))
        // VoiceOver hears whole words.
        #expect(plain(ByteWording.timeLeftSpoken(.seconds(40), locale: britishEnglish)) == "about 40 seconds left")
        #expect(plain(ByteWording.timeLeftSpoken(.seconds(150), locale: britishEnglish)) == "about 3 minutes left")
        #expect(plain(ByteWording.timeLeftSpoken(.seconds(3_900), locale: britishEnglish)).contains("1 hour"))
        #expect(!plain(ByteWording.timeLeft(.seconds(150), locale: britishEnglish)).contains("minutes"))
    }
}

@Suite("Haptics for outcomes (item 23)")
struct OutcomeFeedbackTests {
    @Test func copyAndShareAsJPEG() {
        #expect(OutcomeFeedback.forJPEGAction(.finished("Copied DSC00001 as a JPEG.")) == .success)
        #expect(OutcomeFeedback.forJPEGAction(.failed("The camera didn't answer. Try again.")) == .error)
        #expect(OutcomeFeedback.forJPEGAction(.idle) == nil)   // also where a cancel leaves it
        let work = JPEGWork(id: 1, purpose: .copy, name: "DSC00001.ARW", stage: .fetching(written: 1, total: 2))
        #expect(OutcomeFeedback.forJPEGAction(.working(work)) == nil)
    }

    private func state(_ job: ImportJobState, automaticRetry: Bool = false,
                       failed: Int = 0) -> ImportFeedbackState {
        ImportFeedbackState(state: ImportWording.AnnouncedState(state: job, isAutomaticRetry: automaticRetry),
                            failedFiles: failed)
    }

    @Test func theImportsOutcome() {
        let running = state(.running)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.finished(.completed))) == .success)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.finished(.completed), failed: 2)) == .warning)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.finished(.stopped(.phoneStorageFull)))) == .error)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.finished(.catalogueUnavailable))) == .error)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.finished(.cancelled))) == nil)   // their choice
    }

    @Test func pausesThatNeedThePersonWarnOthersAreQuiet() {
        let running = state(.running)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.cameraRemoved))) == .warning)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.stalled))) == .warning)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.stalled), automaticRetry: true)) == nil)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.byPerson))) == nil)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.appInBackground))) == nil)
        // Wi-Fi's reasons (W7): waiting for the camera, its card or a join is a warning; iOS ending the background
        // time is the app's leaving, so nothing plays.
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.cameraUnreachable))) == .warning)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.cardUnavailable))) == .warning)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.needsJoin))) == .warning)
        #expect(OutcomeFeedback.forImport(from: running, to: state(.paused(.taskExpired))) == nil)
        // Starting and carrying on are progress, not outcomes; the same state twice plays nothing.
        #expect(OutcomeFeedback.forImport(from: state(.idle), to: running) == nil)
        #expect(OutcomeFeedback.forImport(from: state(.paused(.cameraRemoved)), to: running) == nil)
        let finished = state(.finished(.completed))
        #expect(OutcomeFeedback.forImport(from: finished, to: finished) == nil)
    }

    @MainActor @Test func noJobHasNothingToFeel() {
        let model = ImportModel(engine: ImportEngine(catalogue: InMemoryCatalogue(), stagingDirectory: temporaryStaging()),
                                settings: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                                destinations: FakeDestinations())
        #expect(model.feedbackState == ImportFeedbackState(state: model.announcedState, failedFiles: 0))
        #expect(model.rateSpokenLine == nil && model.timeLeftSpokenLine == nil)
    }
}

@Suite("Strips in compact height and at large text sizes (items 9 and 32)")
struct StripLayoutTests {
    @Test func linesAndSpacing() {
        #expect(StripLayout.lineLimit(isAccessibilitySize: false, isCompactHeight: false) == nil)
        #expect(StripLayout.lineLimit(isAccessibilitySize: true, isCompactHeight: false) == 3)
        // Landscape on iPhone: one line each, whatever the text size, so the card stays in view.
        #expect(StripLayout.lineLimit(isAccessibilitySize: false, isCompactHeight: true) == 1)
        #expect(StripLayout.lineLimit(isAccessibilitySize: true, isCompactHeight: true) == 1)
        #expect(StripLayout.spacing(isCompactHeight: true) < StripLayout.spacing(isCompactHeight: false))
    }

    /// A problem notice stays until closed and ends with its next step, so landscape and large text never cut it
    /// to its first words: three lines in compact height, no limit at the accessibility sizes.
    @Test func problemNoticesKeepTheirNextStep() {
        #expect(StripLayout.lineLimit(isAccessibilitySize: false, isCompactHeight: false, isProblem: true) == nil)
        #expect(StripLayout.lineLimit(isAccessibilitySize: true, isCompactHeight: false, isProblem: true) == nil)
        #expect(StripLayout.lineLimit(isAccessibilitySize: false, isCompactHeight: true, isProblem: true) == 3)
        #expect(StripLayout.lineLimit(isAccessibilitySize: true, isCompactHeight: true, isProblem: true) == nil)
        // Confirmations still collapse.
        #expect(StripLayout.lineLimit(isAccessibilitySize: false, isCompactHeight: true, isProblem: false) == 1)
    }
}

@MainActor
@Suite("A discovery failure isn't \"No Camera Connected\" (item 30)")
struct DiscoveryFailureTests {
    @Test func aFailureToStartIsSaidAndTryAgainStartsAgain() async {
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        await discovery.allow()
        await discovery.set(failure: .noAnswer)
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        #expect(model.access == .failed)
        #expect(!model.isLooking)
        // Try Again calls becameActive(); once discovery starts, the empty state (or the cameras) shows.
        await discovery.set(failure: nil)
        await model.becameActive()
        #expect(model.access == .allowed)
        #expect(model.isLooking)
        #expect(await discovery.starts == 2)
    }

    @Test func aRefusalIsStillAccessNotAFailure() async {
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        #expect(model.access == .notAllowed)
    }

    @Test func theWords() {
        #expect(CamerasWording.discoveryFailedTitle == "Can't Look for Cameras")
        #expect(TitleCase.holds(CamerasWording.discoveryFailedTitle))
        #expect(CamerasWording.discoveryFailedDetail.hasSuffix("Tap Try Again."))
    }
}

@Suite("Wording polish (items 20, 22, 28 and 29)")
struct WordingPolishTests {
    @Test func oneWordPerIdea() {
        let raw = item("DSC00001.ARW")
        #expect(ImportWording.row(.committing, item: raw, going: .staging) == "Saving to Staging")
        // A row written by an earlier build's Files folder still reads as it did.
        #expect(ImportWording.row(.imported(.file(relativePath: "Camera/DSC00001.ARW")), item: raw, going: .staging)
            == "Imported to Files")
        #expect(ImportWording.destination(.stagedHere(.chosen), folder: "Camera", finished: true, imported: 1)?
            .hasPrefix("Staged in") == true)
        #expect(ImportWording.paused(.byPerson) == "Paused. Tap Continue to resume.")
        #expect(ImportWording.cancelConfirmDetail == "Files already imported are kept. The rest stay on the card.")
        #expect(BrowseWording.emptyCardDetail == "There are no files on the card.")
    }

    @Test func theImportRowSaysVideosPlainly() {
        let video = item("C0001.MP4")
        let row = ImportWording.row(.skipped(.notAStill), item: video, going: .photos)
        #expect(row == "Skipped: videos can't be imported yet")
        #expect(row.hasSuffix(String(BrowseWording.videosNotYet.lowercased().dropLast())))   // as VoiceOver says
        #expect(!row.contains("1.1"))
        #expect(BrowseWording.videoLabel == "Video: from 1.1")   // the on-screen label stays (Shamil, 9 Nov)
    }

    @Test func neverAskToRestartTheApp() {
        let detail = AppWording.catalogueFailedDetail
        #expect(!detail.lowercased().contains("restart") && !detail.lowercased().contains("quit"))
        #expect(detail.contains("Try Again"))
        // One next step, said once.
        #expect(detail.components(separatedBy: "Try Again").count == 2)
        #expect(AppWording.spinnerDelay == .milliseconds(500))
    }

    @Test func everyJPEGFailureGivesANextStep() {
        var lines = CameraLinkFailure.Kind.allCases.compactMap { JPEGWording.failed(.link(CameraLinkFailure($0))) }
        lines += [JPEGActionFailure.conversion(detail: ""), .storage(detail: ""), .clipboard(detail: ""),
                  .shareUnavailable].compactMap(JPEGWording.failed)
        for line in lines {
            // What happened, then what to do: at least two sentences.
            #expect(line.components(separatedBy: ". ").count >= 2, "\(line)")
        }
        #expect(JPEGWording.failed(.clipboard(detail: "")) == "The JPEG couldn't be copied. Try again, or use Share as JPEG.")
    }
}
