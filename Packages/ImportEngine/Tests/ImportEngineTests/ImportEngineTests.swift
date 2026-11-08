import CameraTransport
import Catalogue
import Foundation
import PhotosBridge
import Testing
@testable import ImportEngine

@Suite("Import progress")
struct ImportProgressTests {
    @Test func fractionAndRemainingAreInBytes() {
        let p = ImportProgress(filesDone: 1, filesTotal: 4, bytesDone: 25, bytesTotal: 100)
        #expect(p.fractionCompleted == 0.25)
        #expect(p.bytesRemaining == 75)
        #expect(ImportProgress.none.fractionCompleted == 0)
        let over = ImportProgress(filesDone: 1, filesTotal: 1, bytesDone: 120, bytesTotal: 100)
        #expect(over.fractionCompleted == 1)
        #expect(over.bytesRemaining == 0)
    }

    @Test func etaNeedsAPositiveRate() {
        // 100 files as 50 RAW+JPEG pairs, about 3.2 GB (backlog, exit criteria), at MSC's 40 MB/s: 80 s.
        var p = ImportProgress(filesDone: 0, filesTotal: 100, bytesDone: 0, bytesTotal: 3_200_000_000)
        #expect(p.estimatedTimeRemaining == nil)
        p.bytesPerSecond = 0
        #expect(p.estimatedTimeRemaining == nil)
        p.bytesPerSecond = .infinity
        #expect(p.estimatedTimeRemaining == nil)
        p.bytesPerSecond = 40_000_000
        #expect(p.estimatedTimeRemaining == .seconds(80))
        #expect(p.megabytesPerSecond == 40)
    }
}

@Suite("Selection and settings")
struct ImportSelectionTests {
    @Test func onlyAnExplicitPickOfNothingIsEmpty() {
        #expect(ImportSelection.items([]).isEmpty)
        #expect(!ImportSelection.allNew.isEmpty)
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(!ImportSelection.dateRange(now ... now).isEmpty)
    }

    @Test func downloadsInFlightIsOneOrTwo() {
        #expect(ImportSettings().downloadsInFlight == 1)
        #expect(ImportSettings(downloadsInFlight: 2).downloadsInFlight == 2)
        #expect(ImportSettings(downloadsInFlight: 0).downloadsInFlight == 1)
        var s = ImportSettings()
        s.downloadsInFlight = 5
        #expect(s.downloadsInFlight == 2)
    }

    @Test func decodingClampsDownloadsInFlight() throws {
        let decode = { (json: String) in try JSONDecoder().decode(ImportSettings.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"downloadsInFlight":5}"#).downloadsInFlight == 2)
        #expect(try decode(#"{"downloadsInFlight":0}"#).downloadsInFlight == 1)
        #expect(try decode(#"{"downloadsInFlight":-1}"#).downloadsInFlight == 1)
        #expect(try decode(#"{}"#).downloadsInFlight == 1)
        let round = try JSONEncoder().encode(ImportSettings(downloadsInFlight: 2))
        #expect(try JSONDecoder().decode(ImportSettings.self, from: round).downloadsInFlight == 2)
    }
}

actor NoLink: CameraLink {
    nonisolated let descriptor = CameraDescriptor(id: .init(rawValue: "none"), name: "None", mode: .usb(.massStorage))
    nonisolated let events = AsyncStream<CameraLinkEvent> { $0.finish() }
    func open() throws(CameraLinkFailure) {}
    func list() throws(CameraLinkFailure) -> [CameraItem] { [] }
    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem { throw CameraLinkFailure(.itemNotFound) }
    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data() }
    func bytes(of item: CameraItem.ID, into directory: URL,
               progress: @escaping @Sendable (UInt64) -> Void) throws(CameraLinkFailure) -> URL {
        throw CameraLinkFailure(.itemNotFound)
    }
    func close() {}
}

struct NoDestination: ImportDestination {
    let kind: DestinationKind = .photos
    func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        throw .rejected(detail: "test")
    }
}

@Suite("The engine's surface, before the stages exist")
struct ImportEngineSurfaceTests {
    @Test func startsIdleWithDefaultSettings() async {
        let engine = ImportEngine(catalogue: InMemoryCatalogue())
        #expect(await engine.state == .idle)
        #expect(await engine.settings.downloadsInFlight == 1)
    }

    @Test func refusesRatherThanPretending() async {
        let engine = ImportEngine(catalogue: InMemoryCatalogue())
        await #expect(throws: ImportEngineError.emptySelection) {
            try await engine.start(.items([]), from: NoLink(), to: NoDestination())
        }
        await #expect(throws: ImportEngineError.notBuilt) {
            try await engine.start(.allNew, from: NoLink(), to: NoDestination())
        }
        #expect(await engine.state == .idle)
    }

    @Test func controlsNeedAJob() async {
        let engine = ImportEngine(catalogue: InMemoryCatalogue())
        await #expect(throws: ImportEngineError.noJob) { try await engine.pause() }
        await #expect(throws: ImportEngineError.noJob) { try await engine.resume() }
        await #expect(throws: ImportEngineError.noJob) { try await engine.append([]) }
        await engine.cancel()
        #expect(await engine.state == .idle)
    }

    @Test func activeStates() {
        #expect(ImportJobState.running.isActive)
        #expect(ImportJobState.paused(.appInBackground).isActive)
        #expect(!ImportJobState.idle.isActive)
        #expect(!ImportJobState.finished(.stopped(.phoneStorageFull)).isActive)
    }
}
