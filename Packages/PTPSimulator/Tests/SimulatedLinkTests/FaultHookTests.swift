import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

private let utc = TimeZone(identifier: "UTC")!

/// Two RAW+JPEG frames and a JPEG, about 42, 22 and 22 KB.
private func smallCard() throws -> ScriptedCard {
    try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .jpeg])).scaled(down: 1000)
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("FaultHookTests-\(UUID().uuidString)",
                                                                  isDirectory: true)
}

private final class Values<Element: Sendable>: Sendable {
    private let stored = Mutex<[Element]>([])
    var all: [Element] { stored.withLock { $0 } }
    var last: Element? { stored.withLock { $0.last } }
    func append(_ element: Element) { stored.withLock { $0.append(element) } }
    var callback: @Sendable (Element) -> Void { { [self] e in self.append(e) } }
}

private final class Box<Value: Sendable>: Sendable {
    private let stored: Mutex<Value>
    init(_ value: Value) { stored = Mutex(value) }
    var value: Value {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

/// Polls `condition` for up to 10 s of real time, so a hook that never delivers fails the test instead of waiting for
/// ever (a wait on a continuation can't be ended by the suite's time limit).
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// The task's result, or nil if it hasn't ended within 10 s (the task is then cancelled).
private func finished<T: Sendable>(_ task: Task<T, any Error>) async -> Result<T, any Error>? {
    let outcome = Box<Result<T, any Error>?>(nil)
    let waiter = Task { outcome.value = await task.result }
    let done = await eventually { outcome.value != nil }
    if !done {
        task.cancel()
        waiter.cancel()
    }
    return outcome.value
}

private func failureKind<T: Sendable>(of task: Task<T, any Error>) async -> CameraLinkFailure.Kind? {
    guard case let .failure(error)? = await finished(task) else { return nil }
    return (error as? CameraLinkFailure)?.kind
}

private func nextEvent(_ iterator: inout AsyncStream<CameraLinkEvent>.Iterator) async -> CameraLinkEvent? {
    await iterator.next()
}

/// A Wi-Fi link over the small card whose first file is the one these tests download.
private func wifiLink(chunkSize: UInt64 = 4096, location: PTPIPEndpoint = .cameraNetwork,
                      dialing: PTPIPEndpoint? = nil,
                      provider: (@Sendable () -> PTPIPEndpoint)? = nil) throws -> SimulatedCameraLink {
    SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork), timeZone: utc, chunkSize: chunkSize,
                        location: location, dialing: dialing, locationProvider: provider)
}

@Suite("Simulator fault hooks: the link", .timeLimit(.minutes(1)))
struct LinkFaultHookTests {
    // MARK: A slow link

