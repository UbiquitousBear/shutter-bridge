import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing

/// RAW+JPEG pairs through the engine against the simulated link (section 7.1 of docs/iteration-2-backlog.md, I6): each
/// frame's ARW and JPG become one Photos asset through the real Photos destination over a fake library, and one stage
/// job puts both in one day folder.
@Suite("RAW+JPEG pairs against the simulated link", .timeLimit(.minutes(1)))
struct EnginePairsAgainstSimulatorTests {
    /// Three RAW+JPEG frames and a JPEG, scaled down by 1,000.
    private func shoot() throws -> ScriptedCard {
        try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 1000)
    }

    private func photosRoute(_ bench: Bench, _ library: RecordingLibrary) -> ImportRoute {
        let photos = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(),
                                              albumPlan: AlbumPlan(albums: []))
        return .photos(photos, staging: bench.files, onThisIPhone: bench.files, stagingPlace: Bench.place,
                       authorisation: { .authorised })
    }

    @Test func eachFrameIsOnePhotosAsset() async throws {
        let bench = Bench(downloadsInFlight: 2)
        let card = try shoot()
        let link = bench.link(card)
        let library = RecordingLibrary()
        try await link.open()
        try await bench.engine.start(.allNew, from: link, camera: bench.camera, to: photosRoute(bench, library))
        #expect(try await bench.waitFinished() == .completed)

        let saves = await library.saves
        #expect(saves.count == 4) // three pairs and the lone JPEG
        let pairs = saves.filter { $0.resources.count == 2 }
        #expect(pairs.count == 3)
        for save in pairs {
            let names = save.resources.map(\.originalFilename)
            #expect(names[0].hasSuffix(".JPG") && names[1].hasSuffix(".ARW"))
            #expect(names[0].dropLast(4) == names[1].dropLast(4))
            #expect(save.resources.map(\.role) == [.photo, .alternatePhoto])
        }
        // Both rows of a frame name its one asset.
        let listed = try await link.list()
        var assets: [String: Set<ImportedLocation?>] = [:]
        for item in listed {
            let identity = try #require(item.identity(camera: bench.camera, timeZone: Bench.zone))
            let record = await bench.catalogue.record(for: identity)
            #expect(record?.state == .imported, "\(item.name)")
            assets[RawPairingRule.stem(ofFilename: item.name), default: []].insert(record?.location)
        }
        #expect(assets.values.allSatisfy { $0.count == 1 })
        #expect(Set(assets.values.compactMap(\.first)).count == 4)
        #expect(bench.stagedFiles() == 0)
    }

    /// A JPG the camera can't read is skipped, and its ARW is saved alone.
    @Test func anUnreadableJPEGLeavesItsARWAlone() async throws {
        let bench = Bench()
        let card = try shoot()
        let link = bench.link(card)
        await link.script("DSC00002.JPG", .fail(.unreadableItem))
        let library = RecordingLibrary()
        try await link.open()
        try await bench.engine.start(.allNew, from: link, camera: bench.camera, to: photosRoute(bench, library))
        #expect(try await bench.waitFinished() == .completed)
        let saves = await library.saves
        #expect(saves.count == 4)
        #expect(saves.filter { $0.resources.count == 2 }.count == 2)
        #expect(saves.contains { $0.resources.map(\.originalFilename) == ["DSC00002.ARW"] })
        let progress = await bench.engine.currentProgress
        #expect(progress.filesSkipped == 1 && progress.filesImported == 6)
    }

    /// A stage job puts each frame's ARW and JPG side by side in the frame's day folder.
    @Test func aStageJobKeepsEachPairTogether() async throws {
        let bench = Bench(downloadsInFlight: 2)
        let card = try shoot()
        let link = bench.link(card)
        try await bench.start(link)
        #expect(try await bench.waitFinished() == .completed)
        bench.expectImported(card.objects.map(\.filename), from: card)
        for item in try await link.list() where item.name.hasSuffix(".ARW") {
            let jpeg = item.name.replacingOccurrences(of: ".ARW", with: ".JPG")
            let rawPath = try await stagedPath(bench, item)
            let partner = try #require(try await link.list().first { $0.name == jpeg })
            let jpegPath = try await stagedPath(bench, partner)
            #expect((rawPath as NSString).deletingLastPathComponent == (jpegPath as NSString).deletingLastPathComponent)
        }
    }

    private func stagedPath(_ bench: Bench, _ item: CameraItem) async throws -> String {
        let identity = try #require(item.identity(camera: bench.camera, timeZone: Bench.zone))
        return try #require(await bench.catalogue.record(for: identity)?.staged?.relativePath)
    }
}

/// A Photos library that saves every asset and records it, with no albums.
private actor RecordingLibrary: PhotoLibraryClient {
    private(set) var saves: [AssetCreation] = []

    func authorisation() -> PhotosAuthorisation { .authorised }
    func requestReadWriteAuthorisation() -> PhotosAuthorisation { .authorised }
    func album(withIdentifier identifier: String) -> AlbumLookup { .missing }
    func createAlbum(titled title: String) throws(PhotoLibraryFailure) -> String { "album" }

    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) throws(PhotoLibraryFailure) -> String {
        saves.append(asset)
        return "asset-\(saves.count)"
    }
}
