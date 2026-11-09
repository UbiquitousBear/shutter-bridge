#if canImport(CoreBluetooth) && os(iOS)
import BLEKit
import Foundation

/// One connected camera, service 8000CC00 discovered: the `GATTLink` the pairing check and the Wi-Fi hand-off run on. Made only
/// by `BluetoothCentral.connect(known:)`, which owns the Core Bluetooth objects; every call goes to the central's actor, on the
/// central's queue. Compiled only for iOS (CI's Xcode 27 job).
///
/// What it adds to the protocol's contract:
/// - Calls after the link has ended throw why it ended: `.cancelled` after `disconnect()`, or the drop's reason
///   (`.linkDropped`, `.notPaired`, `.bluetoothOff`, `.unauthorised`, `.serviceMissing`).
/// - A characteristic the camera's 8000CC00 doesn't have makes the call throw `.serviceMissing`.
/// - `anotherAppHoldsLink` is what iOS listed when the link was made: the camera was connected to the system (Creators'
///   App) before this app connected. It isn't updated afterwards.
/// - Notifications carry only characteristics of 8000CC00 whose notifications are on, and never CC06, CC07 or CC0C.
final class CoreBluetoothGATTLink: GATTLink {
    let peripheral: PeripheralID
    let anotherAppHoldsLink: Bool
    private let central: BluetoothCentral
    private let notificationFan = EventFanOut<(CameraControlCharacteristic, Data)>()
    private let stateFan = LatestValueFanOut<GATTLinkState>(.connected)

    init(central: BluetoothCentral, peripheral: PeripheralID, anotherAppHoldsLink: Bool) {
        self.central = central
        self.peripheral = peripheral
        self.anotherAppHoldsLink = anotherAppHoldsLink
    }

    var notifications: AsyncStream<(CameraControlCharacteristic, Data)> { notificationFan.subscribe() }

    var state: AsyncStream<GATTLinkState> { stateFan.subscribe() }

    func read(_ characteristic: CameraControlCharacteristic, timeout: Duration?) async throws(GATTFailure) -> Data {
        try await central.read(characteristic, timeout: timeout, on: self)
    }

    func write(_ write: CameraControlWrite, timeout: Duration) async throws(GATTFailure) {
        try await central.write(write, timeout: timeout, on: self)
    }

    func setNotify(_ on: Bool, _ characteristic: CameraControlCharacteristic, timeout: Duration) async throws(GATTFailure) {
        try await central.setNotify(on, characteristic, timeout: timeout, on: self)
    }

    func disconnect() async {
        await central.disconnect(self)
    }

    // MARK: From the central

    /// Why the link ended, or nil while it is up.
    var endReason: GATTFailure? {
        if case .dropped(let reason) = stateFan.current { return reason }
        return nil
    }

    /// Passes a notification on to every `notifications` stream. Called by the central only.
    func notify(_ characteristic: CameraControlCharacteristic, _ value: Data) {
        notificationFan.send((characteristic, value))
    }

    /// Ends the link: the state streams say `.dropped(reason)` and then end, and so do the notification streams. Called by
    /// the central only; a second call does nothing.
    func end(_ reason: GATTFailure) {
        stateFan.send(.dropped(reason))
        stateFan.finish()
        notificationFan.finish()
    }
}
#endif
