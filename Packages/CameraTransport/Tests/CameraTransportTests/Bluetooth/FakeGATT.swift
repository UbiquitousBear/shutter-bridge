// Scripted stand-ins for the camera's GATT link. The byte values follow what spike-findings.md records of CC09 (the
// layout, the ten tags, `04 00 01 02 00` as a status-2 notification); nothing here is a capture. The network name and
// password are synthetic: no real value ever goes in a test.

import BLEKit
import Foundation
import Synchronization
@testable import CameraTransport

enum Cam {
    /// A CC09 read: the findings' ten tags, 43 bytes, with tag 0x0001 carrying `status 00`.
    static func statusRead(_ status: UInt8) -> Data {
        let entries: [[UInt8]] = [
            [0x04, 0x00, 0x01, status, 0x00],
            [0x03, 0x00, 0x02, 0x01],
            [0x03, 0x00, 0x03, 0x01],
            [0x05, 0x00, 0x04, 0x00, 0x00, 0x00],
            [0x03, 0x00, 0x05, 0x01],
            [0x03, 0x00, 0x06, 0x00],
            [0x03, 0x00, 0x07, 0x00],
            [0x03, 0x00, 0x08, 0x00],
            [0x03, 0x00, 0x09, 0x00],
            [0x03, 0x00, 0x0A, 0x01],
        ]
        return Data(entries.flatMap { $0 })
    }

    /// One notification: tag 0x0001, `status 00` (the findings' example: `04 00 01 02 00`).
    static func statusNotification(_ status: UInt8) -> Data { Data([0x04, 0x00, 0x01, status, 0x00]) }

    static let ssid = "DIRECT-ab12:TEST-CAM"
    static let passphrase = "test-pass-1234"

    /// CC06 or CC07 as the camera sends it: three prefix bytes, then the text.
    static func networkValue(_ text: String) -> Data { Data([0x01, 0x02, 0x03] + Array(text.utf8)) }
}

enum Call: Equatable, CustomStringConvertible {
    case notify(Bool, CameraControlCharacteristic)
    case read(CameraControlCharacteristic)
    case write(CameraControlCharacteristic)
    case disconnect

    var description: String {
        switch self {
        case .notify(let on, let c): "notify \(on ? "on" : "off") \(c.code)"
        case .read(let c): "read \(c.code)"
        case .write(let c): "write \(c.code)"
        case .disconnect: "disconnect"
        }
    }
}

struct LoggedCall: Equatable {
    var call: Call
    var at: Duration
}

/// A link that does what the test scripted, on the test's clock, and writes down every call with its virtual time.
final class FakeGATTLink: GATTLink {
    private struct State {
        var log: [LoggedCall] = []
        var readTimeouts: [CameraControlCharacteristic: [Duration?]] = [:]
        var statusHistory: [(at: Duration, status: UInt8)]
        var values: [CameraControlCharacteristic: Data] = [
            .ssid: Cam.networkValue(Cam.ssid),
            .passphrase: Cam.networkValue(Cam.passphrase),
        ]
        var readFailures: [CameraControlCharacteristic: [GATTFailure]] = [:]
        var readDelays: [CameraControlCharacteristic: Duration] = [:]
        var notifyFailures: [CameraControlCharacteristic: GATTFailure] = [:]
        var writeFailure: GATTFailure?
        var onWrite: (@Sendable (FakeGATTLink) -> Void)?
        var notificationSinks: [AsyncStream<(CameraControlCharacteristic, Data)>.Continuation] = []
        var stateSinks: [AsyncStream<GATTLinkState>.Continuation] = []
        var another = false
        var dropped = false
        /// Delayed reads in progress: a drop cancels their waits.
        var pendingReadWaits: [Task<Void, Error>] = []
        /// Notifications sent, and times the notification stream's consumer asked for the next one (see `deliveredAll`).
        var emitted = 0
        var asked = 0
        /// Statuses to announce, one per status read, while that read is answered.
        var announcementsDuringReads: [UInt8] = []
    }

    /// Holds the iterator of a notification stream for `AsyncStream(unfolding:)`; only that stream's one consumer uses it.
    private final class Source: @unchecked Sendable {
        var iterator: AsyncStream<(CameraControlCharacteristic, Data)>.Iterator
        init(_ iterator: AsyncStream<(CameraControlCharacteristic, Data)>.Iterator) { self.iterator = iterator }
        func next() async -> (CameraControlCharacteristic, Data)? { await iterator.next() }
    }

    let peripheral: PeripheralID
    let clock: ManualClock
    private let box: Mutex<State>

    init(clock: ManualClock, initialStatus: UInt8 = 0, peripheral: PeripheralID = PeripheralID(UUID())) {
        self.clock = clock
        self.peripheral = peripheral
        box = Mutex(State(statusHistory: [(at: .zero, status: initialStatus)]))
    }

