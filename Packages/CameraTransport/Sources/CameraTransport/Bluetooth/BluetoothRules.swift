// The rules of the Core Bluetooth central (W10) that need no Core Bluetooth: the launch rule, the timings, the order in which
// the camera is looked for, the scan's match, and the mapping of the framework's states and errors. `BluetoothCentral`
// (Apple-only, `BluetoothCentral.swift`) applies them; keeping them here means they are tested on Linux.
//
// Sources: `Spike/Sources/Bluetooth/SonyWiFiHandover.swift` (`doConnect` 318-381, `attemptConnect` 383-420, `doDiscover`
// 432-492, `poweredOnCentral` 1745-1759, `disconnect` 1667-1718) and `ProximityWatcher.swift` (`launch` 104-120); the
// measurements are spike-findings.md, *BLE advertisement* (2 to 5 Nov 2026, α7C II firmware 2.01).

import BLEKit
import Foundation

/// The phone's Bluetooth, as the central sees it (`CBManagerState`, reduced to what the app acts on).
public enum BluetoothPower: Sendable, Equatable, CustomStringConvertible {
    /// Not known yet: just after the central was made, or while iOS is asking for the Bluetooth permission.
    case unknown
    /// The Bluetooth service restarted; every link has gone. It comes back by itself.
    case resetting
    /// No Bluetooth Low Energy here (the iOS Simulator; never an iPhone).
    case unsupported
    /// The app isn't allowed to use Bluetooth (denied, or restricted by a profile or Screen Time).
    case unauthorised
    /// Bluetooth is switched off (Settings or Control Centre).
    case poweredOff
    case poweredOn

    /// What a call made in this state fails with, or nil when it may go ahead (`poweredOn`) or should wait for the state to
    /// settle (`unknown`, `resetting`).
    ///
    /// `unsupported` maps to `bluetoothOff`: it only happens in the Simulator, and `GATTFailure` has nothing nearer.
    public var failure: GATTFailure? {
        switch self {
        case .poweredOn, .unknown, .resetting: nil
        case .unauthorised: .unauthorised
        case .poweredOff, .unsupported: .bluetoothOff
        }
    }

    /// What a live link reports when the phone's Bluetooth leaves `poweredOn` under it: iOS drops every link then.
    public var dropReason: GATTFailure {
        failure ?? .linkDropped
    }

    public var description: String {
        switch self {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorised: "not authorised"
        case .poweredOff: "off"
        case .poweredOn: "on"
        }
    }
}

/// Whether the app may use Bluetooth (`CBManager.authorization`). Reading it never prompts; making a central does.
public enum BluetoothAuthorisation: Sendable, Equatable {
    /// The person hasn't been asked. Making a central now would show the permission prompt.
    case notDetermined
    case restricted
    case denied
    case allowedAlways
}

/// When the app makes its one central at launch (plan section 0, item 2; the spike's rule, `ProximityWatcher.launch`).
public enum BluetoothLaunchRule {
    /// Make the central at launch only when the proximity reminder is on or Bluetooth is already allowed, so launching never
    /// shows the permission prompt, and state restoration still finds the central it hands the scan back to.
    ///
    /// The reminders' setting can't be read before the first unlock after a restart, but the authorisation can, so an
    /// allowed app makes the central either way. With reminders on and the permission later withdrawn in Settings, making
    /// the central doesn't prompt again (iOS asks once); the central reports `unauthorised`.
    public static func createsCentralAtLaunch(remindersOn: Bool, authorisation: BluetoothAuthorisation) -> Bool {
        remindersOn || authorisation == .allowedAlways
    }
}

/// Every wait of the central itself, each with the measurement it rests on (plan section 0, item 8). The waits of the hand-off
/// and the pairing check are in `HandoffTiming`.
public enum BluetoothTiming {
    /// How long a call waits for Bluetooth to settle (`unknown` or `resetting`) before it fails with `.timedOut`. The spike's
    /// limit (`poweredOnCentral`); it settled at once in every run.
    public static let powerOn: Duration = .seconds(30)

