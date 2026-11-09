#if canImport(CoreBluetooth) && os(iOS)
import BLEKit
import CoreBluetooth
import Dispatch
import Foundation
import Synchronization

// The app's one Core Bluetooth central (plan section 0, item 2; backlog section 0, "One owner for Core Bluetooth"). The pairing
// check, the Wi-Fi hand-off and (from W17) the proximity scan all go through it. Compiled only for iOS (CI's Xcode 27 job); the
// rules it applies are pure and tested on Linux (`BluetoothRules.swift`, `CBContinuations.swift`).
//
// Concurrency, in short: the central's actor runs on a private serial queue (its executor), and Core Bluetooth calls the
// delegates on that same queue, so every Core Bluetooth object is only ever used there. The delegate (`CentralBridge`) holds
// nothing but an `AsyncStream` continuation: each callback reads what it needs off the objects it was given, turns it into a
// `Sendable` signal and yields it, in order, to the actor, which owns every piece of state. A call that waits for a callback
// (connect, discovery, read, write, notification switch) is parked in a `GATTCallBroker`, which ends it exactly once: by the
// answer, its time limit, the caller's cancellation, or the link or Bluetooth going away.

/// A Core Bluetooth object handed from a delegate callback to `BluetoothCentral`. `@unchecked Sendable` because both sides run
/// on the central's queue (the actor's executor is that queue, and Core Bluetooth calls the delegate there), so the object is
/// only ever used on one serial queue. The box itself does nothing with it.
struct CBObject<Object: AnyObject>: @unchecked Sendable {
    let object: Object
}

/// A Core Bluetooth error, by domain and code: all the mapping needs (`GATTFailure.classify(domain:code:reading:)`).
struct CBErrorInfo: Sendable, Equatable {
    let domain: String
    let code: Int

    init?(_ error: (any Error)?) {
        guard let error else { return nil }
        let ns = error as NSError
        domain = ns.domain
        code = ns.code
    }
}

/// What the delegates report to `BluetoothCentral`, read off Core Bluetooth's objects inside the callback.
enum CentralSignal: Sendable {
    case power(BluetoothPower)
    /// `willRestoreState`: the peripherals iOS hands back after relaunching the app, and the services of the scan it kept
    /// running (full UUIDs; the proximity scan's is 1800).
    case restored([CBObject<CBPeripheral>], scanServices: [UUID])
    /// `didDiscover`. The RSSI is Core Bluetooth's, 127 when it had none.
    case discovered(CBObject<CBPeripheral>, manufacturerData: Data?, name: String?, rssi: Int)
    /// `connectionEventDidOccur` for a peer matching the proximity scan's registration (W17; never relied on).
    case connectionEvent(UUID, name: String?, peerConnected: Bool)
    case connected(UUID)
    case failedToConnect(UUID, CBErrorInfo?)
    case disconnected(UUID, CBErrorInfo?)
    case servicesDiscovered(UUID, CBErrorInfo?)
    case characteristicsDiscovered(UUID, cameraControl: Bool, CBErrorInfo?)
    /// `didUpdateValueFor` on a characteristic of service 8000CC00: a read's answer or a notification. The value is copied
    /// in the callback, so a later one can't replace it.
    case value(UUID, CameraControlCharacteristic, Data?, isNotifying: Bool, CBErrorInfo?)
    case wrote(UUID, CameraControlCharacteristic, CBErrorInfo?)
    case notificationState(UUID, CameraControlCharacteristic, isNotifying: Bool, CBErrorInfo?)
    /// `didModifyServices` invalidated service 8000CC00 (a firmware change, or the camera re-listing its services).
    case cameraControlInvalidated(UUID)
}

/// The central's and every peripheral's delegate. Callbacks come on the central's queue.
final class CentralBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, Sendable {
    private let signals: AsyncStream<CentralSignal>.Continuation

