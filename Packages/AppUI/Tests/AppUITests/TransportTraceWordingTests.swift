import BLEKit
import CameraTransport
import Foundation
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing
@testable import AppUI

// The bench lines for the wireless checks (W20): each event's exact line, and a whole Wi-Fi connection through the live
// composition (`WirelessConnections`: the real `WirelessSession`, the real hand-off, a real `IPLink` against the simulated
// camera) whose lines must carry no network name, password, serial, peripheral identifier, GUID or address but the camera's
// fixed gateway. Every wait is bounded.

@Suite("Bench lines: the Wi-Fi route's trace")
struct TransportTraceWordingTests {
    private func line(_ event: TransportTraceEvent) -> String { TransportTraceWording.line(for: event) }

    // MARK: Each line

    @Test func theJoinsLines() {
        #expect(line(.preparationStarted(joined: false, bluetoothFirst: false))
            == "wifi join: preparing an import: Bluetooth, then the join")
        #expect(line(.preparationStarted(joined: true, bluetoothFirst: false))
            == "wifi join: preparing an import on the camera's Wi-Fi, without a join")
        #expect(line(.preparationStarted(joined: true, bluetoothFirst: true))
            == "wifi join: preparing an import: the camera's Wi-Fi is presumed off, so Bluetooth first")
        #expect(line(.stayReopenGaveUp(after: .seconds(30)))
            == "wifi join: reopening on the camera's Wi-Fi gave up after 30.0 s; going back to Bluetooth")
        #expect(line(.bluetoothConnected(after: .milliseconds(2_140))) == "wifi join: Bluetooth connected in 2.1 s")
        #expect(line(.bluetoothSignal(dBm: -58, after: .milliseconds(2_150)))
            == "wifi join: Bluetooth RSSI -58 dBm, 2.2 s into the Bluetooth step (connect included)")
        #expect(line(.bluetoothSignal(dBm: nil, after: .zero))
            == "wifi join: Bluetooth RSSI not available, 0.0 s into the Bluetooth step (connect included)")
        #expect(line(.bluetoothDropped(afterWrite: true, reconnect: 1))
            == "wifi join: the Bluetooth link dropped during the hand-off after the CC08 write; connecting again (reconnect 1)")
        #expect(line(.handoffFinished(after: .milliseconds(4_340), rewrite: false, wroteWiFiOn: true, statusTwoAlready: false,
                                      windowLeft: .seconds(50)))
            == "wifi join: hand-off done in 4.3 s (connect included): CC08 written; 50.0 s left of the camera's 50 s")
        #expect(line(.handoffFinished(after: .seconds(1), rewrite: true, wroteWiFiOn: false, statusTwoAlready: true,
                                      windowLeft: .seconds(50)))
            == "wifi join: rewrite hand-off done in 1.0 s (connect included): no CC08 write, the camera's Wi-Fi was already on; "
            + "at most 50.0 s left of the camera's 50 s")
        #expect(line(.joinApplied(attempt: 1, after: .milliseconds(55_200), failure: nil, inFront: true))
            == "wifi join: join 1 returned after 55.2 s with the app in front (iOS's prompt included)")
        #expect(line(.joinApplied(attempt: 2, after: .milliseconds(400), failure: .userDenied, inFront: true))
            == "wifi join: join 2 failed after 0.4 s with the app in front: declined")
        #expect(line(.joinApplied(attempt: 1, after: .seconds(60), failure: nil, inFront: false))
            == "wifi join: join 1 returned after 60.0 s with the app away (iOS's prompt included)")
        #expect(line(.gateway(found: true, after: .milliseconds(1_250)))
            == "wifi join: the camera's gateway 192.168.122.1 appeared 1.3 s after the join")
        #expect(line(.gateway(found: false, after: .seconds(20)))
            == "wifi join: the camera's gateway didn't appear within 20.0 s of the join")
        #expect(line(.cameraWiFiChecked(.read(3), windowPassed: true, off: true))
            == "wifi join: after the join, CC09 Wi-Fi status 3 (stopping); the camera's 50 s have passed; its Wi-Fi is "
            + "off, so switching it on again")
        #expect(line(.cameraWiFiChecked(.read(2), windowPassed: false, off: false))
            == "wifi join: after the join, CC09 Wi-Fi status 2 (on); the camera's 50 s have not passed; its Wi-Fi is on, "
            + "so joining again as it is")
        #expect(line(.cameraWiFiChecked(.linkDown, windowPassed: true, off: true))
            == "wifi join: after the join, the Bluetooth link is down; the camera's 50 s have passed; its Wi-Fi is off, so "
            + "switching it on again")
        #expect(line(.rewriteStarted(number: 1, limit: 2)) == "wifi join: rewriting CC08, rewrite 1 of 2")
        #expect(line(.rejoinedWhileAway(found: true, after: .seconds(4)))
            == "wifi join: with the app away, iOS rejoined the camera's Wi-Fi 4.0 s after the hand-off")
        #expect(line(.sessionOpened(after: .milliseconds(3_400), tries: 1, reopening: false))
            == "wifi join: the camera's session opened 3.4 s after the first try, 1 try (fresh)")
        #expect(line(.sessionNotOpened(after: .seconds(60), tries: 61, refused: false))
            == "wifi join: the camera's session didn't open: no answer after 60.0 s, 61 tries")
        #expect(line(.preparationEnded(succeeded: true, times: WirelessStepTimes(
            total: .milliseconds(18_440), handingOff: .milliseconds(7_200), joining: .milliseconds(6_100),
            openingSession: .milliseconds(5_140))))
            == "wifi join: ready after 18.4 s (hand-off 7.2 s, join 6.1 s, session 5.1 s)")
    }

    @Test func theHandoffsLines() {
        #expect(line(.handoffStatus(0, after: .seconds(1))) == "wifi join: CC09 Wi-Fi status 0 (off) at 1.0 s into the hand-off")
        #expect(line(.handoffStatus(1, after: .milliseconds(1_090)))
            == "wifi join: CC09 Wi-Fi status 1 (starting) at 1.1 s into the hand-off")
        #expect(line(.handoffStatus(9, after: .zero)) == "wifi join: CC09 Wi-Fi status an unknown value at 0.0 s into the hand-off")
        #expect(line(.handoffStatus(nil, after: .zero)) == "wifi join: CC09 Wi-Fi status unreadable at 0.0 s into the hand-off")
        #expect(line(.handoffWroteWiFiOn(after: .seconds(1))) == "wifi join: CC08 written (Wi-Fi on) at 1.0 s into the hand-off")
        #expect(line(.handoffDetailsRead(after: .milliseconds(1_840), tries: 1))
            == "wifi join: network details read at 1.8 s into the hand-off, try 1")
    }

    @Test func theLinksLines() {
        #expect(line(.linkConnected(after: .milliseconds(300), reopening: false))
            == "wifi link: the camera answered on its port 0.3 s after the open began (fresh)")
        #expect(line(.linkOpened(after: .milliseconds(4_100), reopening: false, wholeCard: true, polls: 1,
                                 listedAfter: .milliseconds(200), pollTimedOut: false))
            == "wifi link: card ready 4.1 s after the open began, 1 poll, listed 0.2 s after the first poll (fresh)")
        #expect(line(.linkOpened(after: .seconds(32), reopening: true, wholeCard: true, polls: 7, listedAfter: nil,
                                 pollTimedOut: true))
            == "wifi link: card ready 32.0 s after the open began, 7 polls, the poll reached its limit (reopening)")
        #expect(line(.linkOpened(after: .seconds(2), reopening: false, wholeCard: false, polls: 0, listedAfter: nil,
                                 pollTimedOut: false))
            == "wifi link: session open 2.0 s after the open began, a plain session with no listing poll (fresh)")
        #expect(line(.keepAlive(number: 1, answered: true, idle: .seconds(10), sincePrevious: nil))
            == "wifi link: keep-alive 1 answered, 10.0 s after the last command, the first this session")
        #expect(line(.keepAlive(number: 3, answered: false, idle: .seconds(10), sincePrevious: .milliseconds(10_040)))
            == "wifi link: keep-alive 3 not answered, 10.0 s after the last command, 10.0 s after the previous keep-alive")
        #expect(line(.resumeStarted(offset: 16 * 1_048_576, size: 50_541_363))
            == "wifi link: resuming a file with 0x9211 from 16.0 MiB (16777216 B) of 48.2 MiB")
        #expect(line(.resumeRefused(offset: 16 * 1_048_576))
            == "wifi link: the camera refused the first 0x9211 read at 16.0 MiB (16777216 B); copying the file again from the start")
        #expect(line(.resumeFinished(reads: 9)) == "wifi link: the resumed file finished after 9 0x9211 reads")
        let none = IPThumbnailDiagnostics()
        #expect(line(.linkLost(.linkLost(posix: 53), thumbnails: none))
            == "wifi link: the session was lost: the network went away; GetThumb asked 0")
        #expect(line(.linkLost(.protocolViolation("serial 1234567 at 10.0.0.9"), thumbnails: none))
            == "wifi link: the session was lost: the camera's bytes broke PTP/IP; GetThumb asked 0")
        #expect(line(.linkLost(nil, thumbnails: none))
            == "wifi link: the session was lost: the camera answered SessionNotOpen; GetThumb asked 0")
        // A GetThumb never answered: the timeout shows right after the first thumbnails (bench 19.1).
        var thumbs = IPThumbnailDiagnostics()
        thumbs.asked = 3
        thumbs.answered = 1
        thumbs.bytesTotal = 7_397
        thumbs.timeouts = 1
        thumbs.failuresByCode = [.operationNotSupported: 1]
        thumbs.firstAfterOpen = .milliseconds(420)
        #expect(line(.linkLost(.timedOut(.transaction), thumbnails: thumbs))
            == "wifi link: the session was lost: no answer in time; GetThumb asked 3, answered 1 (7397 B), refused 1 "
            + "(OperationNotSupported 1), timed out 1, other failures 0, not listed 0, the first answered 0.4 s after the open")
        var seen = IPLinkDiagnostics()
        seen.sessionsOpened = 2
        seen.sessionsLost = 1
        seen.keepAlivesAnswered = 6
        seen.resumes = 1
        seen.partialReads = 9
        #expect(line(.linkClosed(seen))
            == "wifi link: closed: sessions opened 2, lost 1; keep-alives answered 6, failed 0; GetDevicePropValue sent 0; "
            + "0x9211 resumes 1, reads 9, refused 0; transfers aborted 0; GetThumb asked 0")
        seen.thumbnails.notListed = 12
        #expect(line(.linkClosed(seen)).hasSuffix("; GetThumb asked 0, answered 0 (0 B), refused 0, timed out 0, other "
            + "failures 0, not listed 12"))
        #expect(line(.linkClosed(IPLinkDiagnostics())) == "wifi link: closed without opening a session")
    }

    @Test func theHoldsLines() {
        #expect(line(.appWentToBackground(during: .handOff))
            == "wifi join: the app went to the background during the hand-off")
        #expect(line(.appCameBack(after: .milliseconds(74_200), during: .join))
            == "wifi join: the app came back after 74.2 s, during the join")
        #expect(line(.joinHeld(reason: .beforeJoin, limit: .seconds(300)))
            == "wifi join: join held before the join: the app is away; waiting for it to come back (at most 300.0 s)")
        #expect(line(.joinHeld(reason: .joinRefused, limit: .seconds(300)))
            == "wifi join: join held after iOS refused the join with the app away (code 14): the app is away; waiting for "
            + "it to come back (at most 300.0 s)")
        #expect(line(.joinHeld(reason: .beforeSwitchOn, limit: .seconds(300))).contains("before switching the camera's Wi-Fi on again"))
        #expect(line(.joinHeld(reason: .retryHandoff, limit: .seconds(300))).contains("before running the hand-off again"))
        #expect(line(.joinHoldEnded(after: .seconds(28), windowPassed: false))
            == "wifi join: the app is back after 28.0 s; the camera's 50 s have not passed; joining now")
        #expect(line(.joinHoldEnded(after: .seconds(90), windowPassed: true))
            == "wifi join: the app is back after 90.0 s; the camera's 50 s have passed; joining now")
        #expect(line(.joinHoldRanOut(after: .seconds(300))) == "wifi join: the hold ran out after 300.0 s; letting go")
        #expect(line(.handoffRetriedAfterAway(rewrite: true, failure: .timedOut(lastStatus: nil)))
            == "wifi join: the rewrite hand-off failed with the app away for part of it (timed out waiting for Wi-Fi "
            + "(last status unknown)); running it once more from the front")
        #expect(line(.preparationFailed(rewrite: true, appAway: .milliseconds(74_200)))
            == "wifi join: the preparation failed in a rewrite hand-off; the app was away 74.2 s in all since it began")
        #expect(line(.preparationFailed(rewrite: false, appAway: .zero))
            == "wifi join: the preparation failed outside a rewrite hand-off; the app was away 0.0 s in all since it began")
    }

    @Test func secondsAndSizesRound() {
        #expect(TransportTraceWording.seconds(.milliseconds(49)) == "0.0 s")
        #expect(TransportTraceWording.seconds(.milliseconds(50)) == "0.1 s")
        #expect(TransportTraceWording.seconds(.milliseconds(-400)) == "0.0 s")
        #expect(TransportTraceWording.seconds(.seconds(180)) == "180.0 s")
        #expect(TransportTraceWording.mebibytes(0) == "0.0 MiB")
        #expect(TransportTraceWording.mebibytes(1_048_576 + 524_288) == "1.5 MiB")
    }

    @Test func theBenchTraceWritesOneLinePerEvent() {
        let log = RecordingLog()
        let trace = TransportTrace.bench(log)
        #expect(trace.isOn)
        let events: [TransportTraceEvent] = [.rewriteStarted(number: 1, limit: 2), .resumeFinished(reads: 1)]
        for event in events { trace.record(event) }
        #expect(log.lines == ["wifi join: rewriting CC08, rewrite 1 of 2",
                              "wifi link: the resumed file finished after 1 0x9211 read"])
    }

    // MARK: A whole connection, with fake identifiers fed through it

    @Test(.timeLimit(.minutes(1)))
    func aWholeConnectionLogsNoNetworkNamePasswordOrIdentifier() async throws {
        let ssid = "DIRECT-Qx7k:ILCE-7CM2"
        let passphrase = "Fake-Pass-8813"
        let peripheral = UUID(uuidString: "5A4B3C2D-1E0F-4A1B-9C8D-7E6F5A4B3C2D")!
        let guid = UUID(uuidString: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A")!
        let card = try #require(ScriptedCard.shoot([.jpeg, .raw])).scaled(down: 100)
        let camera = try InMemoryPTPIPCamera(card: card, flavour: .ptpIP)
        let clock = FastClock(camera: camera)
        let gatt = ScriptedCameraGATT(peripheral: PeripheralID(peripheral), ssid: ssid, passphrase: passphrase)
        let joiner = RecordingJoiner()
        let log = RecordingLog()
        let connections = WirelessConnections(
            connector: OneLinkConnector(gatt), joiner: joiner, path: GatewayAtOnce(),
            foreground: SceneForegroundSignal(inForeground: true), channels: camera, clock: clock, trace: .bench(log))
        let entry = WiFiCameraEntry(
            descriptor: CameraDescriptor(id: .init(rawValue: "wifi-trace"), name: "Camera", mode: .wifi(.cameraNetwork)),
            key: nil, peripheral: PeripheralID(peripheral), guid: guid, typed: nil)
        let session = connections.session(for: entry)
        let opened = Task { () -> (any CameraLink)? in try? await session.prepareImport() }
        let link = try #require(await bounded(opened))
        let serial = try #require(await (link as? IPLink)?.deviceInfo?.serialNumber)
        // Two keep-alives (10 s apart on the session's clock), then the leave closes the link.
        #expect(await waitUntil(seconds: 20) { log.lines.filter { $0.hasPrefix("wifi link: keep-alive") }.count >= 2 })
        await session.leave()
        #expect(await waitUntil(seconds: 20) { log.lines.contains { $0.hasPrefix("wifi link: closed:") } })
        #expect(await waitUntil(seconds: 20) {
            log.lines.filter { $0.hasPrefix("wifi join: Bluetooth RSSI -61 dBm") }.count == 2
        })

        let lines = log.lines
        // The identifiers really went through: the join used the network name, the camera has a serial.
        #expect(joiner.applied == [ssid])
        #expect(!serial.isEmpty)
        // What the bench checks need is there.
        for prefix in ["wifi join: preparing an import: Bluetooth, then the join", "wifi join: Bluetooth connected in",
                       "wifi join: CC09 Wi-Fi status 0 (off)", "wifi join: CC08 written (Wi-Fi on)",
                       "wifi join: CC09 Wi-Fi status 2 (on)", "wifi join: network details read",
                       "wifi join: hand-off done in", "wifi join: join 1 returned after",
                       "wifi join: the camera's gateway 192.168.122.1 appeared", "wifi link: the camera answered on its port",
                       "wifi link: card ready", "wifi join: the camera's session opened", "wifi join: ready after",
                       "wifi link: keep-alive 1 answered", "wifi link: keep-alive 2 answered"] {
            #expect(lines.contains { $0.hasPrefix(prefix) }, "no line starting \"\(prefix)\" in \(lines)")
        }
        #expect(lines.contains { $0.contains("GetDevicePropValue sent 0;") })
        // And nothing that identifies the network, the phone, the camera or an address.
        let secrets = [ssid, "DIRECT-", "Qx7k", passphrase, "8813", serial, peripheral.uuidString,
                       peripheral.uuidString.lowercased(), guid.uuidString, guid.uuidString.lowercased(), "ILCE"]
        for line in lines {
            for secret in secrets { #expect(!line.contains(secret), "\"\(line)\" holds an identifier") }
            for address in Self.ipv4Addresses(in: line) {
                #expect(address == WirelessCamera.cameraNetworkGateway, "\"\(line)\" holds the address \(address)")
            }
        }
    }

    /// Every dotted quad in `line`.
    static func ipv4Addresses(in line: String) -> [String] {
        var found: [String] = []
        var current = ""
        func flush() {
            let parts = current.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 }) { found.append(current) }
            current = ""
        }
        for character in line {
            if character.isASCII, character.isNumber || character == "." { current.append(character) } else { flush() }
        }
        flush()
        return found.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }
}

