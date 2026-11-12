import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPSimulator
import SimulatedLink
import Testing
@testable import AppUI

/// Section 1's remaining identity items (I14) through the app's models: a card relisted with the phone 9 hours away
/// has nothing new for *Select All New*, and files without a capture date are left out with a line saying how many
/// and why (D10).
@MainActor
@Suite("The capture time's zone and undated files in Browse and Import", .serialized, .timeLimit(.minutes(5)))
struct CaptureZoneAndUndatedTests {
    /// A fixed zone 9 hours from the one Browse reads in (`TimeZone.current`), east or west so it stays a real offset.
    static var nineHoursAway: TimeZone {
        let here = TimeZone.current.secondsFromGMT()
        return TimeZone(secondsFromGMT: here + (here > 0 ? -9 : 9) * 3600)!
    }

    @Test func aCardRelisted9HoursAwayHasNothingNewForSelectAllNew() async throws {
        let bench = try await SimulatorBench.make(setting: .photos)
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        browse.selectAllNew()
        #expect(await browse.importSelected() == .started(importableStills.count))
        try await bench.untilImport(.finished(.completed))
        await bench.stopBrowsing()

        // The same camera, its card listed with the phone 9 hours away: every date is a different instant now.
        let away = Self.nineHoursAway
        let relisting = SimulatedCameraLink(card: await bench.link.card, mode: bench.camera.mode,
                                            name: bench.camera.name, descriptorID: bench.camera.id.rawValue,
                                            timeZone: away, generation: bench.link.generation + 1, chunkSize: 4096)
        try await bench.plug(relisting)
        let again = bench.browse()
        try await bench.until("the card to be listed again") { again.phase == .listed }
        let still = try #require(again.shown("DSC00001.ARW"))
        #expect(still.captureTimeZone == away)
        try await bench.until("the badges") { again.imported.count == importableStills.count }
        #expect(Set(again.shown.filter(again.isImported).map(\.name)) == importableStills)
        again.selectAllNew()
        #expect(again.selection.isEmpty)
        for item in again.shown where importableStills.contains(item.name) {
            #expect(await bench.state(of: item) == .imported, "\(item.name)")
        }
        await bench.expectInPhotos(importableStills)   // nothing went twice
        await bench.finish()
    }

    @Test func undatedFilesAloneStartNoJob() async throws {
        let bench = try await SimulatorBench.make(setting: .photos)
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        let undated = try #require(browse.shown("DSC00004.ARW"))
        #expect(browse.selectionBlock(for: undated) == .noCaptureDate)   // Browse's dimmed state stays
        let outcome = await bench.importer.importItems(
            [undated], from: ImportCamera(descriptor: bench.camera, key: bench.key), link: bench.link, as: .photos,
            newOnly: true)
        #expect(outcome == .nothingNew(staging: false))
        #expect(!bench.importer.hasJob)
        #expect(bench.importer.undatedLine == nil)
        await bench.finish()
    }

    @Test func theLeftOutLineSaysHowManyAndWhy() {
        #expect(ImportWording.undatedLeftOut(0) == nil)
        #expect(ImportWording.undatedLeftOut(1) == "1 file was left out because it has no capture date, so Shutter "
            + "Bridge can't tell whether it was imported before.")
        #expect(ImportWording.undatedLeftOut(3) == "3 files were left out because they have no capture date, so "
            + "Shutter Bridge can't tell whether they were imported before.")
        for line in [1, 2].compactMap(ImportWording.undatedLeftOut) {
            #expect(line.hasSuffix("."))
            #expect(!line.lowercased().contains("sony"))
        }
    }

    @Test func theProgressCountsTheUndatedLine() {
        let p = ImportProgress(filesDone: 7, filesTotal: 7, bytesDone: 1, bytesTotal: 1, state: .finished(.completed),
                               filesSkipped: 2, filesUndated: 2)
        #expect(ImportWording.counts(p) == "5 files imported, 2 skipped.")
        #expect(ImportWording.undatedLeftOut(p.filesUndated) == ImportWording.undatedLeftOut(2))
    }
}