    init(_ signals: AsyncStream<CentralSignal>.Continuation) {
        self.signals = signals
        super.init()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        signals.yield(.power(BluetoothPower(central.state)))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        // Set here, on the central's queue, as Apple asks, so no callback for them reaches a nil delegate before the signal
        // has reached the actor.
        for peripheral in peripherals { peripheral.delegate = self }
        // Core Bluetooth's text form of a 16-bit UUID is the short one ("1800"), which `SonyBluetooth.uuid(bluetoothString:)`
        // takes as well as the full form.
        let services = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] ?? []
        let scanServices = services.compactMap { SonyBluetooth.uuid(bluetoothString: $0.uuidString) }
        signals.yield(.restored(peripherals.map { CBObject(object: $0) }, scanServices: scanServices))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        signals.yield(.discovered(CBObject(object: peripheral), manufacturerData: manufacturerData, name: name,
                                  rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent,
                        for peripheral: CBPeripheral) {
        signals.yield(.connectionEvent(peripheral.identifier, name: peripheral.name, peerConnected: event == .peerConnected))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        signals.yield(.connected(peripheral.identifier))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        signals.yield(.failedToConnect(peripheral.identifier, CBErrorInfo(error)))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        signals.yield(.disconnected(peripheral.identifier, CBErrorInfo(error)))
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        signals.yield(.servicesDiscovered(peripheral.identifier, CBErrorInfo(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        signals.yield(.characteristicsDiscovered(peripheral.identifier, cameraControl: Self.isCameraControl(service.uuid),
                                                 CBErrorInfo(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let code = Self.code(of: characteristic) else { return }
        signals.yield(.value(peripheral.identifier, code, characteristic.value, isNotifying: characteristic.isNotifying,
                             CBErrorInfo(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let code = Self.code(of: characteristic) else { return }
        signals.yield(.wrote(peripheral.identifier, code, CBErrorInfo(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard let code = Self.code(of: characteristic) else { return }
        signals.yield(.notificationState(peripheral.identifier, code, isNotifying: characteristic.isNotifying,
                                         CBErrorInfo(error)))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // Only 8000CC00 matters; the characteristics of a service that wasn't invalidated stay valid (the spike's rule).
        guard invalidatedServices.contains(where: { Self.isCameraControl($0.uuid) }) else { return }
        signals.yield(.cameraControlInvalidated(peripheral.identifier))
    }

    // MARK: Identifiers

    /// Whether a service UUID is 8000CC00. Core Bluetooth's text form goes through `SonyBluetooth.uuid(bluetoothString:)`,
    /// which also takes the 16-bit short form.
    static func isCameraControl(_ uuid: CBUUID) -> Bool {
        SonyBluetooth.uuid(bluetoothString: uuid.uuidString) == SonyService.cameraControl.uuid
    }

    /// The characteristic of service 8000CC00 this is, or nil for any other (a characteristic of another service, or one of
    /// 8000CC00's seventy-odd that the app doesn't use).
    static func code(of characteristic: CBCharacteristic) -> CameraControlCharacteristic? {
        guard let service = characteristic.service, isCameraControl(service.uuid),
              let uuid = SonyBluetooth.uuid(bluetoothString: characteristic.uuid.uuidString) else { return nil }
        return CameraControlCharacteristic(uuid: uuid)
    }
}

extension BluetoothPower {
    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorised
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

extension BluetoothAuthorisation {
    init(_ authorisation: CBManagerAuthorization) {
        switch authorisation {
        case .allowedAlways: self = .allowedAlways
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }

    /// The app's Bluetooth permission now (`CBManager.authorization`). Reading it never prompts.
    public static var current: BluetoothAuthorisation { BluetoothAuthorisation(CBManager.authorization) }
}

/// The app's one Core Bluetooth central: the only place a `CBCentralManager` is made, with one restore identifier. It finds and
/// connects to the camera and hands out `GATTLink`s for the pairing check and the Wi-Fi hand-off.
///
/// - **Made once.** `shared()` makes it on first use, which shows the Bluetooth permission prompt if the person hasn't been
///   asked (onboarding's pairing step, backlog section 6). At launch the app calls `makeAtLaunchIfAllowed(remindersOn:)`,
///   which makes it only when that can't prompt, so state restoration (W17) finds it. Both return the same instance.
/// - **Finding the camera** (`connect(known:)`): the stored identifier, then a camera iOS lists as connected to the system
///   with service 8000CC00, then a 10 s scan for Sony's company ID and a camera's name (`BluetoothConnectPlan`).
/// - **One link per camera.** A second `connect` to a camera that already has a link closes the first (its calls fail with
///   `.cancelled`). Connects are meant to be made one at a time (the pairing check and the hand-off never overlap).
/// - **The scan replaces any other.** Core Bluetooth runs one scan per central, so the connect's scan replaces the proximity
///   scan while it runs, and the proximity scan starts again when it ends (`BluetoothCentral+Proximity.swift`).
/// - **The proximity scan** (W17, backlog section 11): `startProximityScan()` scans for service 1800 without duplicates, and
///   `proximityReports` carries what it finds, unconfirmed. A scan iOS hands back after relaunching the app
///   (`willRestoreState`, reported on `restored`) is kept, not restarted; after Bluetooth comes back on, the scan starts again
///   by itself while it is wanted.
/// - Nothing here logs a value. The network name and password read through a link never leave the call that read them, and
///   are never put on a notification stream (`GATTValueRoute`).
public actor BluetoothCentral: GATTConnector {
    /// The restore identifier the central is made with from day one, so iOS can hand back the proximity scan after it ends
    /// the app (W17; backlog section 11).
    public static let restoreIdentifier = "net.shamil.shutter-bridge.central"

    private static let instance = Mutex<BluetoothCentral?>(nil)

    /// The central, made now if it hasn't been. The first call shows the Bluetooth permission prompt when the person hasn't
    /// been asked, so call it only where that is expected (the pairing step, or *Import* over Wi-Fi).
    public static func shared() -> BluetoothCentral {
        instance.withLock { current in
            if let current { return current }
            let made = BluetoothCentral()
            current = made
            return made
        }
    }

    /// For the app's launch (`didFinishLaunching`, before any UI): the central, made now, when the proximity reminder is on or
    /// Bluetooth is already allowed (`BluetoothLaunchRule`); else nil, and nothing is made. Never prompts.
    public static func makeAtLaunchIfAllowed(remindersOn: Bool) -> BluetoothCentral? {
        makeAtLaunchIfAllowed(remindersOn: remindersOn, authorisation: { BluetoothAuthorisation.current })
    }

    /// `makeAtLaunchIfAllowed(remindersOn:)` with the permission read through `authorisation`, for tests.
    static func makeAtLaunchIfAllowed(
        remindersOn: Bool, authorisation: () -> BluetoothAuthorisation
    ) -> BluetoothCentral? {
        guard BluetoothLaunchRule.createsCentralAtLaunch(remindersOn: remindersOn, authorisation: authorisation()) else {
            return nil
        }
        return shared()
    }

    /// Whether the central has been made (for tests).
    static var isMade: Bool { instance.withLock { $0 != nil } }

    // MARK: Instance

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The phone's Bluetooth: a new stream on every access, starting with the state now (`unknown` until Core Bluetooth has
    /// reported), then every change.
    public nonisolated var powerState: AsyncStream<BluetoothPower> { power.subscribe() }

    private struct LinkRecord {
        let link: CoreBluetoothGATTLink
        let peripheral: CBPeripheral
        let characteristics: [CameraControlCharacteristic: CBCharacteristic]
    }

    private struct Closing {
        let token: UInt64
        let peripheral: CBPeripheral
    }

    private nonisolated let queue: DispatchSerialQueue
    nonisolated let broker: GATTCallBroker
    private nonisolated let power: LatestValueFanOut<BluetoothPower>
    /// The proximity scan's reports, held until the proximity model subscribes (`BluetoothCentral+Proximity.swift`).
    nonisolated let proximityFan = HoldingEventFanOut<ProximityReport>()
    /// What `willRestoreState` handed back at this launch, if anything (`restored`).
    nonisolated let restoredFan = LatestValueFanOut<RestoredState?>(nil)
    private let clock: any Clock<Duration>
    private let bridge: CentralBridge
    /// Internal for the proximity extension (`BluetoothCentral+Proximity.swift`); used only on the central's queue.
    let manager: CBCentralManager
    private var links: [UUID: LinkRecord] = [:]
    /// Links closed by `disconnect` that stay up for `BluetoothTiming.disconnectGrace`, so the camera sees the notification
    /// switches go off.
    private var closing: [UUID: Closing] = [:]
    private var nextToken: UInt64 = 0
    /// Peripherals this app cancelled the connection (or pending connect) of, until Core Bluetooth's disconnect without an
    /// error that answers the cancel arrives (`cancelConnection`).
    private var ownCancels: Set<UUID> = []
    /// Notification switches `disconnect()` turned off without waiting, until their answers arrive. A connect that takes the
    /// closing link over keeps them, so `setNotify` doesn't trust `isNotifying` while an off is in flight.
    private var pendingOffs: [UUID: Set<CameraControlCharacteristic>] = [:]
    /// What the connect's scan found.
    private var scanFound: CBPeripheral?
    /// Peripherals the connect under way has found or is opening; emptied when `connect` returns.
    private var connecting: Set<UUID> = []
    /// Peripherals iOS handed back in `willRestoreState` (the bridge sets their delegate there, as Apple asks). Held so they
    /// stay alive; the proximity scan needs none (the 5 Nov relaunch handed back none).
    private var restoredPeripherals: [UUID: CBPeripheral] = [:]
    /// The app wants the proximity scan: it starts when Bluetooth is on and the connect's scan isn't running.
    var proximityWanted = false
    /// The proximity scan is running (this central's, or the one iOS handed back): its discoveries are reports.
    var proximityScanning = false
    /// iOS handed back the proximity scan and Bluetooth hasn't reported `poweredOn` since: that report keeps it rather than
    /// starting a new one.
    var restoredProximityScan = false

    init(clock: any Clock<Duration> = ContinuousClock()) {
        let queue = DispatchSerialQueue(label: "net.shamil.shutter-bridge.central", qos: .userInitiated)
        let (signals, sink) = AsyncStream.makeStream(of: CentralSignal.self, bufferingPolicy: .unbounded)
        let bridge = CentralBridge(sink)
        self.queue = queue
        self.clock = clock
        self.bridge = bridge
        broker = GATTCallBroker(clock: clock)
        power = LatestValueFanOut(.unknown)
        // No system power alert: the central may be made at launch, in the background; the app says when Bluetooth is off.
        manager = CBCentralManager(delegate: bridge, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
        // The stream ends when the bridge (held by this actor) goes, so the task ends with the central.
        Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                await self.handle(signal)
            }
        }
    }

    // MARK: GATTConnector

    /// Finds the camera and connects to it, then discovers service 8000CC00 and its characteristics (15 s each).
    ///
    /// 1. Waits for Bluetooth to settle when it is `unknown` or `resetting` (30 s, or as long as the permission prompt is up).
    /// 2. `retrievePeripherals(withIdentifiers:)` with `known`: 8 s to connect, or 20 s when iOS lists it as connected to the
    ///    system.
    /// 3. `retrieveConnectedPeripherals(withServices: [8000CC00])`: 20 s.
    /// 4. A 10 s scan for Sony's company ID and a camera's name, then 20 s to connect.
    ///
    /// A connect that runs out of time is cancelled and the next route is tried. Throws `.bluetoothOff`, `.unauthorised`,
    /// `.cancelled` (the calling task was cancelled), `.notPaired` (Core Bluetooth said the pairing is gone), `.timedOut`
    /// (not found, or no answer to discovery), or `.serviceMissing` (no 8000CC00).
    public func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink {
        defer { connecting.removeAll() }
        try await waitForPower()
        let service = CBUUID(nsuuid: SonyService.cameraControl.uuid)
        let stored = known.map { manager.retrievePeripherals(withIdentifiers: [$0.uuid]) } ?? []
        let system = manager.retrieveConnectedPeripherals(withServices: [service])
        var byID: [UUID: CBPeripheral] = [:]
        for peripheral in stored + system { byID[peripheral.identifier] = peripheral }
        // This app's own links (one still closing, say) are listed as connected to the system too; they aren't another app's.
        let heldByAnotherApp = Set(system.map(\.identifier)).subtracting(links.keys).subtracting(closing.keys)

        let attempts = BluetoothConnectPlan.attempts(storedIdentifier: stored.map { candidate($0) },
                                                     connectedToSystem: system.map { candidate($0) })
        for attempt in attempts {
            guard let peripheral = byID[attempt.peripheral] else { continue }
            // A reset during the previous route fails it with `.linkDropped`; wait for the power before the next request,
            // as Core Bluetooth ignores (and never answers) one made while it isn't on.
            try await waitForPower()
            if let link = try await open(peripheral, timeout: attempt.timeout,
                                         anotherAppHoldsLink: heldByAnotherApp.contains(peripheral.identifier)) {
                return link
            }
        }
        try await waitForPower()
        let found = try await scanForCamera()
        try await waitForPower()
        if let link = try await open(found, timeout: BluetoothTiming.connect, anotherAppHoldsLink: false) {
            return link
        }
        throw .timedOut
    }

    // MARK: Calls from a link

    func read(_ characteristic: CameraControlCharacteristic, timeout: Duration?,
              on link: CoreBluetoothGATTLink) async throws(GATTFailure) -> Data {
        let (peripheral, target) = try resolve(characteristic, on: link)
        let outcome = await broker.call(.read(peripheral.identifier, characteristic), timeout: timeout) {
            peripheral.readValue(for: target)
        }
        switch outcome {
        case .value(let data): return data
        case .failed(let failure): throw failure
        case .done, .notifying: return Data()
        }
    }

    func write(_ write: CameraControlWrite, timeout: Duration, on link: CoreBluetoothGATTLink) async throws(GATTFailure) {
        let (peripheral, target) = try resolve(write.characteristic, on: link)
        let outcome = await broker.call(.write(peripheral.identifier, write.characteristic), timeout: timeout) {
            peripheral.writeValue(write.value, for: target, type: .withResponse)
        }
        if case .failed(let failure) = outcome { throw failure }
    }

    /// Returns at once when iOS already has the switch in the asked state (Core Bluetooth sends nothing then), unless an off
    /// sent by `disconnect()` on a link this one took over is still in flight, as `isNotifying` can still read true then. An
    /// off waits for that off's answer instead of sending another; an on is sent and waits for its own answer, the off's
    /// coming first and being passed over (that Core Bluetooth sends an on queued behind an off is `unverified`). An answer that
    /// leaves the switch unchanged is `.other(0)`, as Core Bluetooth's "unknown" is: with another app's link, iOS shares one
    /// set of switches between the apps (backlog section 7).
    func setNotify(_ on: Bool, _ characteristic: CameraControlCharacteristic, timeout: Duration,
                   on link: CoreBluetoothGATTLink) async throws(GATTFailure) {
        let (peripheral, target) = try resolve(characteristic, on: link)
        let id = peripheral.identifier
        let offPending = pendingOffs[id]?.contains(characteristic) ?? false
        if target.isNotifying == on, !offPending { return }
        // An off already in flight answers this off: stop passing its answer over, and send nothing.
        let alreadySent = offPending && !on
        if alreadySent {
            pendingOffs[id]?.remove(characteristic)
            if pendingOffs[id]?.isEmpty == true { pendingOffs[id] = nil }
        }
        let outcome = await broker.call(.notify(id, characteristic), timeout: timeout) {
            if !alreadySent { peripheral.setNotifyValue(on, for: target) }
        }
        switch outcome {
        case .notifying(let now): if now != on { throw .other(0) }
        case .failed(let failure): throw failure
        case .done, .value: return
        }
    }

    /// Closes a link: its calls end with `.cancelled`, its state stream says `.dropped(.cancelled)`, and notifications still
    /// on are turned off without waiting for the answers; the connection itself is cancelled `BluetoothTiming.disconnectGrace`
    /// later, so those writes reach the camera first (the spike's `disconnect`), or at once when none was on. Safe to call
    /// twice and after a drop.
    func disconnect(_ link: CoreBluetoothGATTLink) {
        let id = link.peripheral.uuid
        guard let record = links[id], record.link === link else { return }
        links[id] = nil
        broker.fail(.cancelled) { $0.peripheral == id }
        link.end(.cancelled)
        let peripheral = record.peripheral
        var turnedOff = false
        if peripheral.state == .connected {
            for (code, characteristic) in record.characteristics where characteristic.isNotifying {
                peripheral.setNotifyValue(false, for: characteristic)
                pendingOffs[id, default: []].insert(code)
                turnedOff = true
            }
        }
        guard turnedOff else {
            cancelConnection(peripheral)
            return
        }
        nextToken += 1
        let token = nextToken
        closing[id] = Closing(token: token, peripheral: peripheral)
        let clock = clock
        Task { [weak self] in
            try? await clock.sleep(for: BluetoothTiming.disconnectGrace)
            await self?.finishClosing(id, token: token)
        }
    }

    // MARK: Private

    /// Every `cancelPeripheralConnection` goes through here. Core Bluetooth answers a cancel of a pending or live connection
    /// with a disconnect with no error; that one belongs to this cancel, so it is passed over rather than taken for a drop
    /// under the next connect to the same camera (the pairing check's `disconnect()` followed at once by the hand-off's
    /// connect; the scan finding the peripheral the stored identifier just failed to reach). Every caller has already
    /// removed the link's record. A peripheral that is already disconnected gets no callback, so it isn't recorded.
    private func cancelConnection(_ peripheral: CBPeripheral) {
        if peripheral.state != .disconnected { ownCancels.insert(peripheral.identifier) }
        manager.cancelPeripheralConnection(peripheral)
    }

    /// Whether this app is connecting to, connected to, or disconnecting from the peripheral: the proximity scan's reports
    /// leave these out (`BluetoothCentral+Proximity.swift`).
    func isOwnConnection(_ id: UUID) -> Bool {
        connecting.contains(id) || links[id] != nil || closing[id] != nil || ownCancels.contains(id)
    }

    private func finishClosing(_ id: UUID, token: UInt64) {
        // A connect to the same camera since then took the link over (`open` removes the entry).
        guard let entry = closing[id], entry.token == token else { return }
        closing[id] = nil
        cancelConnection(entry.peripheral)
    }

    private func candidate(_ peripheral: CBPeripheral) -> BluetoothConnectPlan.Candidate {
        BluetoothConnectPlan.Candidate(id: peripheral.identifier, name: peripheral.name)
    }

    private func waitForPower() async throws(GATTFailure) {
        let now = BluetoothPower(manager.state)
        if now == .poweredOn { return }
        if let failure = now.failure { throw failure }
        let limit = BluetoothTiming.powerWait(authorisation: .current)
        let outcome = await broker.call(.power, timeout: limit) {}
        if case .failed(let failure) = outcome { throw failure }
    }

    /// Connects to one peripheral and discovers 8000CC00. Nil when the connect ran out of time or failed for a reason the
    /// next route may not share; throws for a cancellation, Bluetooth going, a pairing that is gone, or a failed discovery.
    private func open(
        _ peripheral: CBPeripheral, timeout: Duration, anotherAppHoldsLink: Bool
    ) async throws(GATTFailure) -> CoreBluetoothGATTLink? {
        let id = peripheral.identifier
        connecting.insert(id)
        // Only a connection that is still up (this app's closing link) keeps valid services and characteristics: after a
        // disconnect Apple documents them as invalid, even when the same `CBPeripheral` still lists them.
        let wasConnected = peripheral.state == .connected
        closing[id] = nil
        if !wasConnected { pendingOffs[id] = nil }
        if let old = links.removeValue(forKey: id) {
            broker.fail(.cancelled) { $0.peripheral == id }
            old.link.end(.cancelled)
        }
        peripheral.delegate = bridge
        if !wasConnected {
            let outcome = await broker.call(.connect(id), timeout: timeout) {
                manager.connect(peripheral, options: nil)
            }
            switch outcome {
            case .done:
                break
            case .failed(.timedOut):
                // A retrieved peripheral that isn't in range never connects and never fails: give up, try the next route.
                cancelConnection(peripheral)
                return nil
            case .failed(.cancelled):
                cancelConnection(peripheral)
                throw .cancelled
            case .failed(let failure) where [.bluetoothOff, .unauthorised, .notPaired].contains(failure):
                throw failure
            default:
                // Refused (`didFailToConnect`), or dropped while connecting: Core Bluetooth has ended the attempt itself.
                return nil
            }
        }
        do throws(GATTFailure) {
            let characteristics = try await discover(peripheral, reuseCached: wasConnected)
            let link = CoreBluetoothGATTLink(central: self, peripheral: PeripheralID(id), anotherAppHoldsLink: anotherAppHoldsLink)
            links[id] = LinkRecord(link: link, peripheral: peripheral, characteristics: characteristics)
            return link
        } catch {
            cancelConnection(peripheral)
            throw error
        }
    }

    /// Service 8000CC00 and all its characteristics, as the spike discovered them (all characteristics of the service; the
    /// spike listed every service, here only 8000CC00 is asked for, which is standard Core Bluetooth and `unverified` on the
    /// camera). A link that was still up when `open` began (closing) keeps what it discovered (`reuseCached`); after a
    /// disconnect, discovery always runs again.
    private func discover(
        _ peripheral: CBPeripheral, reuseCached: Bool
    ) async throws(GATTFailure) -> [CameraControlCharacteristic: CBCharacteristic] {
        let id = peripheral.identifier
        if reuseCached, let service = cameraControl(of: peripheral), let known = service.characteristics, !known.isEmpty {
            let table = characteristicTable(known)
            if !table.isEmpty { return table }
        }
        let serviceUUID = CBUUID(nsuuid: SonyService.cameraControl.uuid)
        let services = await broker.call(.services(id), timeout: BluetoothTiming.discovery) {
            peripheral.discoverServices([serviceUUID])
        }
        if case .failed(let failure) = services { throw failure }
        guard let service = cameraControl(of: peripheral) else { throw .serviceMissing }
        let found = await broker.call(.characteristics(id), timeout: BluetoothTiming.discovery) {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if case .failed(let failure) = found { throw failure }
        let table = characteristicTable(service.characteristics ?? [])
        guard !table.isEmpty else { throw .serviceMissing }
        return table
    }

    private func cameraControl(of peripheral: CBPeripheral) -> CBService? {
        peripheral.services?.first { CentralBridge.isCameraControl($0.uuid) }
    }

    private func characteristicTable(_ list: [CBCharacteristic]) -> [CameraControlCharacteristic: CBCharacteristic] {
        var table: [CameraControlCharacteristic: CBCharacteristic] = [:]
        for characteristic in list {
            if let code = CentralBridge.code(of: characteristic), table[code] == nil { table[code] = characteristic }
        }
        return table
    }

    private func scanForCamera() async throws(GATTFailure) -> CBPeripheral {
        scanFound = nil
        // Core Bluetooth runs one scan per central: this one replaces the proximity scan, which starts again afterwards if it
        // is still wanted (a restored scan the app never asked for isn't: the app is in front by now, and has said).
        proximityScanning = false
        restoredProximityScan = false
        let outcome = await broker.call(.scan, timeout: BluetoothTiming.scan) {
            manager.scanForPeripherals(withServices: nil, options: nil)
        }
        manager.stopScan()
        if proximityWanted, manager.state == .poweredOn { issueProximityScan() }
        let found = scanFound
        scanFound = nil
        if let found { connecting.insert(found.identifier) }
        switch outcome {
        case .failed(let failure): throw failure
        case .done, .value, .notifying:
            guard let found else { throw .timedOut }
            return found
        }
    }

    /// The peripheral and characteristic a link's call is for. Throws why the link ended when it has (`.cancelled` after
    /// `disconnect`, the drop's reason otherwise), and `.serviceMissing` when 8000CC00 lacks the characteristic.
    private func resolve(
        _ characteristic: CameraControlCharacteristic, on link: CoreBluetoothGATTLink
    ) throws(GATTFailure) -> (CBPeripheral, CBCharacteristic) {
        guard let record = links[link.peripheral.uuid], record.link === link else {
            throw link.endReason ?? .linkDropped
        }
        guard let target = record.characteristics[characteristic] else { throw .serviceMissing }
        return (record.peripheral, target)
    }

    private func outcome(_ error: CBErrorInfo?, reading characteristic: CameraControlCharacteristic?) -> GATTCallOutcome {
        guard let error else { return .done }
        return .failed(GATTFailure.classify(domain: error.domain, code: error.code, reading: characteristic))
    }

    private func handle(_ signal: CentralSignal) {
        switch signal {
        case .power(let state):
            powerChanged(state)
        case .restored(let peripherals, let scanServices):
            // The bridge has already made itself their delegate (`willRestoreState`).
            for box in peripherals { restoredPeripherals[box.object.identifier] = box.object }
            proximityRestored(RestoredState(scanServices: scanServices,
                                            peripherals: peripherals.map { PeripheralID($0.object.identifier) }))
        case .discovered(let box, let manufacturerData, let name, let rssi):
            guard broker.isWaiting(.scan) else {
                proximityDiscovered(box.object.identifier, manufacturerData: manufacturerData, name: name, rssi: rssi)
                return
            }
            guard scanFound == nil,
                  BluetoothConnectPlan.scanMatches(manufacturerData: manufacturerData, name: name) else { return }
            scanFound = box.object
            manager.stopScan()
            broker.answer(.scan, .done)
        case .connectionEvent(let id, let name, let peerConnected):
            proximityConnectionEvent(id, name: name, peerConnected: peerConnected)
        case .connected(let id):
            broker.answer(.connect(id), .done)
        case .failedToConnect(let id, let error):
            var failure = error.map { GATTFailure.classify(domain: $0.domain, code: $0.code, reading: nil) } ?? .linkDropped
            // Core Bluetooth ended the attempt itself: its "connection timeout" and "operation cancelled" mustn't read as the
            // broker's own time limit or the caller's cancellation, which `open` acts on as its own.
            if failure == .timedOut || failure == .cancelled { failure = .linkDropped }
            broker.answer(.connect(id), .failed(failure))
        case .disconnected(let id, let error):
            // The connection is gone, so no answer to an off is still to come.
            pendingOffs[id] = nil
            // The answer to this app's own cancel, not a drop (`cancelConnection`), unless a link has been made since: the
            // connection is gone either way, so that link has dropped.
            let ownCancel = error == nil && ownCancels.remove(id) != nil
            if ownCancel, links[id] == nil { return }
            peripheralDropped(id, reason: GATTFailure.dropReason(domain: error?.domain, code: error?.code))
        case .servicesDiscovered(let id, let error):
            broker.answer(.services(id), outcome(error, reading: nil))
        case .characteristicsDiscovered(let id, let cameraControl, let error):
            guard cameraControl else { return }
            broker.answer(.characteristics(id), outcome(error, reading: nil))
        case .value(let id, let characteristic, let value, let isNotifying, let error):
            let key = GATTWaitKey.read(id, characteristic)
            switch GATTValueRoute.route(readWaiting: broker.isWaiting(key), characteristic: characteristic,
                                        isNotifying: isNotifying, hasError: error != nil) {
            case .answerRead:
                broker.answer(key, error == nil ? .value(value ?? Data()) : outcome(error, reading: characteristic))
            case .notification:
                if let value, let record = links[id] { record.link.notify(characteristic, value) }
            case .ignore:
                break
            }
        case .wrote(let id, let characteristic, let error):
            broker.answer(.write(id, characteristic), outcome(error, reading: characteristic))
        case .notificationState(let id, let characteristic, let isNotifying, let error):
            // Core Bluetooth answers one characteristic's requests in order, so the first answer after `disconnect()`'s
            // off is the off's, not the answer to a `setNotify` made since by a link that took the connection over.
            if pendingOffs[id]?.remove(characteristic) != nil {
                if pendingOffs[id]?.isEmpty == true { pendingOffs[id] = nil }
                return
            }
            let answer = error == nil ? GATTCallOutcome.notifying(isNotifying) : outcome(error, reading: characteristic)
            broker.answer(.notify(id, characteristic), answer)
        case .cameraControlInvalidated(let id):
            // The characteristics the link holds are no longer valid. Close it; the next connect discovers again.
            guard let record = links[id] else { return }
            peripheralDropped(id, reason: .serviceMissing)
            cancelConnection(record.peripheral)
        }
    }

    private func powerChanged(_ state: BluetoothPower) {
        power.send(state)
        switch state {
        case .poweredOn:
            broker.answerAll(.power, .done)
            proximityPoweredOn()
        case .unknown:
            break
        case .resetting:
            // Every link has gone; a wait for the power goes on until Bluetooth is back.
            dropEverything(.linkDropped)
            proximityPoweredDown()
        case .poweredOff, .unauthorised, .unsupported:
            broker.answerAll(.power, .failed(state.dropReason))
            dropEverything(state.dropReason)
            proximityPoweredDown()
        }
    }

    private func dropEverything(_ reason: GATTFailure) {
        broker.fail(reason) { $0 != .power }
        scanFound = nil
        closing = [:]
        ownCancels = []
        pendingOffs = [:]
        let all = links
        links = [:]
        for record in all.values { record.link.end(reason) }
    }

    private func peripheralDropped(_ id: UUID, reason: GATTFailure) {
        broker.fail(reason) { $0.peripheral == id }
        if closing[id] != nil { closing[id] = nil }
        guard let record = links.removeValue(forKey: id) else { return }
        record.link.end(reason)
    }
}
#endif
