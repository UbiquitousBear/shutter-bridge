import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Testing

/// The fault matrix's Wi-Fi cases where the wire matters (backlog section 3): the real `IPLink` over
/// `InMemoryPTPIPCamera` (the simulated α7C II's whole-card session, byte for byte), with the real engine, for the
/// camera going away at 10, 50 and 99 % of a file and coming back at the same address and at another. The link
/// flavour in `FaultMatrixCutTests` plays the same contract through `SimulatedCameraLink`; this one shows the same
/// outcome through 0x9211, the checkpoints and the reopen. `PTPIPSimulatorServer` (Network.framework, so CI's
/// Simulator job only) does the same over TCP in `IPLinkOverNetworkTests`; the harness composes the in-memory camera
/// so it runs on Linux.
@Suite("Fault matrix: the real Wi-Fi link", .timeLimit(.minutes(2)))
struct FaultMatrixWireTests {
    typealias Wire = IPLinkAgainstSimulatorTests.Bench

    /// Bounded wait (10 s of real time) for the gate to hold a receive, recording an issue and throwing otherwise.
    private func waitHolding(_ wire: Wire, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: MatrixBench.patience)
        while !wire.gate.isHoldingAReceive {
            guard ContinuousClock.now < deadline else {
                Issue.record("the download never reached its cut", sourceLocation: sourceLocation)
                throw MatrixTimeout(what: "the cut")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// A second link to the same camera, dialling `endpoint`, as the app makes one once its locator has found the
    /// camera at a new address.
    private func link(on wire: Wire, at endpoint: PTPIPEndpoint) -> IPLink {
        var configuration = IPLink.Configuration(guid: IPLinkAgainstSimulatorTests.guid, endpoint: endpoint)
        configuration.timeZone = IPLinkAgainstSimulatorTests.utc
        configuration.timing.maxRead = 1500
        configuration.partialReadChunkSize = IPLinkResumeAgainstSimulatorTests.chunk
        let descriptor = CameraDescriptor(id: .init(rawValue: "wifi-test"), name: "ILCE-7CM2",
                                          mode: .wifi(.cameraNetwork))
        return IPLink(descriptor: descriptor, configuration: configuration, channels: wire.gate, clock: wire.clock,
                      connectionClock: ContinuousClock())
    }

    private func open(_ link: IPLink, on wire: Wire) async throws {
        let result = try await wire.clock.drive(within: IPLinkAgainstSimulatorTests.openHorizon) {
            () async -> Result<Void, CameraLinkFailure> in
            do throws(CameraLinkFailure) {
                try await link.open()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// Cuts the first download at `percent` and returns the job, once the engine is paused for the lost session.
    private func cut(_ bench: MatrixBench, _ wire: Wire, _ purpose: MatrixPurpose, percent: UInt64,
                     dropping drop: () -> Void) async throws -> (job: ImportJobID, items: [CameraItem]) {
        try await wire.open()
        let items = try await wire.link.list()
        let item = try #require(items.first)
        wire.gate.hold(afterReceiving: Int(item.size * percent / 100))
        try await bench.engine.start(.allNew, from: wire.link, camera: MatrixBench.camera, to: bench.route(purpose))
        let job = try #require(await bench.engine.currentJobID)
        try await waitHolding(wire)
        drop()
        wire.gate.release()
        try await bench.waitPaused(.cameraUnreachable)
        #expect(await bench.engine.currentProgress.filesFailed == 0)
        return (job, items)
    }

    /// The Wi-Fi goes mid-file at each offset; the reopen finds the same camera and the engine finishes the file with
    /// 0x9211 from its checkpoint, once.
    @Test("Wi-Fi dropped mid-file over the real link", arguments: MatrixCase.offsets, MatrixPurpose.allCases)
    func dropMidFile(_ percent: UInt64, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        bench.rowFolder = "" // the Wi-Fi link lists no folders
        let wire = try IPLinkResumeAgainstSimulatorTests.bench(frames: [.raw])
        let camera = wire.camera
        let (job, items) = try await cut(bench, wire, purpose, percent: percent) {
            camera.dropAll(losingUndelivered: true)
        }
        try await open(wire.link, on: wire)
        let known = try await wire.link.list(reusing: items)
        try await bench.engine.reconnect(job, to: wire.link, knownItems: known)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([camera.card], committed: MatrixBench.keys(camera.card.objects), purpose: purpose)
        #expect(camera.commandsAnswered.filter { $0 == .getObject }.count == 1) // never copied from 0 again
        #expect(camera.commandsAnswered.contains(.sonySDIOGetPartialLargeObject))
        await wire.link.close()
    }

    /// The camera comes back at another port of its address, or another address: a new link dials where the locator
    /// found it, and the file continues from its checkpoint.
    @Test("Wi-Fi reconnect at a different address over the real link",
          arguments: FaultMatrixCutTests.Move.allCases, MatrixPurpose.allCases)
    func reconnectAtADifferentAddress(_ move: FaultMatrixCutTests.Move, _ purpose: MatrixPurpose) async throws {
        let bench = MatrixBench()
        bench.rowFolder = "" // the Wi-Fi link lists no folders
        let wire = try IPLinkResumeAgainstSimulatorTests.bench(frames: [.raw])
        let camera = wire.camera
        let (job, items) = try await cut(bench, wire, purpose, percent: 50) {
            camera.restart(at: move.location) // the old address is silent from now on
        }
        #expect(camera.listensAt == move.location)
        let moved = link(on: wire, at: move.location)
        try await open(moved, on: wire)
        #expect(camera.dialled.last == move.location)
        let known = try await moved.list(reusing: items)
        try await bench.engine.reconnect(job, to: moved, knownItems: known)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([camera.card], committed: MatrixBench.keys(camera.card.objects), purpose: purpose)
        #expect(camera.commandsAnswered.filter { $0 == .getObject }.count == 1)
        #expect(camera.commandsAnswered.contains(.sonySDIOGetPartialLargeObject))
        await moved.close()
        await wire.link.close()
    }
}
