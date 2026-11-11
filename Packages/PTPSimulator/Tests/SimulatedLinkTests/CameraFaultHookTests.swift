import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

/// The in-memory PTP/IP camera's fault hooks (backlog Iteration 2, section 3): a slow link and a camera that restarts
/// at another endpoint, seen through `PTPIPConnection` as the Wi-Fi link sees them. The loopback server's versions are
/// the same logic over a socket and are compiled and run by CI's Xcode 27 job only.
@Suite("Simulator fault hooks: the in-memory camera", .timeLimit(.minutes(1)))
struct CameraFaultHookTests {
    static let guid = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    /// Three small files; the USB flavour, where a plain OpenSession serves the card.
    static func camera(packetSize: Int = 4096) throws -> InMemoryPTPIPCamera {
        let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 1000)
        return try InMemoryPTPIPCamera(card: card, flavour: .usbMTP, packetSize: packetSize)
    }

    static func connection(to camera: InMemoryPTPIPCamera, at endpoint: PTPIPEndpoint = .cameraNetwork)
        -> PTPIPConnection {
        PTPIPConnection(endpoint: endpoint, guid: guid, friendlyName: "Shutter Bridge",
                        timing: .init(maxRead: 1500), channels: camera)
    }

    private final class Received: Sendable {
        private let stored = Mutex(Data())
        func append(_ data: Data) { stored.withLock { $0.append(data) } }
        var data: Data { stored.withLock { $0 } }
    }

    private final class Outcome: Sendable {
        private let stored = Mutex<PTPIPConnection.Reply?>(nil)
        var reply: PTPIPConnection.Reply? {
            get { stored.withLock { $0 } }
            set { stored.withLock { $0 = newValue } }
        }
    }

    /// Polls for up to 10 s of real time, so a hook that never delivers fails the test, not the runner.
    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// A few turns of the scheduler, so bytes that were going to arrive have: the camera adds nothing without budget,
    /// so this only gives a wrongly delivered extra byte the chance to show.
    private func settle() async {
        for _ in 0 ..< 50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    /// The download's result, or nil if it hasn't ended within 10 s of real time (the task is then cancelled).
    private func finishedReply(_ task: Task<PTPIPConnection.Reply, any Error>) async -> Result<PTPIPConnection.Reply, any Error>? {
        let outcome = Mutex<Result<PTPIPConnection.Reply, any Error>?>(nil)
        let waiter = Task { let r = await task.result; outcome.withLock { $0 = r } }
        if await eventually({ outcome.withLock { $0 != nil } }) { return outcome.withLock { $0 } }
        task.cancel()
        waiter.cancel()
        return nil
    }

    private func openSession(_ connection: PTPIPConnection) async throws {
        _ = try await connection.connect()
        #expect(try await connection.perform(PTPCommand.openSession(sessionID: 1)).code == .ok)
    }

    // MARK: A slow link

    @Test func aDataPhaseFlowsOnlyAsFastAsTheBudgetGrows() async throws {
        let camera = try Self.camera()
        let object = try #require(camera.card.objects.first)
        let connection = Self.connection(to: camera)
        try await openSession(connection)

        camera.limitThroughput(bytesPerTick: 5_000, every: .seconds(1))
        let received = Received()
        let outcome = Outcome()
        let download = Task {
            outcome.reply = try await connection.perform(PTPCommand.getObject(object.handle, tx: 2)) {
                received.append($0)
            }
        }
        await settle()
        #expect(received.data.isEmpty)                                  // no tick yet: not a byte of the object

        var granted: UInt64 = 0
        while granted < object.size {
            camera.advance(by: .seconds(1))
            granted = min(object.size, granted + 5_000)
            let expected = granted
            let arrived = await eventually { UInt64(received.data.count) == expected }
            #expect(arrived, "expected \(granted) bytes, have \(received.data.count)")
            if granted < object.size {
                await settle()
                #expect(UInt64(received.data.count) == granted)         // and no more than the tick's
            }
        }
        try await download.value
        #expect(outcome.reply?.code == .ok && outcome.reply?.dataIsComplete == true)
        #expect(received.data == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        await connection.close()
    }

    /// The PTP/IP flavour drops a session that has sent no command for 30 s, and the initiator can't send one while a
    /// transfer is under way: a slow file that keeps making progress must not trip it, however long it takes.
    @Test func aSlowTransferThatKeepsMovingOutlastsTheIdleDrop() async throws {
        let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .jpeg])).scaled(down: 1000)
        let camera = try InMemoryPTPIPCamera(card: card, flavour: .ptpIP, packetSize: 4096)
        let connection = Self.connection(to: camera)
        _ = try await connection.connect()
        #expect(try await connection.perform(PTPCommand.sonySDIOOpenSession(functionMode: 1, tx: 1)).code == .ok)
        #expect(try await connection.perform(PTPCommand.sonySetContentsTransferMode(2, 1, 0, tx: 2)).code == .ok)
        camera.advance(by: .seconds(1))                                 // the card's arrival
        let object = try #require(camera.card.objects.first)
        let perTick: UInt64 = 1_000
        #expect(object.size > 31 * perTick)                             // more than the idle limit's worth of ticks

        camera.limitThroughput(bytesPerTick: perTick, every: .seconds(1))
        let received = Received()
        let download = Task {
            try await connection.perform(PTPCommand.getObject(object.handle, tx: 3)) { received.append($0) }
        }
        var granted: UInt64 = 0
        var ticks = 0
        while granted < object.size {
            camera.advance(by: .seconds(1))
            ticks += 1
            granted = min(object.size, granted + perTick)
            let expected = granted
            let arrived = await eventually { UInt64(received.data.count) == expected }
            #expect(arrived, "expected \(granted) bytes, have \(received.data.count) after \(ticks) s")
            if !arrived { break }
        }
        #expect(ticks > 30)                                             // past the 30 s a quiet session lasts
        guard case let .success(reply)? = await finishedReply(download) else {
            Issue.record("the download did not finish")
            return
        }
        #expect(reply.code == .ok && reply.dataIsComplete)
        #expect(received.data == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        #expect(camera.isConnected)
        await connection.close()
    }

    @Test func halfATickTwiceGrantsOneTick() async throws {
        let camera = try Self.camera()
        let object = try #require(camera.card.objects.first)
        let connection = Self.connection(to: camera)
        try await openSession(connection)
        camera.limitThroughput(bytesPerTick: 3_000, every: .seconds(2))
        let received = Received()
        let download = Task {
            _ = try await connection.perform(PTPCommand.getObject(object.handle, tx: 2)) { received.append($0) }
        }
        camera.advance(by: .seconds(1))
        await settle()
        #expect(received.data.isEmpty)
        camera.advance(by: .seconds(1))
        #expect(await eventually { received.data.count == 3_000 })
        camera.removeThroughputLimit()
        try await download.value
        #expect(received.data.count == Int(object.size))
        await connection.close()
    }

    @Test func removingTheLimitReleasesAReadWaitingForBudget() async throws {
        let camera = try Self.camera()
        let object = try #require(camera.card.objects.first)
        let connection = Self.connection(to: camera)
        try await openSession(connection)
        camera.limitThroughput(bytesPerTick: 1)
        let received = Received()
        let download = Task {
            _ = try await connection.perform(PTPCommand.getObject(object.handle, tx: 2)) { received.append($0) }
        }
        await settle()
        #expect(received.data.isEmpty)
        camera.removeThroughputLimit()
        try await download.value
        #expect(received.data == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        await connection.close()
    }

    @Test func aDropWhileWaitingForBudgetCutsTheDownloadShort() async throws {
        let camera = try Self.camera()
        let object = try #require(camera.card.objects.first)
        let connection = Self.connection(to: camera)
        try await openSession(connection)
        camera.limitThroughput(bytesPerTick: 5_000)
        let received = Received()
        let download = Task {
            try await connection.perform(PTPCommand.getObject(object.handle, tx: 2)) { received.append($0) }
        }
        camera.advance(by: .seconds(1))
        #expect(await eventually { received.data.count == 5_000 })
        camera.dropAll(losingUndelivered: true)
        await #expect(throws: PTPIPConnectionFailure.self) { _ = try await download.value }
        // What came is the file's start, no more than was granted.
        #expect(received.data == ScriptedCard.content(of: object.handle, in: 0 ..< 5_000))
    }

    // MARK: A camera at another endpoint

    @Test func aRestartAtAnotherEndpointLeavesTheOldOneSilentAndAnswersTheNew() async throws {
        let camera = try Self.camera()
        let moved = PTPIPEndpoint(host: "192.168.1.50", port: PTPIP.defaultPort)
        let otherPort = PTPIPEndpoint(host: PTPIPEndpoint.cameraNetwork.host, port: 15741)
        #expect(camera.listensAt == nil)

        let first = Self.connection(to: camera)
        let events = first.events
        _ = try await first.connect()
        camera.restart(at: moved)
        #expect(camera.listensAt == moved)
        for await _ in events {}                                        // the session ended with the camera
        #expect(await first.linkFailure == .linkLost(posix: 53))

        // The old address, now silent: nobody answers, so the connect times out.
        await #expect(throws: PTPIPConnectionFailure.timedOut(.connect)) {
            try await Self.connection(to: camera, at: .cameraNetwork).connect()
        }
        await #expect(throws: PTPIPConnectionFailure.timedOut(.connect)) {
            try await Self.connection(to: camera, at: otherPort).connect()
        }
        let again = Self.connection(to: camera, at: moved)
        _ = try await again.connect()
        #expect(try await again.perform(PTPCommand.getDeviceInfo(tx: 1)).code == .ok)
        await again.close()
        #expect(camera.dialled.contains(moved) && camera.dialled.contains(otherPort))
        #expect(camera.dialled.first == .cameraNetwork)
    }

    @Test func aRestartAtAnotherPortOfTheSameHostRefusesTheOldPort() async throws {
        let camera = try Self.camera()
        let moved = PTPIPEndpoint(host: PTPIPEndpoint.cameraNetwork.host, port: 15741)
        camera.restart(at: moved)
        // The host answers and nothing listens on the old port.
        await #expect(throws: PTPIPConnectionFailure.refused(initFailReason: nil)) {
            try await Self.connection(to: camera).connect()
        }
        let again = Self.connection(to: camera, at: moved)
        _ = try await again.connect()
        await again.close()
    }

    @Test func restartingAtNilAnswersEverywhereAgain() async throws {
        let camera = try Self.camera()
        camera.restart(at: PTPIPEndpoint(host: "192.168.1.50"))
        await #expect(throws: PTPIPConnectionFailure.timedOut(.connect)) {
            try await Self.connection(to: camera).connect()
        }
        camera.restart(at: nil)
        let connection = Self.connection(to: camera)
        _ = try await connection.connect()
        await connection.close()
    }
}