    @Test func aDownloadWritesOnlyTheBytesEachTickGrants() async throws {
        let link = try wifiLink()
        try await link.open()
        let item = try await link.list()[0]
        let object = try smallCard().objects[0]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await link.limitThroughput(bytesPerTick: 10_000, every: .seconds(1))
        #expect(await link.throughputLimit?.bytesPerTick == 10_000)
        let progress = Values<UInt64>()
        let download = Task {
            try await link.bytes(of: item.id, into: folder, resuming: nil, checkpoint: { _ in },
                                 progress: progress.callback)
        }
        await link.waitUntilThrottled()
        #expect(progress.all.isEmpty)                                  // no tick has passed: nothing is written

        var granted: UInt64 = 0
        var ticks = 0
        while granted < object.size {
            await link.advance(by: .seconds(1))
            ticks += 1
            granted = min(object.size, granted + 10_000)
            if granted == object.size { break }
            await link.waitUntilThrottled()                            // the tick's bytes are all written
            #expect(progress.last == granted)
            #expect(try Data(contentsOf: folder.appendingPathComponent(object.filename))
                == ScriptedCard.content(of: object.handle, in: 0 ..< granted))
        }
        let result = await finished(download)
        #expect(try result?.get().lastPathComponent == object.filename)
        #expect(ticks == Int((object.size + 9_999) / 10_000))
        #expect(progress.all == progress.all.sorted())                 // never backwards
        #expect(progress.last == object.size)
        #expect(await link.delivered == [object.filename])
        #expect(try Data(contentsOf: folder.appendingPathComponent(object.filename))
            == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
    }

    @Test func timeShortOfATickWritesNothing() async throws {
        let link = try wifiLink()
        try await link.open()
        let item = try await link.list()[0]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.limitThroughput(bytesPerTick: 6_000, every: .seconds(1))
        let progress = Values<UInt64>()
        let download = Task {
            try await link.bytes(of: item.id, into: folder, resuming: nil, checkpoint: { _ in },
                                 progress: progress.callback)
        }
        await link.waitUntilThrottled()
        await link.advance(by: .milliseconds(600))
        await link.advance(by: .milliseconds(399))
        #expect(await link.throttledDownloads == 1)
        #expect(progress.all.isEmpty)
        await link.advance(by: .milliseconds(1))                       // the tick completes
        await link.waitUntilThrottled()
        #expect(progress.last == 6_000)
        await link.removeThroughputLimit()
        #expect(await finished(download) != nil)
    }

    @Test func twoDownloadsShareOneBudget() async throws {
        let link = try wifiLink()
        try await link.open()
        let items = try await link.list()
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.limitThroughput(bytesPerTick: 8_000, every: .seconds(1))
        let first = Values<UInt64>(), second = Values<UInt64>()
        let a = Task {
            try await link.bytes(of: items[0].id, into: folder, resuming: nil, checkpoint: { _ in },
                                 progress: first.callback)
        }
        let b = Task {
            try await link.bytes(of: items[1].id, into: folder, resuming: nil, checkpoint: { _ in },
                                 progress: second.callback)
        }
        let bothWaiting = await eventually { await link.throttledDownloads == 2 }
        #expect(bothWaiting)
        await link.advance(by: .seconds(1))
        let spent = await eventually { (first.last ?? 0) + (second.last ?? 0) == 8_000 }
        #expect(spent)                                                  // one tick's bytes between the two
        #expect(await eventually { await link.throttledDownloads == 2 })
        #expect((first.last ?? 0) + (second.last ?? 0) == 8_000)
        await link.removeThroughputLimit()
        #expect(await finished(a) != nil)
        #expect(await finished(b) != nil)
        #expect(Set(await link.delivered) == Set([items[0].name, items[1].name]))
    }

    @Test func removingTheLimitLetsAWaitingDownloadFinish() async throws {
        let link = try wifiLink()
        try await link.open()
        let item = try await link.list()[1]
        let object = try smallCard().objects[1]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.limitThroughput(bytesPerTick: 1)
        let download = Task { try await link.bytes(of: item.id, into: folder) }
        await link.waitUntilThrottled()
        await link.removeThroughputLimit()
        let url = try await #require(finished(download)).get()
        #expect(try Data(contentsOf: url) == ScriptedCard.content(of: object.handle, in: 0 ..< object.size))
        #expect(await link.throughputLimit == nil)
    }

    @Test func aPowerOffEndsADownloadWaitingForBudget() async throws {
        let link = try wifiLink()
        var events = link.events.makeAsyncIterator()
        try await link.open()
        let item = try await link.list()[0]
        let object = try smallCard().objects[0]
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await link.limitThroughput(bytesPerTick: 5_000)
        let progress = Values<UInt64>()
        let download = Task {
            try await link.bytes(of: item.id, into: folder, resuming: nil, checkpoint: { _ in },
                                 progress: progress.callback)
        }
        await link.waitUntilThrottled()
        await link.advance(by: .seconds(1))
        await link.waitUntilThrottled()
        #expect(progress.last == 5_000)
        await link.powerOff()
        #expect(await nextEvent(&events) == .sessionLost)
        #expect(await failureKind(of: download) == .disconnected)
        // What reached the disk is the file's first bytes, and no more than was granted.
        let onDisk = try Data(contentsOf: folder.appendingPathComponent(object.filename))
        #expect(onDisk == ScriptedCard.content(of: object.handle, in: 0 ..< 5_000))
    }

    // MARK: A camera that powers off

    @Test func aWiFiCameraThatPowersOffStaysGoneUntilItIsSwitchedOn() async throws {
        let link = try wifiLink()
        var events = link.events.makeAsyncIterator()
        try await link.open()
        let item = try await link.list()[0]
        await link.script(item.name, .holdAfter(8_192))
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let download = Task { try await link.bytes(of: item.id, into: folder) }
        await link.waitUntilHeld(item.name)

        await link.powerOff()
        #expect(await link.isPoweredOff)
        #expect(await nextEvent(&events) == .sessionLost)
        #expect(await failureKind(of: download) == .disconnected)
        #expect(await link.isRemoved == false)                          // a Wi-Fi link can be opened again

        // Nothing answers, however many times it is tried, and the outcome is the one that waits for a reconnect.
        for _ in 0 ..< 3 {
            let failure = await #expect(throws: CameraLinkFailure.self) { try await link.open() }
            #expect(failure?.kind == .disconnected)
            #expect(failure?.outcome == .retryOnReconnect)
        }
        #expect(await link.openCount == 1)
        #expect(await link.isOpen == false)

        // Later (the test's clock isn't involved: the camera has no time of its own) it comes back.
        await link.powerOn()
        try await link.open()
        #expect(await link.openCount == 2)
        #expect(try await link.list().count == 5)
        let url = try await link.bytes(of: item.id, into: folder)
        #expect(url.lastPathComponent == item.name)
    }

    @Test func aUSBCameraThatPowersOffLeavesTheBusAndComesBackWithAReplug() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), timeZone: utc)
        var events = link.events.makeAsyncIterator()
        try await link.open()
        _ = try await link.list()
        await link.powerOff()
        #expect(await nextEvent(&events) == .removed)
        #expect(await link.isRemoved)
        let failure = await #expect(throws: CameraLinkFailure.self) { try await link.open() }
        #expect(failure?.kind == .disconnected)

        // The cable is still in: a new link made now finds nothing until the camera is on.
        let replugged = await link.replugged()
        #expect(await replugged.isPoweredOff)
        await #expect(throws: CameraLinkFailure.self) { try await replugged.open() }
        await link.powerOn()
        #expect(await link.isRemoved)                                   // switching on doesn't revive a removed link
        await replugged.powerOn()
        try await replugged.open()
        #expect(try await replugged.list().count == 5)
    }

    @Test func aCameraSwitchedOffTwiceOrOnWhenOnChangesNothing() async throws {
        let link = try wifiLink()
        var events = link.events.makeAsyncIterator()
        try await link.open()
        await link.powerOn()
        #expect(await link.isOpen)
        await link.powerOff()
        await link.powerOff()
        #expect(await nextEvent(&events) == .sessionLost)
        await link.send(.resumedOperations)                             // a marker: no second loss came before it
        #expect(await nextEvent(&events) == .resumedOperations)
    }

    @Test func aCameraThatStartsOffRefusesToAnswerUntilSwitchedOn() async throws {
        let link = SimulatedCameraLink(card: try smallCard(), mode: .wifi(.cameraNetwork), isPoweredOff: true)
        await #expect(throws: CameraLinkFailure.self) { try await link.open() }
        await link.powerOn()
        try await link.open()
        #expect(await link.isOpen)
    }

    // MARK: A camera at another address

    private let elsewhere = PTPIPEndpoint(host: "192.168.1.50", port: PTPIP.defaultPort)

    @Test func aLinkWithAProviderFollowsTheCameraToItsNewAddress() async throws {
        let where_ = Box(PTPIPEndpoint.cameraNetwork)
        let link = try wifiLink(provider: { where_.value })
        var events = link.events.makeAsyncIterator()
        try await link.open()
        #expect(await link.dialled == [.cameraNetwork])

        await link.moveCamera(to: elsewhere)
        #expect(await nextEvent(&events) == .sessionLost)
        #expect(await link.isOpen == false)
        #expect(await link.cameraLocation == elsewhere)

        // The locator hasn't found it yet: the old address answers nothing.
        let unanswered = await #expect(throws: CameraLinkFailure.self) { try await link.open() }
        #expect(unanswered?.kind == .disconnected)
        // Then it has.
        where_.value = elsewhere
        try await link.open()
        #expect(await link.dialled == [.cameraNetwork, .cameraNetwork, elsewhere])
        #expect(await link.dialLocation == elsewhere)
        #expect(try await link.list().count == 5)
    }

    @Test func aLinkWithAFixedLocationNeverFindsACameraThatMoved() async throws {
        let link = try wifiLink()
        try await link.open()
        await link.moveCamera(to: elsewhere)
        for _ in 0 ..< 2 {
            let failure = await #expect(throws: CameraLinkFailure.self) { try await link.open() }
            #expect(failure?.outcome == .retryOnReconnect)
        }
        #expect(await link.dialled == [.cameraNetwork, .cameraNetwork, .cameraNetwork])
        // A new link keeps the way its predecessor found the camera.
        #expect(await link.replugged().dialLocation == .cameraNetwork)
        #expect(await link.replugged().cameraLocation == elsewhere)
    }

    @Test func aNewPortOnTheSameHostIsRefusedWhereAnotherHostIsUnanswered() async throws {
        let sameHost = PTPIPEndpoint(host: PTPIPEndpoint.cameraNetwork.host, port: 15741)
        let link = try wifiLink()
        try await link.open()
        await link.moveCamera(to: sameHost)
        let refused = await #expect(throws: CameraLinkFailure.self) { try await link.open() }
        #expect(refused?.kind == .refused)
        #expect(refused?.outcome == .stopJob)
        let provided = Box(sameHost)
        let follower = try wifiLink(location: sameHost, dialing: sameHost, provider: { provided.value })
        try await follower.open()
        #expect(await follower.dialled == [sameHost])
    }

    @Test func movingAClosedLinksCameraSendsNoLoss() async throws {
        let link = try wifiLink()
        var events = link.events.makeAsyncIterator()
        await link.moveCamera(to: elsewhere)
        await link.send(.resumedOperations)                             // a marker
        #expect(await nextEvent(&events) == .resumedOperations)
    }

    // MARK: A late loss from a replaced session

    @Test func aLateLossArrivesWhileTheNewSessionIsUpAndChangesNothing() async throws {
        let link = try wifiLink()
        var events = link.events.makeAsyncIterator()
        try await link.open()
        let item = try await link.list()[1]
        await link.loseSessionAndReopen(announcing: .late)
        #expect(await link.lateSessionLosses == 1)
        #expect(await link.isOpen)
        #expect(await link.openCount == 2)

        // No `.sessionLost` has gone out: the next event the app sees is the marker.
        await link.send(.resumedOperations)
        #expect(await nextEvent(&events) == .resumedOperations)
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await link.bytes(of: item.id, into: folder)             // the new session carries on

        #expect(await link.sendLateSessionLoss())
        #expect(await nextEvent(&events) == .sessionLost)
        #expect(await link.lateSessionLosses == 0)
        #expect(await link.isOpen)                                      // it was the old session that was lost
        #expect(try await link.list().count == 5)
        #expect(await link.sendLateSessionLoss() == false)
    }

    @Test func eachReplacedSessionLeavesOneLateLoss() async throws {
        let link = try wifiLink()
        var events = link.events.makeAsyncIterator()
        try await link.open()
        await link.loseSessionAndReopen(announcing: .late)
        await link.loseSessionAndReopen(announcing: .late)
        #expect(await link.lateSessionLosses == 2)
        #expect(await link.sendLateSessionLoss())
        #expect(await link.sendLateSessionLoss())
        #expect(await link.sendLateSessionLoss() == false)
        #expect(await nextEvent(&events) == .sessionLost)
        #expect(await nextEvent(&events) == .sessionLost)
    }

    @Test func aCallFromTheReplacedSessionStillEndsDisconnectedWithALateLoss() async throws {
        let link = try wifiLink()
        try await link.open()
        let item = try await link.list()[0]
        await link.script(item.name, .holdAfter(4_096))
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let download = Task { try await link.bytes(of: item.id, into: folder) }
        await link.waitUntilHeld(item.name)
        await link.loseSessionAndReopen(announcing: .late)
        #expect(await failureKind(of: download) == .disconnected)
        #expect(await link.delivered.isEmpty)
        #expect(await link.isOpen)
    }

    @Test func announcingImmediatelyIsTheDefaultAndSendsTheLossAtOnce() async throws {
        let link = try wifiLink()
        var events = link.events.makeAsyncIterator()
        try await link.open()
        await link.loseSessionAndReopen()
        #expect(await nextEvent(&events) == .sessionLost)
        #expect(await link.lateSessionLosses == 0)
        #expect(await link.isOpen)
    }
}