// MARK: - Fakes

/// A clock 20 times faster than real time, whose camera's time follows it (the simulated camera's own time moves only when
/// told: its card appears and its idle drop runs on it).
private final class FastClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    static let factor = 20
    private let origin = ContinuousClock.now
    private let camera: InMemoryPTPIPCamera
    private let cameraTime = Mutex(Duration.zero)

    init(camera: InMemoryPTPIPCamera) { self.camera = camera }

    var now: Instant { Instant(offset: (ContinuousClock.now - origin) * Self.factor) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let remaining = now.duration(to: deadline)
        if remaining > .zero { try await Task.sleep(for: remaining / Self.factor) }
        let target = now.offset
        let step = cameraTime.withLock { time -> Duration in
            let step = max(.zero, target - time)
            time += step
            return step
        }
        if step > .zero { camera.advance(by: step) }
    }
}

/// The camera over Bluetooth: CC09 at 0 until CC08 is written, then 1 and 2 as notifications; the network's details as the
/// camera sends them; an RSSI of -61 dBm.
private final class ScriptedCameraGATT: GATTLink, GATTSignalReading, @unchecked Sendable {
    let peripheral: PeripheralID
    let anotherAppHoldsLink = false
    private let ssid: String
    private let passphrase: String
    private let lock = NSLock()
    private var status: UInt8 = 0
    private var connected = true
    private var sinks: [AsyncStream<(CameraControlCharacteristic, Data)>.Continuation] = []

