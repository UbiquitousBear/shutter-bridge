// The proximity scan's model (Iteration 4, section 11; W17): confirmation against the catalogue's cameras, arrivals for the
// reminder rules, and restarts from wakes only, against a fake scanner and fixed dates.

import CameraTransport
import Catalogue
import Foundation
import Synchronization
import Testing
@testable import AppUI

/// A scanner that records what the model asks of it; reports and power are sent by the test.
private final class FakeScanner: ProximityScanning, @unchecked Sendable {
    enum Call: Equatable { case start, restart, stop }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let proximityReports: AsyncStream<ProximityReport>
    private let reportSink: AsyncStream<ProximityReport>.Continuation
    private let powerStream: AsyncStream<BluetoothPower>
    private let powerSink: AsyncStream<BluetoothPower>.Continuation

    init() {
        (proximityReports, reportSink) = AsyncStream.makeStream()
        (powerStream, powerSink) = AsyncStream.makeStream()
    }

    var powerState: AsyncStream<BluetoothPower> { powerStream }
    var calls: [Call] { lock.withLock { recorded } }

    func startProximityScan() async { lock.withLock { recorded.append(.start) } }
    func restartProximityScan() async { lock.withLock { recorded.append(.restart) } }
    func stopProximityScan() async { lock.withLock { recorded.append(.stop) } }

    func send(_ report: ProximityReport) { reportSink.yield(report) }
    func send(_ power: BluetoothPower) { powerSink.yield(power) }
}

/// Records every ask: `.some(nil)` is a cancel. `settles` counts the asks made before each wait to settle.
private final class FakeRefresh: ProximityRefreshScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Date?] = []
    private var settled: [Int] = []
    var asks: [Date?] { lock.withLock { recorded } }
    var settles: [Int] { lock.withLock { settled } }
    func scheduleRefresh(earliest date: Date?) { lock.withLock { recorded.append(date) } }
    func settle(within limit: Duration) async {
        #expect(limit == ProximityModel.refreshSettleLimit)
        lock.withLock { settled.append(recorded.count) }
    }
}

private final class ProximityRecordingLog: BenchLog, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var lines: [String] { lock.withLock { recorded } }
    func note(_ line: String) { lock.withLock { recorded.append(line) } }
}

/// A wall clock the test moves.
private final class TestNow: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_794_000_000))
    var date: Date { value.withLock { $0 } }
    func advance(minutes: Double) { value.withLock { $0 = $0.addingTimeInterval(minutes * 60) } }
}

private let sonyData = Data([0x2D, 0x01] + [UInt8](repeating: 0x5A, count: 20))
private let pairedID = UUID(uuidString: "0E1D2C3B-4A59-6877-8695-A4B3C2D1E0F0")!

private func record(_ key: String, peripheral: UUID? = nil, model: String = "ILCE-7CM2") -> CameraRecord {
    CameraRecord(key: CameraKey(rawValue: key), model: model, bluetoothPeripheralID: peripheral)
}

@MainActor
private struct Harness {
    let scanner = FakeScanner()
    let refresh = FakeRefresh()
    let log = ProximityRecordingLog()
    let now = TestNow()
    let model: ProximityModel

    init() {
        let now = now
        model = ProximityModel(scanner: scanner, refresh: refresh, now: { now.date }, log: log)
        model.setKnownCameras([record("paired", peripheral: pairedID), record("usb-only", model: "")])
    }

    func report(_ id: UUID = pairedID, data: Data? = sonyData, name: String? = "ILCE-7CM2") -> ProximityReport {
        ProximityReport(peripheral: PeripheralID(id), at: now.date, rssi: -70, manufacturerData: data, name: name)
    }
}

@MainActor
@Suite("Proximity model")
struct ProximityModelTests {
    @Test func theRefreshIdentifierIsTheOneInInfoPlist() {
        #expect(ProximityModel.refreshTaskIdentifier == "net.shamil.shutter-bridge.proximity-refresh")
    }

    @Test func itIsOffByDefaultAndIgnoresReports() async {
        let h = Harness()
        #expect(!h.model.isEnabled)
        await h.model.handle(h.report())
        await h.model.appBecameActive()
        #expect(h.scanner.calls.isEmpty)
        #expect(h.model.lastNearby.isEmpty)
    }

    @Test func switchingOnStartsTheScanAndCancelsALeftoverRefresh() async {
        let h = Harness()
        await h.model.setEnabled(true)
        #expect(h.scanner.calls == [.start])
        #expect(h.refresh.asks == [nil])
        await h.model.setEnabled(true) // again: nothing more
        #expect(h.scanner.calls == [.start])
    }