    // MARK: Scripting

    /// CC09 reads `status` from `delay` after now on; with `notify`, a notification arrives then too. Call it before the run
    /// for a timeline from the start, or from `onWrite` for one counted from the write.
    func schedule(status: UInt8, after delay: Duration, notify: Bool = true) {
        let at = clock.elapsed + delay
        box.withLock { $0.statusHistory.append((at: at, status: status)) }
        if notify {
            clock.schedule(at: at) { [self] in emit(.status, Cam.statusNotification(status)) }
        }
    }

    /// Sends a notification now (from a scheduled action or a test).
    func emit(_ characteristic: CameraControlCharacteristic, _ value: Data) {
        let sinks = box.withLock { s -> [AsyncStream<(CameraControlCharacteristic, Data)>.Continuation] in
            s.emitted += 1
            return s.notificationSinks
        }
        for sink in sinks { sink.yield((characteristic, value)) }
    }

    /// The link goes away `delay` from now.
    func scheduleDrop(after delay: Duration, _ failure: GATTFailure = .linkDropped) {
        clock.schedule(at: clock.elapsed + delay) { [self] in drop(failure) }
    }

    /// The link goes away: its state stream says so, and every read still waiting ends with `.linkDropped`, as the
    /// `GATTLink` contract has it.
    func drop(_ failure: GATTFailure) {
        let (sinks, waits) = box.withLock { s -> ([AsyncStream<GATTLinkState>.Continuation], [Task<Void, Error>]) in
            s.dropped = true
            let waits = s.pendingReadWaits
            s.pendingReadWaits = []
            return (s.stateSinks, waits)
        }
        for wait in waits { wait.cancel() }
        for sink in sinks {
            sink.yield(.dropped(failure))
            sink.finish()
        }
    }

    func set(_ value: Data, for characteristic: CameraControlCharacteristic) {
        box.withLock { $0.values[characteristic] = value }
    }

    /// The next reads of `characteristic` fail with these, in order; later reads go back to the value.
    func failReads(_ characteristic: CameraControlCharacteristic, with failures: [GATTFailure]) {
        box.withLock { $0.readFailures[characteristic] = failures }
    }

    /// Reads of `characteristic` take this long on the clock, as a read waiting for a person does.
    func delayReads(_ characteristic: CameraControlCharacteristic, by delay: Duration) {
        box.withLock { $0.readDelays[characteristic] = delay }
    }

    func failNotify(_ characteristic: CameraControlCharacteristic, with failure: GATTFailure) {
        box.withLock { $0.notifyFailures[characteristic] = failure }
    }

    func failWrite(with failure: GATTFailure) {
        box.withLock { $0.writeFailure = failure }
    }

    /// Runs when CC08 is written and acknowledged: schedules what the camera does next.
    func onWrite(_ body: @escaping @Sendable (FakeGATTLink) -> Void) {
        box.withLock { $0.onWrite = body }
    }

    /// The next status reads are each answered with a notification of `status` sent just before the answer, as a camera whose
    /// status changes while the phone reads it does. The notification has reached the consumer when the read returns.
    func announceDuringStatusReads(_ statuses: [UInt8]) {
        box.withLock { $0.announcementsDuringReads = statuses }
    }

    func setAnotherAppHoldsLink(_ value: Bool) {
        box.withLock { $0.another = value }
    }

    // MARK: What happened

    var calls: [Call] { box.withLock { $0.log.map(\.call) } }
    var logged: [LoggedCall] { box.withLock { $0.log } }
    func timeouts(for characteristic: CameraControlCharacteristic) -> [Duration?] {
        box.withLock { $0.readTimeouts[characteristic] ?? [] }
    }
    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
    func time(of call: Call) -> Duration? { logged.first { $0.call == call }?.at }

    private func record(_ call: Call) {
        let at = clock.elapsed
        box.withLock { $0.log.append(LoggedCall(call: call, at: at)) }
    }

    // MARK: GATTLink

