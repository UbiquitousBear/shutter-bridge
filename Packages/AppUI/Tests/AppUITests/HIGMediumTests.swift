import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

// The HIG review's medium items (6–19): what the screens say and do, as plain Swift. The views themselves (system
// toolbars, glass strips, focus) are compiled and run by CI's Xcode job.

/// HIG title-style capitalisation, as Apple writes it: every word capitalised except articles, coordinating
/// conjunctions and short prepositions, and the first and last words always.
enum TitleCase {
    static let minorWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
        "as", "at", "by", "in", "of", "off", "on", "per", "to", "up", "via", "over", "from", "into", "with",
    ]

    static func holds(_ title: String) -> Bool {
        let words = title.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard !words.isEmpty else { return false }
        for (index, word) in words.enumerated() {
            guard let first = word.first else { return false }
            let edge = index == 0 || index == words.count - 1
            if !edge, minorWords.contains(word.lowercased()) {
                if word != word.lowercased() { return false }
            } else if !first.isUppercase && !first.isNumber {
                return false
            }
        }
        return true
    }
}

@Suite("Titles and buttons in title case (HIG Writing)")
struct TitleCaseTests {
    @Test func theRuleItself() {
        #expect(TitleCase.holds("No Files over USB"))
        #expect(TitleCase.holds("Couldn't Read the Card"))
        #expect(TitleCase.holds("Camera Access Is Off"))
        #expect(TitleCase.holds("Share as JPEG…"))
        #expect(!TitleCase.holds("No camera connected"))
        #expect(!TitleCase.holds("No Files Over USB"))
        #expect(!TitleCase.holds("Nothing to import yet"))
    }

    @Test func theEmptyAndErrorStateTitlesAsDecided() {
        #expect(CamerasEmptyState.standard.title == "No Camera Connected")
        #expect(CamerasWording.notAllowedTitle == "Camera Access Is Off")
        #expect(BrowseWording.readingTitle == "Reading the Card")
        #expect(BrowseWording.noFilesTitle == "No Files over USB")
        #expect(BrowseWording.emptyCardTitle == "No Photos on the Card")
        #expect(BrowseWording.goneTitle == "Camera Disconnected")
        #expect(BrowseWording.listingFailedTitle == "Couldn't Read the Card")
        #expect(BrowseWording.noMatchesTitle == "No Matching Files")
        #expect(ImportWording.noJobTitle == "Nothing to Import")
        #expect(AppWording.catalogueFailedTitle == "Shutter Bridge Couldn't Start")
        #expect(BrowseWording.undatedHeader == "No Date")
    }

    @Test func everyTitleHeaderAndButtonIsInTitleCase() {
        let titles = [
            CamerasEmptyState.standard.title, CamerasEmptyState.standard.modeHelpButton,
            CamerasWording.title, CamerasWording.notAllowedTitle, CamerasWording.openSettings,
            CamerasWording.settingsButton,
            BrowseWording.readingTitle, BrowseWording.noFilesTitle, BrowseWording.emptyCardTitle,
            BrowseWording.goneTitle, BrowseWording.listingFailedTitle, BrowseWording.undatedHeader,
            BrowseWording.noMatchesTitle, BrowseWording.tryAgain, BrowseWording.close, BrowseWording.select,
            BrowseWording.doneSelecting, BrowseWording.selectAllNew, BrowseWording.deselectAll,
            BrowseWording.importAction, BrowseWording.selectItems, BrowseWording.filters, BrowseWording.newOnly,
            BrowseWording.type, BrowseWording.dateRange, BrowseWording.anyDate, BrowseWording.clearFilters,
            BrowseWording.limitDates, BrowseWording.readingTimesButton, BrowseWording.connectingTitle,
            BrowseWording.reconnect, WiFiWording.failedTitle,
            JPEGWording.copyAction, JPEGWording.shareAction, JPEGWording.cancel,
            SettingsWording.title, SettingsWording.stagingHeader, BrowseWording.stageAction,
            BrowseWording.importToPhotos, BrowseWording.stagedBadge,
            ImportWording.title, ImportWording.pause, ImportWording.resume, ImportWording.cancel,
            CamerasWording.discoveryFailedTitle,
            ImportWording.openSettings, ImportWording.filesHeader, ImportWording.noJobTitle,
            ImportWording.keepImporting, AppWording.catalogueFailedTitle, AppWording.tryAgain,
        ]
        for title in titles {
            #expect(TitleCase.holds(title), "\(title)")
        }
        // Apple's names keep their own case (iCloud, iPhone); the rest of the menu's titles are in title case.
        for title in [BrowseWording.stageInICloudDrive, BrowseWording.stageOnIPhone] {
            let apple = title.replacingOccurrences(of: "iCloud", with: "ICloud")
                .replacingOccurrences(of: "iPhone", with: "IPhone")
            #expect(TitleCase.holds(apple), "\(title)")
        }
        // Counted titles too.
        #expect(BrowseWording.selectingTitle(SelectionSummary(count: 3, bytes: 1)) == "3 Selected")
        #expect(TitleCase.holds(BrowseWording.selectingTitle(SelectionSummary(count: 3, bytes: 1))))
    }
}