    init(peripheral: PeripheralID, ssid: String, passphrase: String) {
        self.peripheral = peripheral
        self.ssid = ssid
        self.passphrase = passphrase
    }

    var notifications: AsyncStream<(CameraControlCharacteristic, Data)> {
        let (stream, continuation) = AsyncStream.makeStream(of: (CameraControlCharacteristic, Data).self)
        lock.withLock { connected ? sinks.append(continuation) : continuation.finish() }
        return stream
    }

    var state: AsyncStream<GATTLinkState> {
        let up = lock.withLock { connected }
        return AsyncStream { continuation in
            continuation.yield(up ? .connected : .dropped(.cancelled))
            continuation.finish()
        }
    }

    func read(_ characteristic: CameraControlCharacteristic, timeout: Duration?) async throws(GATTFailure) -> Data {
        switch characteristic {
        case .status: return Self.statusRead(lock.withLock { status })
        case .ssid: return Data([0x01, 0x02, 0x03] + Array(ssid.utf8))
        case .passphrase: return Data([0x01, 0x02, 0x03] + Array(passphrase.utf8))
        default: return Data()
        }
    }

    func write(_ write: CameraControlWrite, timeout: Duration) async throws(GATTFailure) {
        guard write == .wifiOn else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(5))
            self.announce(1)
            try? await Task.sleep(for: .milliseconds(5))
            self.announce(2)
        }
    }

    func setNotify(_ on: Bool, _ characteristic: CameraControlCharacteristic, timeout: Duration) async throws(GATTFailure) {}

    func disconnect() async {
        let ended = lock.withLock { () -> [AsyncStream<(CameraControlCharacteristic, Data)>.Continuation] in
            connected = false
            defer { sinks = [] }
            return sinks
        }
        for sink in ended { sink.finish() }
    }

    func readSignalStrength(timeout: Duration) async -> Int? { -61 }

    private func announce(_ value: UInt8) {
        let current = lock.withLock { () -> [AsyncStream<(CameraControlCharacteristic, Data)>.Continuation] in
            status = value
            return sinks
        }
        for sink in current { sink.yield((.status, Data([0x04, 0x00, 0x01, value, 0x00]))) }
    }

    /// A CC09 read with tag 0x0001 carrying the status (the layout spike-findings.md records; synthetic).
    static func statusRead(_ status: UInt8) -> Data {
        Data([0x04, 0x00, 0x01, status, 0x00, 0x03, 0x00, 0x02, 0x01, 0x03, 0x00, 0x03, 0x01])
    }
}

private final class OneLinkConnector: GATTConnector, Sendable {
    private let link: ScriptedCameraGATT
    init(_ link: ScriptedCameraGATT) { self.link = link }
    func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink { link }
}

private final class RecordingJoiner: HotspotJoining, @unchecked Sendable {
    private let lock = NSLock()
    private var networks: [String] = []
    var applied: [String] { lock.withLock { networks } }
    func apply(_ credentials: SonyWiFiCredentials) async throws(JoinFailure) {
        lock.withLock { networks.append(credentials.ssid) }
    }
    func leave(ssid: String) async {}
}

private struct GatewayAtOnce: WiFiPathWatching {
    func gateway() async -> String? { WirelessCamera.cameraNetworkGateway }
    func waitForGateway(_ ip: String, timeout: Duration) async -> Bool { true }
}
