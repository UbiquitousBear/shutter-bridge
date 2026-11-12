import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing

/// Backlog Iteration 2, section 1 (I14): a card listed in London and listed again with the phone 9 hours east still
/// matches its rows, through the simulated link's own listing (its dates are made in the zone it is given, as
/// ImageCaptureCore's and the IP link's are made in the phone's).
@Suite("The capture time's zone against the simulated link", .timeLimit(.minutes(1)))
struct CaptureZoneAgainstSimulatorTests {
    static let london = TimeZone(identifier: "Europe/London")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func card() throws -> ScriptedCard {
        try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 1000)
    }

    @Test func aCardStagedInLondonIsAllStagedWhenRelisted9HoursEast() async throws {
        let bench = Bench()   // the engine reads in UTC
        let card = try card()
        let inLondon = SimulatedCameraLink(card: card, timeZone: Self.london, chunkSize: 4096)
        try await bench.start(inLondon)
        #expect(try await bench.waitFinished() == .completed)
        let firstListing = try await inLondon.list()
        #expect(firstListing.allSatisfy { $0.captureTimeZone == Self.london })
        for item in firstListing { #expect(await bench.isStaged(item), "\(item.name)") }
        await inLondon.close()

        let inTokyo = SimulatedCameraLink(card: card, timeZone: Self.tokyo, generation: 2, chunkSize: 4096)
        try await inTokyo.open()
        let relisted = try await inTokyo.list()
        #expect(relisted.count == firstListing.count)
        for item in relisted {
            let before = try #require(firstListing.first { $0.name == item.name }?.captureDate)
            // Nine hours apart as instants, one reading of the camera's clock.
            let apart: TimeInterval? = item.captureDate.map { before.timeIntervalSince($0) }
            #expect(apart == TimeInterval(9 * 3600), "\(item.name)")
            #expect(await bench.isStaged(item), "\(item.name)")
        }
        // *Select all new* and the whole card both find nothing to do.
        #expect(try await bench.engine.picksToDo(.newItems(relisted), camera: bench.camera, for: bench.route).isEmpty)
        try await bench.engine.start(.allNew, from: inTokyo, camera: bench.camera, to: bench.route)
        #expect(try await bench.waitFinished() == .completed)
        #expect(await inTokyo.bytesCalls.isEmpty)
        #expect(await bench.engine.currentProgress.filesTotal == 0)
        #expect(bench.importedFiles().count == card.objects.count)   // no second copy of anything
        await inTokyo.close()
    }

    @Test func anEngineIn9HoursEastMatchesItemsListedInLondon() async throws {
        let bench = Bench()
        let card = try card()
        let inLondon = SimulatedCameraLink(card: card, timeZone: Self.london, chunkSize: 4096)
        try await bench.start(inLondon)
        #expect(try await bench.waitFinished() == .completed)
        let listed = try await inLondon.list()
        // The phone has moved; the items are the ones listed before (as an IP relist keeps them).
        let moved = ImportEngine(catalogue: bench.catalogue,
                                 stagingDirectory: bench.root.appendingPathComponent("moved", isDirectory: true),
                                 timeZone: Self.tokyo)
        #expect(try await moved.picksToDo(.newItems(listed), camera: bench.camera, for: bench.route).isEmpty)
        await inLondon.close()
    }
}