    func read(_ characteristic: CameraControlCharacteristic, timeout: Duration?) async throws(GATTFailure) -> Data {
        record(.read(characteristic))
        enum Plan { case fail(GATTFailure), value(Data, delay: Duration?) }
        let now = clock.elapsed
        let (plan, announcement) = box.withLock { s -> (Plan, UInt8?) in
            s.readTimeouts[characteristic, default: []].append(timeout)
            if s.dropped { return (.fail(.linkDropped), nil) }
            let announcement: UInt8? = characteristic == .status && !s.announcementsDuringReads.isEmpty
                ? s.announcementsDuringReads.removeFirst() : nil
            if var queue = s.readFailures[characteristic], !queue.isEmpty {
                let failure = queue.removeFirst()
                s.readFailures[characteristic] = queue
                return (.fail(failure), announcement)
            }
            let delay = s.readDelays[characteristic]
            if characteristic == .status, s.values[.status] == nil {
                let current = s.statusHistory.filter { $0.at <= now }.max { $0.at < $1.at }?.status ?? 0
                return (.value(Cam.statusRead(current), delay: delay), announcement)
            }
            guard let value = s.values[characteristic] else { return (.fail(.serviceMissing), announcement) }
            return (.value(value, delay: delay), announcement)
        }
        if let announcement {
            emit(.status, Cam.statusNotification(announcement))
            await deliveredAll()
        }
        switch plan {
        case .fail(let failure):
            throw failure
        case .value(let value, let delay):
            guard let delay else { return value }
            // A read that gets a timeout shorter than its delay times out, as a real one would. A drop ends it at once.
            let wait = timeout.map { min($0, delay) } ?? delay
            let sleeper = Task { [clock] in try await clock.sleep(for: wait) }
            let droppedAlready = box.withLock { s -> Bool in
                if s.dropped { return true }
                s.pendingReadWaits.append(sleeper)
                return false
            }
            if droppedAlready {
                sleeper.cancel()
                throw GATTFailure.linkDropped
            }
            do {
                try await withTaskCancellationHandler { try await sleeper.value } onCancel: { sleeper.cancel() }
            } catch {
                throw box.withLock { $0.dropped } ? GATTFailure.linkDropped : GATTFailure.cancelled
            }
            if let timeout, timeout < delay { throw GATTFailure.timedOut }
            return value
        }
    }

    /// Returns once the consumer of the notification stream has taken everything sent so far and asked for more, which is
    /// when the sequencer's pump has queued it: tests that need a notification queued before the sequencer's next step wait
    /// on this rather than on luck. Spins on `Task.yield`, with no clock and no wall time in it.
    private func deliveredAll() async {
        while box.withLock({ $0.asked <= $0.emitted }) { await Task.yield() }
    }

    func write(_ write: CameraControlWrite, timeout: Duration) async throws(GATTFailure) {
        record(.write(write.characteristic))
        let (failure, body) = box.withLock { ($0.writeFailure, $0.onWrite) }
        if let failure { throw failure }
        body?(self)
    }

    func setNotify(_ on: Bool, _ characteristic: CameraControlCharacteristic, timeout: Duration) async throws(GATTFailure) {
        record(.notify(on, characteristic))
        if on, let failure = box.withLock({ $0.notifyFailures[characteristic] }) { throw failure }
        if !on, let failure = box.withLock({ $0.notifyFailures[characteristic] }) { throw failure }
    }

    var notifications: AsyncStream<(CameraControlCharacteristic, Data)> {
        let (inner, continuation) = AsyncStream.makeStream(of: (CameraControlCharacteristic, Data).self)
        box.withLock { $0.notificationSinks.append(continuation) }
        let source = Source(inner.makeAsyncIterator())
        return AsyncStream(unfolding: { [self] in
            box.withLock { $0.asked += 1 }
            return await source.next()
        })
    }

    /// The current state first, then a drop when one is scripted (and the stream ends).
    var state: AsyncStream<GATTLinkState> {
        let (stream, continuation) = AsyncStream.makeStream(of: GATTLinkState.self)
        let alreadyDropped = box.withLock { s -> Bool in
            if !s.dropped { s.stateSinks.append(continuation) }
            return s.dropped
        }
        if alreadyDropped {
            continuation.yield(.dropped(.linkDropped))
            continuation.finish()
        } else {
            continuation.yield(.connected)
        }
        return stream
    }

    var anotherAppHoldsLink: Bool { box.withLock { $0.another } }

    func disconnect() async {
        record(.disconnect)
    }
}

/// Hands out the links the test queued, and writes down what it was asked for.
final class FakeGATTConnector: GATTConnector {
    private struct State {
        var results: [Result<FakeGATTLink, GATTFailure>]
        var knownArguments: [PeripheralID?] = []
    }

    private let box: Mutex<State>

    init(_ results: [Result<FakeGATTLink, GATTFailure>]) {
        box = Mutex(State(results: results))
    }

    var knownArguments: [PeripheralID?] { box.withLock { $0.knownArguments } }
    var connectCount: Int { knownArguments.count }

    func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink {
        let next = box.withLock { s -> Result<FakeGATTLink, GATTFailure>? in
            s.knownArguments.append(known)
            return s.results.isEmpty ? nil : s.results.removeFirst()
        }
        switch next {
        case .success(let link): return link
        case .failure(let failure): throw failure
        case nil: throw GATTFailure.timedOut
        }
    }
}