    /// How long the connect by the stored identifier gets when iOS does *not* list the camera as connected to the system.
    /// A retrieved peripheral that isn't in range never connects and never fails, so it gets a short go before the next
    /// route. The spike's limit; measured: 0.19 to 0.57 s typically, 5.2 to 5.95 s for the first connect to a camera that had
    /// been idle, and once (3 Nov 11:53) 8 s ran out before a scan found the camera (backlog section 7).
    public static let connectKnown: Duration = .seconds(8)

    /// How long a connect gets when iOS lists the camera as connected to the system (another app's link, Creators' App), and
    /// the connect to a camera the scan has just found. The spike's default connect limit; measured: 0.00 to 0.05 s with
    /// another app's link.
    public static let connect: Duration = .seconds(20)

    /// How long the scan for the camera runs when neither the stored identifier nor a system link found it. The spike's
    /// limit (`doConnect`).
    public static let scan: Duration = .seconds(10)

    /// How long service discovery, and then characteristic discovery of service 8000CC00, each get. The spike's limits
    /// (`doDiscover`); measured: 1.05 s for every service and characteristic together.
    public static let discovery: Duration = .seconds(15)

    /// How long a link stays up after `disconnect()` has turned notifications off without waiting, so the descriptor writes
    /// reach the camera before the link closes. The spike's rule (`disconnect`); whether the camera needs it is `unverified`.
    public static let disconnectGrace: Duration = .seconds(2)

    /// How long a call waits for Bluetooth to settle, given the permission: no limit while the person hasn't answered the
    /// permission prompt (the state stays `unknown` until they do, and they may be reading it), else `powerOn`.
    public static func powerWait(authorisation: BluetoothAuthorisation) -> Duration? {
        authorisation == .notDetermined ? nil : powerOn
    }
}

/// The order in which `BluetoothCentral.connect(known:)` looks for the camera (backlog section 7; spike `doConnect`): the stored
/// identifier, then a camera iOS lists as connected to the system with service 8000CC00, then a scan.
public enum BluetoothConnectPlan {
    /// A peripheral iOS handed back, as the plan sees it.
    public struct Candidate: Sendable, Equatable {
        public let id: UUID
        /// The peripheral's name, if iOS knows one. Used only to prefer a camera; never logged.
        public let name: String?

        public init(id: UUID, name: String?) {
            self.id = id
            self.name = name
        }
    }

    /// How an attempt found the peripheral.
    public enum Route: Sendable, Equatable {
        /// `retrievePeripherals(withIdentifiers:)` with the stored identifier.
        case storedIdentifier
        /// `retrieveConnectedPeripherals(withServices: [8000CC00])`: another app's link.
        case connectedToSystem
        /// A scan for Sony's company ID and a camera's name.
        case scan
    }

    public struct Attempt: Sendable, Equatable {
        public let peripheral: UUID
        public let route: Route
        /// How long the connect gets before it is cancelled and the next route is tried.
        public let timeout: Duration

        public init(peripheral: UUID, route: Route, timeout: Duration) {
            self.peripheral = peripheral
            self.route = route
            self.timeout = timeout
        }
    }

    /// The connects to try before scanning, in order: the peripheral retrieved by the stored identifier (`connectKnown`, or
    /// `connect` when iOS also lists it as connected to the system), then the camera among those connected to the system
    /// (`connect`), unless it is the same peripheral. Empty means scan at once.
    ///
    /// - Parameters:
    ///   - storedIdentifier: what `retrievePeripherals(withIdentifiers:)` returned for the stored identifier (at most one is
    ///     asked for; the spike preferred a camera's name among several).
    ///   - connectedToSystem: what `retrieveConnectedPeripherals(withServices: [8000CC00])` returned.
    public static func attempts(storedIdentifier: [Candidate], connectedToSystem: [Candidate]) -> [Attempt] {
        var out: [Attempt] = []
        let systemIDs = Set(connectedToSystem.map(\.id))
        if let known = preferCamera(storedIdentifier) {
            let timeout = systemIDs.contains(known.id) ? BluetoothTiming.connect : BluetoothTiming.connectKnown
            out.append(Attempt(peripheral: known.id, route: .storedIdentifier, timeout: timeout))
        }
        if let system = preferCamera(connectedToSystem), !out.contains(where: { $0.peripheral == system.id }) {
            out.append(Attempt(peripheral: system.id, route: .connectedToSystem, timeout: BluetoothTiming.connect))
        }
        return out
    }