@Suite("Browse wording for the bars, strips and VoiceOver")
struct BrowseBarWordingTests {
    @Test func selectingTitles() {
        #expect(BrowseWording.selectingTitle(SelectionSummary(count: 0, bytes: 0)) == "Select Items")
        #expect(BrowseWording.selectingTitle(SelectionSummary(count: 1, bytes: 9)) == "1 Selected")
    }

    @Test func theFiltersButtonSaysWhetherAFilterIsOn() {
        #expect(BrowseWording.filtersValue(isActive: true) == "On")
        #expect(BrowseWording.filtersValue(isActive: false) == "Off")
    }

    @Test func hintsDescribeTheResult() {
        #expect(BrowseWording.importStripHint == "Opens the import.")
        #expect(BrowseWording.close == "Close")
    }

    @Test func theLastKnownCardIsOneLineInFamiliarWords() {
        let line = BrowseWording.lastKnownLine("8 Nov 2026 at 14:05")
        #expect(line == "Showing the card as it was on 8 Nov 2026 at 14:05.")
        #expect(!line.lowercased().contains("listed") && !line.lowercased().contains("last-known"))
        #expect(BrowseWording.readingSubtitle == "Reading the card…")
    }

    @Test func theCellValueLeavesOutWhatTheLabelSays() {
        #expect(BrowseWording.cellAccessibilityValue(nil) == nil)
        #expect(BrowseWording.cellAccessibilityValue(.notAPhoto) == nil)
        #expect(BrowseWording.cellAccessibilityValue(.video) == "Videos can't be imported yet.")
        #expect(BrowseWording.cellAccessibilityValue(.noCaptureDate) == "No capture date, so it can't be imported yet.")
        #expect(BrowseWording.cellAccessibilityValue(.cardNotRead) == "Wait until the card has been read.")
        // The on-screen label stays Shamil's wording; VoiceOver hears the plain sentence.
        #expect(BrowseWording.videoLabel == "Video: from 1.1")
        #expect(BrowseWording.cellAccessibility(name: "C0001.MP4", date: "9 Nov", kind: .video, isImported: false)
            == "C0001.MP4, 9 Nov, Video")
        #expect(BrowseWording.cellAccessibility(name: "A.DAT", date: nil, kind: .other, isImported: false)
            == "A.DAT, No Date, Not a photo")
    }
}

// MARK: - Browse: selection like Photos, taps, the bar's title and subtitle

extension BrowseFullTests {
    @Test func theTitleReportsTheSelectionAndTheSubtitleItsSize() async {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        // The fake camera is in Image Transfer (MSC), where its name is the card's volume.
        #expect(h.model.navigationTitle == "Camera")
        #expect(h.model.navigationSubtitle == "Image Transfer (MSC)")
        h.model.isSelecting = true
        #expect(h.model.navigationTitle == "Select Items")
        #expect(h.model.navigationSubtitle == "Image Transfer (MSC)")
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(h.model.navigationTitle == "1 Selected")
        #expect(h.model.navigationSubtitle == ByteWording.size(22_000_000))
        h.model.toggleSelection(named("DSC00004.HIF"))
        #expect(h.model.navigationTitle == "2 Selected")
        #expect(h.model.navigationSubtitle == ByteWording.size(31_000_000))
        h.model.isSelecting = false
        #expect(h.model.navigationTitle == "Camera")
        #expect(h.model.navigationSubtitle == "Image Transfer (MSC)")
        await h.stop()
    }