    @Test func aKnownCameraIsAnArrivalAndAsksForTheRearmRefresh() async {
        let h = Harness()
        await h.model.setEnabled(true)
        let report = h.report()
        await h.model.handle(report)
        #expect(h.model.lastNearby == [CameraKey(rawValue: "paired"): report.at])
        #expect(h.scanner.calls == [.start]) // no restart: the camera was just reported
        #expect(h.refresh.asks == [nil, h.now.date.addingTimeInterval(1800)])
        var arrivals = h.model.arrivals.makeAsyncIterator()
        let arrival = await arrivals.next()
        #expect(arrival == ProximityArrival(camera: CameraKey(rawValue: "paired"), report: report, match: .storedIdentifier))
    }

    @Test func aSonyCameraWithoutAnIdentifierIsConfirmedByCompanyAndName() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(h.report(UUID(), name: "ILCE-7M4"))
        #expect(h.model.lastNearby.keys.map(\.rawValue) == ["usb-only"])
    }

    @Test func anythingElseAdvertising1800IsIgnored() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(h.report(UUID(), data: Data([0x4C, 0x00, 1, 2]), name: "Headphones"))
        #expect(h.model.lastNearby.isEmpty)
        #expect(h.scanner.calls == [.start])
        #expect(h.refresh.asks == [nil])
    }

    @Test func aWakeAfterTheRearmRestartsTheScan() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(h.report())
        h.now.advance(minutes: 10)
        await h.model.handle(h.report(UUID(), data: nil, name: nil)) // something else, too early
        #expect(h.scanner.calls == [.start])
        h.now.advance(minutes: 21)
        await h.model.handle(h.report(UUID(), data: nil, name: nil)) // something else, rearm due
        #expect(h.scanner.calls == [.start, .restart])
        #expect(h.refresh.asks.last == .some(nil)) // nothing waiting any more: the refresh is cancelled
    }

    @Test func theRefreshTaskRestartsWhenTheRearmIsDue() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(h.report())
        let rearm = h.now.date.addingTimeInterval(1800)
        h.now.advance(minutes: 5)
        await h.model.refreshTaskRan()
        #expect(h.scanner.calls == [.start])
        // Asked again: running the task used the request up, and the first submit may have failed.
        #expect(h.refresh.asks == [nil, rearm, rearm])
        // And it waited for that ask to settle before ending (iOS may suspend the app once the task is complete).
        #expect(h.refresh.settles == [3])
        await h.model.appBecameActive()
        await h.model.handle(h.report())
        let second = h.now.date.addingTimeInterval(1800)
        await h.model.handle(h.report(UUID(), data: nil, name: nil)) // a wake that isn't due: the same ask isn't sent twice
        #expect(h.refresh.asks == [nil, rearm, rearm, nil, second])
        h.now.advance(minutes: 31)
        await h.model.refreshTaskRan()
        #expect(h.scanner.calls == [.start, .restart, .restart])
        #expect(h.refresh.asks == [nil, rearm, rearm, nil, second, nil])
        // Only the refresh task waits: the reports and coming to the front in between didn't.
        #expect(h.refresh.settles == [3, 6])
    }

    @Test func comingToTheFrontRestarts() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(h.report())
        await h.model.appBecameActive()
        #expect(h.scanner.calls == [.start, .restart])
        #expect(h.refresh.asks.last == .some(nil))
    }

    @Test func bluetoothComingBackOnStartsTheScan() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(power: .poweredOn)
        #expect(h.scanner.calls == [.start, .start])
        await h.model.handle(power: .poweredOn) // no change: nothing
        await h.model.handle(power: .poweredOff)
        #expect(h.scanner.calls == [.start, .start])
        await h.model.handle(power: .poweredOn)
        #expect(h.scanner.calls == [.start, .start, .start])
        #expect(h.model.power == .poweredOn)
    }

    @Test func switchingOffStopsTheScanAndCancelsTheRefresh() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(h.report())
        await h.model.setEnabled(false)
        #expect(h.scanner.calls == [.start, .stop])
        #expect(h.refresh.asks.last == .some(nil))
        await h.model.handle(h.report())
        await h.model.refreshTaskRan()
        await h.model.handle(power: .poweredOn)
        #expect(h.scanner.calls == [.start, .stop])
        // Switched off, the task still cancels the refresh and waits for that to settle.
        #expect(h.refresh.asks.last == .some(nil))
        #expect(h.refresh.settles == [h.refresh.asks.count])
    }

    @Test func launchReadsTheScannersReportsAndPower() async {
        let h = Harness()
        await h.model.setEnabled(true)
        h.model.launch()
        h.model.launch() // once only
        h.scanner.send(.poweredOn)
        h.scanner.send(h.report())
        #expect(await eventually {
            h.model.lastNearby.count == 1 && h.model.power == .poweredOn && h.scanner.calls.count == 2
        })
        #expect(h.scanner.calls == [.start, .start])
    }

    @Test func aReportReadBeforeTheSettingIsDecidedIsHandledWhenSwitchedOn() async {
        // A relaunch for the scan: the report is waiting, `launch()` reads it, and the setting is read after.
        let h = Harness()
        let report = h.report()
        h.scanner.send(report)
        h.model.launch()
        #expect(await eventually { h.model.heldReports.count == 1 })
        #expect(h.model.lastNearby.isEmpty)
        await h.model.setEnabled(true)
        #expect(h.model.lastNearby == [CameraKey(rawValue: "paired"): report.at])
        #expect(h.model.heldReports.isEmpty)
        #expect(h.scanner.calls == [.start])
        var arrivals = h.model.arrivals.makeAsyncIterator()
        #expect(await arrivals.next()?.camera == CameraKey(rawValue: "paired"))
    }

    @Test func theFirstDecisionOffStopsAScanIOSHandedBackAndDropsHeldReports() async {
        let h = Harness()
        await h.model.handle(h.report())
        await h.model.setEnabled(false)
        #expect(h.scanner.calls == [.stop])
        #expect(h.refresh.asks == [nil])
        #expect(h.model.heldReports.isEmpty)
        #expect(h.model.lastNearby.isEmpty)
        await h.model.setEnabled(false) // again: nothing more
        #expect(h.scanner.calls == [.stop])
        await h.model.setEnabled(true)
        #expect(h.model.lastNearby.isEmpty) // the dropped report isn't handled later
        #expect(h.scanner.calls == [.stop, .start])
    }

    @Test func newCamerasAreConfirmedOnceKnown() async {
        let h = Harness()
        await h.model.setEnabled(true)
        let newID = UUID()
        await h.model.handle(h.report(newID, data: nil, name: nil))
        #expect(h.model.lastNearby.isEmpty)
        h.model.setKnownCameras([record("new", peripheral: newID)])
        await h.model.handle(h.report(newID, data: nil, name: nil))
        #expect(h.model.lastNearby.keys.map(\.rawValue) == ["new"])
    }

    @Test func theLogNamesNoCameraPeripheralOrManufacturerData() async {
        let h = Harness()
        await h.model.setEnabled(true)
        await h.model.handle(h.report())
        await h.model.handle(h.report(UUID(), data: sonyData, name: "WH-1000XM5"))
        #expect(h.log.lines.count >= 3)
        for line in h.log.lines {
            #expect(!line.contains(pairedID.uuidString))
            #expect(!line.uppercased().contains("ILCE"))
            #expect(!line.contains("WH-1000"))
            #expect(!line.contains("paired") && !line.contains("usb-only"))
            #expect(!line.contains("5A5A") && !line.contains("9090")) // the payload, in hex or decimal
        }
        #expect(h.log.lines.contains { $0.contains("confirmed by stored identifier") && $0.contains("RSSI -70 dBm") })
    }

    @Test func theCopySaysNearbyAndMayStop() {
        #expect(ProximityWording.swipeAwayStops.contains("reminders stop"))
        #expect(ProximityWording.lowPowerMayStop.contains("may stop"))
        #expect(!ProximityWording.cameraSetting.lowercased().contains("switched on"))
    }
}

