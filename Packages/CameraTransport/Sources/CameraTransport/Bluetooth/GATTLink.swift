// The two protocols the Bluetooth sequencers are written against. The Core Bluetooth adapter (W10) implements them;
// tests use scripted fakes.

import BLEKit
import Foundation

/// A camera's Bluetooth identity: the identifier iOS gave its peripheral. It is a device identifier, so it prints
/// redacted and is never logged; the catalogue stores the `uuid` (`Camera.bluetoothPeripheralID`).
public struct PeripheralID: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let uuid: UUID

    public init(_ uuid: UUID) { self.uuid = uuid }

    public var description: String { "peripheral (identifier redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description], displayStyle: .struct) }
}

/// What a link reports about itself on `GATTLink.state`.
public enum GATTLinkState: Sendable, Equatable {
    case connected
    /// The link has gone, and why. Nothing follows.
    case dropped(GATTFailure)
}

/// One connected camera, services already discovered: the reads, writes and notifications of service 8000CC00 that the
/// hand-off needs. The Core Bluetooth adapter owns discovery, timeouts and the mapping of framework errors through
/// `GATTFailure.classify`; the sequencers own the order and the waiting.
///
/// Contract the sequencers rely on:
/// - Every call throws only `GATTFailure`, and honours cancellation of the calling task by throwing `.cancelled` (the
///   pairing read waits for a person, and *Cancel* in the app cancels the task).
/// - A call that is given a timeout throws `.timedOut` when it passes. `read` with a nil timeout never times out.
/// - `notifications` and `state` each return a new, independent stream on every access. A stream sees what arrives after
///   it was obtained and nothing from before, so a sequencer takes both before it subscribes to anything. `state` starts
///   with the current state.
/// - Values from CC06, CC07 and CC0C are secrets: the link never logs them.
public protocol GATTLink: Sendable {
    var peripheral: PeripheralID { get }

    /// Reads a characteristic. A nil `timeout` waits for the person: the first protected read of an unpaired camera makes
    /// iOS ask for a pairing and the camera ask for a confirmation (measured: 12.3 s, 4 Nov 13:06).
    func read(_ characteristic: CameraControlCharacteristic, timeout: Duration?) async throws(GATTFailure) -> Data

    /// Writes with response. Returns when the camera has acknowledged it (measured for CC08: 55 to 88 ms).
    func write(_ write: CameraControlWrite, timeout: Duration) async throws(GATTFailure)

    /// Turns notifications for a characteristic on or off, and returns when iOS has confirmed the new state.
    func setNotify(_ on: Bool, _ characteristic: CameraControlCharacteristic, timeout: Duration) async throws(GATTFailure)

    /// Every notification, as the characteristic and its value.
    var notifications: AsyncStream<(CameraControlCharacteristic, Data)> { get }

    var state: AsyncStream<GATTLinkState> { get }

    /// iOS lists another app's link to the same camera (Creators' App). iOS then shares one link and one set of
    /// notification switches, so turning a notification off may come back as Core Bluetooth's "unknown" error, which is
    /// harmless (backlog section 7).
    var anotherAppHoldsLink: Bool { get }

    /// Closes the link. Never throws; safe to call twice and after a drop.
    func disconnect() async
}

/// A link that can read its own signal strength, for the bench log only (W20). `CoreBluetoothGATTLink` reads it with Core
/// Bluetooth's `readRSSI()`, which asks the phone's radio and sends nothing to the camera's characteristics; test links
/// don't conform, so nothing is read in tests.
public protocol GATTSignalReading: Sendable {
    /// The link's RSSI in dBm now; nil when the link has ended, iOS gave none (127), the read failed or `timeout` passed.
    func readSignalStrength(timeout: Duration) async -> Int?
}

/// How long the trace's RSSI read may take. A choice, `unverified`: Core Bluetooth answers within a connection interval or
/// two; the read only feeds the log.
public enum GATTSignalTiming {
    public static let read: Duration = .seconds(5)
}

/// Finds the camera and connects to it: by the stored identifier first, then a scan (W10). Throws `.timedOut` when the
/// camera isn't found in time, `.bluetoothOff`, `.unauthorised`, or `.serviceMissing`.
public protocol GATTConnector: Sendable {
    func connect(known: PeripheralID?) async throws(GATTFailure) -> any GATTLink
}