    /// The candidate named like a camera ("ILCE" or "SONY", `SonyAdvertisement.nameLooksLikeCamera`), else the first; nil
    /// for none. The spike preferred "ILCE" (`preferCamera`); the wider rule is the one the scan uses.
    public static func preferCamera(_ candidates: [Candidate]) -> Candidate? {
        candidates.first { SonyAdvertisement.nameLooksLikeCamera($0.name) } ?? candidates.first
    }

    /// Whether a peripheral the scan reported is the camera: Sony's company ID at the front of its manufacturer data and a
    /// camera's name (`SonyAdvertisement.isSony && nameLooksLikeCamera`). The spike matched "ILCE" only; the α7C II calls
    /// itself "ILCE-7CM2" (measured). The manufacturer data is never logged.
    public static func scanMatches(manufacturerData: Data?, name: String?) -> Bool {
        guard let manufacturerData, let advertisement = try? SonyAdvertisement(manufacturerData: manufacturerData) else {
            return false
        }
        return advertisement.isSony && SonyAdvertisement.nameLooksLikeCamera(name)
    }
}

/// The error domains Core Bluetooth reports in, by name, so the mapping is tested without the framework.
public enum CoreBluetoothErrorDomain {
    /// `CBATTErrorDomain`: the camera answered with an ATT error.
    public static let att = "CBATTErrorDomain"
    /// `CBErrorDomain`: Core Bluetooth's own errors.
    public static let coreBluetooth = "CBErrorDomain"
}

extension GATTFailure {
    /// Maps an error Core Bluetooth gave, by its domain and code, through `classify(att:coreBluetooth:reading:)`. A domain
    /// that is neither (`CBInternalErrorDomain`, seen once when the link dropped by itself 11.2 s after a join, 5 Nov 02:21)
    /// is `other(code)`.
    public static func classify(domain: String, code: Int, reading characteristic: CameraControlCharacteristic?) -> GATTFailure {
        switch domain {
        case CoreBluetoothErrorDomain.att: classify(att: code, coreBluetooth: nil, reading: characteristic)
        case CoreBluetoothErrorDomain.coreBluetooth: classify(att: nil, coreBluetooth: code, reading: characteristic)
        default: .other(code)
        }
    }

    /// What a link reports when the camera or iOS closed it without being asked (`didDisconnectPeripheral`), given the error
    /// Core Bluetooth passed, if any: `notPaired` when the error says the pairing is gone, else `linkDropped`. The camera
    /// drops an unpaired phone 0.55 s after refusing its write (measured, 4 Nov), with *peripheral disconnected*, which is
    /// `linkDropped`: the refusal itself has already said `notPaired`.
    public static func dropReason(domain: String?, code: Int?) -> GATTFailure {
        guard let domain, let code else { return .linkDropped }
        return classify(domain: domain, code: code, reading: nil) == .notPaired ? .notPaired : .linkDropped
    }
}

/// Where a value Core Bluetooth delivered (`didUpdateValueFor`) goes. Core Bluetooth uses the same callback for a read's
/// answer and for a notification, so the link decides.
public enum GATTValueRoute: Sendable, Equatable {
    /// The answer to the read waiting on this characteristic.
    case answerRead
    /// A notification, for the link's `notifications` streams.
    case notification
    /// Neither: dropped without being looked at.
    case ignore

    /// - A read is waiting on the characteristic: the value answers it, as in the spike (a notification that comes while a
    ///   read of CC09 is outstanding answers the read; both carry CC09 entries, which the sequencer merges either way, and the
    ///   read's own answer then comes as a notification).
    /// - Else, with no error, a characteristic of 8000CC00 whose notifications are on, and not a secret one: a notification.
    ///   A late answer to a read that was cancelled or timed out on a characteristic without notifications is dropped, so a
    ///   network name or password never reaches a notification stream.
    public static func route(
        readWaiting: Bool, characteristic: CameraControlCharacteristic?, isNotifying: Bool, hasError: Bool
    ) -> GATTValueRoute {
        if readWaiting { return .answerRead }
        guard !hasError, let characteristic, isNotifying, !characteristic.isSecret else { return .ignore }
        return .notification
    }
}