@Suite("Info.plist for the proximity scan")
struct ProximityInfoPlistTests {
    /// App/Info.plist, found from this file's path (Packages/AppUI/Tests/AppUITests/), so it is the one the app builds with;
    /// nil where the checkout isn't reachable (a test bundle run away from its sources), as `CapturedFixtureCopyTests` does.
    private func infoPlist(file: String = #filePath) throws -> [String: Any]? {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent() // AppUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AppUI
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // the repository
        guard let data = try? Data(contentsOf: root.appendingPathComponent("App/Info.plist")) else { return nil }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func theBackgroundModesAreBluetoothCentralAndFetch() throws {
        guard let plist = try infoPlist() else { return }
        let modes = try #require(plist["UIBackgroundModes"] as? [String])
        #expect(modes.contains("bluetooth-central"))
        #expect(modes.contains("fetch"))
    }

    @Test func theRefreshTaskIsPermitted() throws {
        guard let plist = try infoPlist() else { return }
        let identifiers = try #require(plist["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        #expect(identifiers.contains(ProximityModel.refreshTaskIdentifier))
    }

    @Test func theBluetoothPurposeMentionsTheReminder() throws {
        guard let plist = try infoPlist() else { return }
        let purpose = try #require(plist["NSBluetoothAlwaysUsageDescription"] as? String)
        #expect(purpose.contains("nearby"))
    }
}
