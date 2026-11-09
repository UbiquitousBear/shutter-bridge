// What can go wrong on a Bluetooth link to the camera, in the terms the sequencers act on.

import BLEKit

/// Why a GATT call (connect, read, write, subscribe) failed, reduced to what the hand-off and the pairing check decide on.
/// The Core Bluetooth adapter (W10) maps what the framework says through `classify` and adds the cases only it can see
/// (`bluetoothOff`, `unauthorised`, `serviceMissing`, `cancelled`, `timedOut`).
public enum GATTFailure: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The camera refused a protected value because this phone isn't paired with it (ATT "insufficient authentication" or
    /// "insufficient encryption"), or iOS says the pairing is gone. The camera also drops the link soon after (measured:
    /// 0.55 s after a refused write). Never retried in a loop: the person has to open the camera's Pairing screen.
    case notPaired
    /// CC06 or CC07 refused with ATT 0x9D: the camera's Wi-Fi is off (measured, 5 Nov 02:21). Not a pairing error.
    case wifiOff
    /// The link went away under the call (the camera dropped it, or iOS lost it).
    case linkDropped
    /// The call got no answer in the time it was given.
    case timedOut
    /// The camera has no service 8000CC00, or lacks a characteristic the call needs (a firmware change): the manual route
    /// is the fallback (backlog section 7).
    case serviceMissing
    /// The phone's Bluetooth is switched off.
    case bluetoothOff
    /// The app isn't allowed to use Bluetooth.
    case unauthorised
    /// The caller cancelled the call (a cancelled task), or the app closed the link on purpose.
    case cancelled
    /// Anything else, with the ATT error code if the framework gave one, else the Core Bluetooth error code. For the log
    /// only; never shown to the person.
    case other(Int)

    // MARK: ATT error codes the camera used (Bluetooth Core Specification, Vol 3, Part F, 3.4.1.1)

    /// ATT 0x05, "insufficient authentication": measured on the unpaired α7C II, for the second CC09 read, the CCAB read and
    /// the CC08 write (4 Nov).
    public static let attInsufficientAuthentication = 0x05
    /// ATT 0x0F, "insufficient encryption": measured on the unpaired α7C II, for the first CC09 read (4 Nov).
    public static let attInsufficientEncryption = 0x0F
    /// ATT 0x08, "insufficient authorisation". The spike treated it as a pairing hint (`noteIfPairing`); the camera never
    /// sent it, so the mapping is `unverified`.
    public static let attInsufficientAuthorisation = 0x08
    /// ATT 0x0C, "insufficient encryption key size". A pairing hint in the spike; never seen, `unverified`.
    public static let attInsufficientKeySize = 0x0C
    /// ATT 0x9D, an application error: the camera's Wi-Fi is off, for CC06 and CC07 (measured, 5 Nov 02:21).
    public static let attWiFiOff = 0x9D

    // MARK: Core Bluetooth error codes (`CBError.Code`) the mapping uses

    static let cbNotConnected = 3
    static let cbOperationCancelled = 5
    static let cbConnectionTimeout = 6
    static let cbPeripheralDisconnected = 7
    static let cbConnectionFailed = 10
    /// `peerRemovedPairingInformation`: the camera forgot the pairing (or the person removed it there). `unverified` (not seen).
    static let cbPeerRemovedPairingInformation = 14
    /// `encryptionTimedOut`: the encryption never came up, the spike's other pairing hint. `unverified` (not seen).
    static let cbEncryptionTimedOut = 15

    /// Maps what Core Bluetooth reported to a failure.
    ///
    /// - Parameters:
    ///   - att: the code when the error is in `CBATTErrorDomain` (the ATT error the camera sent), else nil.
    ///   - coreBluetooth: the code when the error is in `CBErrorDomain`, else nil.
    ///   - reading: the characteristic the call was on, when it was a read or write of one. It decides whether ATT 0x9D means
    ///     "Wi-Fi off" (only for CC06 and CC07, where it was measured).
    ///
    /// An ATT code wins over a Core Bluetooth code when both are given. ATT 0x05 and 0x0F are measured; the other pairing
    /// codes (ATT 0x08 and 0x0C, Core Bluetooth 14 and 15) are the spike's pairing hints and are `unverified`: mapping them
    /// to `notPaired` only sends the person to the camera's Pairing screen, once. Neither argument given is `other(0)`, what
    /// Core Bluetooth calls "unknown".
    public static func classify(att: Int?, coreBluetooth: Int?, reading characteristic: CameraControlCharacteristic?) -> GATTFailure {
        if let att {
            switch att {
            case attInsufficientAuthentication, attInsufficientEncryption, attInsufficientAuthorisation, attInsufficientKeySize:
                return .notPaired
            case attWiFiOff where characteristic == .ssid || characteristic == .passphrase:
                return .wifiOff
            default:
                return .other(att)
            }
        }
        guard let coreBluetooth else { return .other(0) }
        switch coreBluetooth {
        case cbPeerRemovedPairingInformation, cbEncryptionTimedOut: return .notPaired
        case cbNotConnected, cbPeripheralDisconnected, cbConnectionFailed: return .linkDropped
        case cbConnectionTimeout: return .timedOut
        case cbOperationCancelled: return .cancelled
        default: return .other(coreBluetooth)
        }
    }

    public var description: String {
        switch self {
        case .notPaired: "not paired"
        case .wifiOff: "camera Wi-Fi off"
        case .linkDropped: "link dropped"
        case .timedOut: "timed out"
        case .serviceMissing: "service missing"
        case .bluetoothOff: "Bluetooth off"
        case .unauthorised: "Bluetooth not authorised"
        case .cancelled: "cancelled"
        case .other(let code): "other (\(code))"
        }
    }
}