    @Test func selectAllNewTurnsIntoDeselectAllWhichKeepsSelecting() async {
        let catalogue = InMemoryCatalogue(records: [importedRow("DSC00002.ARW", camera: descriptor)])
        let h = await start(catalogue: catalogue)
        #expect(await eventually { h.model.phase == .listed && !h.model.imported.isEmpty })
        h.model.isSelecting = true
        #expect(!h.model.allNewSelected)
        #expect(h.model.canToggleSelectAllNew)
        h.model.toggleSelectAllNew()
        #expect(h.model.allNewSelected)
        #expect(h.model.selectionSummary.count == 4)   // stills not imported, with a date
        h.model.toggleSelection(named("DSC00003.JPG"))
        #expect(!h.model.allNewSelected)   // Select All New again
        h.model.toggleSelectAllNew()
        #expect(h.model.allNewSelected)
        h.model.toggleSelectAllNew()   // Deselect All
        #expect(h.model.selection.isEmpty)
        #expect(h.model.isSelecting)
        #expect(!h.model.allNewSelected)
        await h.stop()
    }

    @Test func selectAllNewFollowsTheFilters() async {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        h.model.filter.types = [.raw]
        h.model.isSelecting = true
        h.model.toggleSelectAllNew()
        #expect(Set(h.model.selectedItems.map(\.name)) == ["DSC00001.ARW", "DSC00002.ARW"])
        #expect(h.model.allNewSelected)
        // Showing more files: not all of them are selected any more.
        h.model.filter.types = Set(BrowseFileType.allCases)
        #expect(!h.model.allNewSelected)
        await h.stop()
    }

    @Test func withNothingToSelectTheLeadingButtonHasNothingToDo() async {
        let h = await start(items: [item("C0001.MP4", at: 5), item("DSC00005.JPG", at: nil)])
        #expect(await eventually { h.model.phase == .listed })
        h.model.isSelecting = true
        #expect(!h.model.allNewSelected)
        #expect(!h.model.canToggleSelectAllNew)
        await h.stop()
    }

    @Test func aTapStartsSelectingWithThatFileThenSelectsAndDeselects() async {
        let h = await start()
        #expect(await eventually { h.model.phase == .listed })
        // Files that can't be imported do nothing outside the selecting mode, so they aren't announced as buttons.
        #expect(!h.model.respondsToTap(named("C0001.MP4")) && !h.model.respondsToTap(named("DSC00005.JPG")))
        #expect(h.model.respondsToTap(named("DSC00003.JPG")))
        h.model.tap(named("C0001.MP4"))
        h.model.tap(named("DSC00005.JPG"))
        #expect(!h.model.isSelecting)
        h.model.tap(named("DSC00003.JPG"))
        #expect(h.model.isSelecting)
        #expect(h.model.selectedItems.map(\.name) == ["DSC00003.JPG"])
        h.model.tap(named("DSC00004.HIF"))
        #expect(Set(h.model.selectedItems.map(\.name)) == ["DSC00003.JPG", "DSC00004.HIF"])
        h.model.tap(named("DSC00003.JPG"))
        #expect(h.model.selectedItems.map(\.name) == ["DSC00004.HIF"])
        h.model.tap(named("C0001.MP4"))
        #expect(h.model.selectedItems.map(\.name) == ["DSC00004.HIF"])
        #expect(h.model.respondsToTap(named("DSC00004.HIF")) && !h.model.respondsToTap(named("C0001.MP4")))
        await h.stop()
    }

    @Test func whileTheCardIsReadTheBarSaysSoAndATapDoesNothing() async throws {
        let camera = descriptor
        let listedAt = Date(timeIntervalSince1970: 1_792_000_000)
        let catalogue = InMemoryCatalogue()
        await catalogue.saveListing(CardListing(camera: key(camera), listedAt: listedAt, entries: card.prefix(2).map {
            CardListing.Entry(identity: $0.identity(camera: key(camera), timeZone: .current)!, format: $0.format)
        }))
        let h = await start(catalogue: catalogue, listHangs: true)
        #expect(await eventually { h.model.lastKnownListedAt == listedAt })
        guard case .reading = h.model.phase else {
            Issue.record("expected the card to be still reading, got \(h.model.phase)")
            await h.link.set(listHangs: false)
            await h.stop()
            return
        }
        #expect(h.model.navigationTitle == "Camera")
        #expect(h.model.navigationSubtitle == "Reading the card…")
        let shown = try #require(h.model.sections.first?.items.first)
        h.model.tap(shown)
        #expect(!h.model.isSelecting)
        #expect(h.model.accessibilityValue(for: shown) == "Wait until the card has been read.")
        await h.link.set(listHangs: false)
        #expect(await eventually { h.model.phase == .listed })
        #expect(h.model.navigationSubtitle == "Image Transfer (MSC)")
        await h.stop()
    }
}

// MARK: - Import: one button pauses and continues

extension ImportModelTests {
    @Test func oneButtonPausesAndContinues() async {
        #expect(ImportModel.PauseControl.pause.title == "Pause")
        #expect(ImportModel.PauseControl.pause.systemImage == "pause.fill")
        #expect(ImportModel.PauseControl.resume.title == "Continue")
        #expect(ImportModel.PauseControl.resume.systemImage == "play.fill")

        let h = await harness(hangs: true)
        #expect(h.model.pauseControl == nil)   // no job
        _ = await h.importAll(card)
        #expect(await eventually { await h.link.bytesStarted == 1 })
        #expect(h.model.pauseControl == .pause)
        await h.model.togglePause()
        #expect(h.model.state == .paused(.byPerson))
        #expect(h.model.pauseControl == .resume)
        await h.model.togglePause()
        #expect(h.model.state == .running)
        #expect(h.model.pauseControl == .pause)
        // Waiting for a removed camera: only the camera coming back lifts it, so there is no button.
        await h.link.remove()
        #expect(await h.state(.paused(.cameraRemoved)))
        #expect(h.model.pauseControl == nil)
        await h.model.togglePause()
        #expect(h.model.state == .paused(.cameraRemoved))
        await h.model.cancel()
        #expect(await h.finished())
        #expect(h.model.pauseControl == nil)
    }
}

// MARK: - Settings: what Photos access does to Import to Photos

@MainActor
@Suite("Settings: what Photos access does to Import to Photos")
struct SettingsPhotosAccessTests {
    @Test func aDenialSaysImportToPhotosStagesAndOffersSettings() async {
        let photos = FakePhotosAccess(.denied)
        let model = SettingsModel(photos: photos)
        #expect(model.photosAccess == nil)   // not read yet: nothing said
        #expect(model.forcedStagingLine == nil)
        await model.refresh()
        #expect(model.photosAccess == .denied)
        #expect(model.forcedStagingReason == .photosDenied)
        #expect(model.forcedStagingLine == "Photos access is off, so Import to Photos stages the photos instead.")
        #expect(model.offersPhotosSettingsLink)
        #expect(photos.askCount == 0)   // reading never asks: that is the first Import's job
    }

    @Test func aRestrictionSaysSoWithoutASettingsButton() async {
        let model = SettingsModel(photos: FakePhotosAccess(.restricted))
        await model.refresh()
        #expect(model.forcedStagingReason == .photosRestricted)
        #expect(model.forcedStagingLine
            == "Photos is restricted on this iPhone, so Import to Photos stages the photos instead.")
        #expect(!model.offersPhotosSettingsLink)
    }

    @Test func havingAccessSaysNothing() async {
        let photos = FakePhotosAccess(.denied)
        let model = SettingsModel(photos: photos)
        for access in [PhotosAuthorisation.authorised, .limited, .notDetermined] {
            photos.set(access)
            await model.refresh()
            #expect(model.photosAccess == access)
            #expect(model.forcedStagingLine == nil, "\(access)")
            #expect(!model.offersPhotosSettingsLink, "\(access)")
        }
    }

    @Test func withoutAWayToReadAccessNothingIsSaid() async {
        let model = SettingsModel()
        await model.refresh()
        #expect(model.photosAccess == nil)
        #expect(model.forcedStagingLine == nil)
    }

    @Test func theAppReadsAccessAgainWhenItComesBack() async {
        let photos = FakePhotosAccess(.authorised)
        let catalogue = InMemoryCatalogue()
        let app = AppModel(discovery: FakeDiscovery(link: FakeLink(items: [])), services: services(),
                           catalogue: catalogue,
                           engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                           settingsStore: InMemoryDestinationSettingStore(), photos: photos,
                           destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
        await app.scenePhaseChanged(.active)
        #expect(app.settings.photosAccess == .authorised)
        #expect(app.settings.forcedStagingLine == nil)
        // Where staging goes is read with it (the fakes stage on this iPhone).
        #expect(app.settings.stagingPlace == testStagingPlace)
        // Turned off in Settings while the app was away.
        photos.set(.denied)
        await app.scenePhaseChanged(.background)
        #expect(app.settings.photosAccess == .authorised)
        await app.scenePhaseChanged(.active)
        #expect(app.settings.forcedStagingLine == "Photos access is off, so Import to Photos stages the photos instead.")
        #expect(photos.askCount == 0)
    }
}
