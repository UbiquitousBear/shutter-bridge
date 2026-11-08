// The camera's Wi-Fi network as read over Bluetooth: CC06 (name) and CC07 (password), and whether CC0C (BSSID) was there.
//
// Measured layout (spike builds 10 to 14; spike-findings.md, *BLE advertisement*): CC06 is 24 bytes, a 3-byte prefix and a
// 21-character name beginning `DIRECT-`; CC07 is 11 bytes, the same 3-byte prefix and an 8-character printable password.
// What the three prefix bytes hold was not recorded, so they are skipped without being read (unverified). The spike also
// dropped trailing zero bytes before decoding; no measured value had any.
//
// THE VALUES ARE SECRETS. They are never logged, displayed, stored, put on the pasteboard or put in a fixture or test
// output. `SonyWiFiCredentials` keeps them in memory only, long enough to join, and everything that prints it (description,
// debugDescription, the custom mirror, the playground description, and the errors) shows lengths and yes/no only. It isn't
// Codable, on purpose: a value you can encode is a value you can write to disk by accident.

import Foundation

/// Why CC06 or CC07 didn't give a usable value. Carries lengths only, never bytes or text.
public enum SonyNetworkDetailsError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Field: Sendable, Equatable {
        case ssid, passphrase
    }

    /// No text after the 3-byte prefix: the value is 3 bytes or fewer, or only zero bytes follow the prefix.
    case noText(Field, byteCount: Int)
    case notUTF8(Field)
    /// A zero byte inside the text (a zero byte at its end is padding and is dropped).
    case embeddedNUL(Field)
    /// The network name isn't 1 to 32 bytes of UTF-8 (the 802.11 limit; the spike only refused an empty name).
    case ssidLength(byteCount: Int)
    /// The password isn't 8 to 63 printable ASCII characters.
    case invalidPassphrase(characterCount: Int)

    public var description: String {
        func name(_ field: Field) -> String { field == .ssid ? "CC06 (network name)" : "CC07 (password)" }
        switch self {
        case .noText(let field, let byteCount): return "\(name(field)) is \(byteCount) B, with no text after the 3-byte prefix"
        case .notUTF8(let field): return "\(name(field)) isn't UTF-8 after the 3-byte prefix"
        case .embeddedNUL(let field): return "\(name(field)) has a zero byte inside its text"
        case .ssidLength(let byteCount): return "network name is \(byteCount) bytes, not 1 to 32"
        case .invalidPassphrase(let count): return "password is \(count) characters, or not printable ASCII; needs 8 to 63 printable ASCII"
        }
    }
}

public struct SonyWiFiCredentials: Equatable, Sendable {
    public let ssid: String
    public let passphrase: String
    /// CC0C had a value (not empty). Its bytes aren't kept. Measured: present on the α7C II; whether it is the BSSID,
    /// and its layout, are unverified.
    public let bssidPresent: Bool

    /// The length of the 3-byte prefix before the text in CC06 and CC07 (measured: 24 B and 11 B values; unverified: what it holds).
    public static let prefixLength = 3

    /// Builds credentials from text already in hand, with the checks `decode` makes: a name of 1 to 32 bytes, with no zero
    /// byte, and a password that `isValidPassphrase` accepts.
    public init(ssid: String, passphrase: String, bssidPresent: Bool = false) throws {
        let ssidBytes = ssid.utf8.count
        guard (1 ... 32).contains(ssidBytes) else { throw SonyNetworkDetailsError.ssidLength(byteCount: ssidBytes) }
        guard !ssid.utf8.contains(0) else { throw SonyNetworkDetailsError.embeddedNUL(.ssid) }
        guard Self.isValidPassphrase(passphrase) else {
            throw SonyNetworkDetailsError.invalidPassphrase(characterCount: passphrase.unicodeScalars.count)
        }
        self.ssid = ssid
        self.passphrase = passphrase
        self.bssidPresent = bssidPresent
    }

    /// Decodes the values of CC06, CC07 and (optionally) CC0C: the text after the 3-byte prefix, trailing zero bytes dropped,
    /// as UTF-8. Throws a `SonyNetworkDetailsError` (lengths only) for a value with no text, bad UTF-8, a zero byte inside,
    /// a name outside 1 to 32 bytes or a password that isn't 8 to 63 printable ASCII characters. CC06 is checked first.
    public static func decode(ssidValue: Data, passphraseValue: Data, bssidValue: Data? = nil) throws -> SonyWiFiCredentials {
        let ssid = try text(in: ssidValue, field: .ssid)
        let passphrase = try text(in: passphraseValue, field: .passphrase)
        return try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase, bssidPresent: !(bssidValue?.isEmpty ?? true))
    }

    /// WPA2 passphrase rule, the spike's: 8 to 63 printable ASCII characters (0x20 to 0x7E, spaces included).
    public static func isValidPassphrase(_ text: String) -> Bool {
        (8 ... 63).contains(text.unicodeScalars.count)
            && text.unicodeScalars.allSatisfy { (0x20 ... 0x7E).contains($0.value) }
    }

    /// The text after the prefix. Internal: only `decode` hands secrets out of raw bytes.
    static func text(in value: Data, field: SonyNetworkDetailsError.Field) throws -> String {
        let bytes = [UInt8](value)
        guard bytes.count > prefixLength else { throw SonyNetworkDetailsError.noText(field, byteCount: bytes.count) }
        var payload = Array(bytes[prefixLength...])
        while payload.last == 0 { payload.removeLast() }
        guard !payload.isEmpty else { throw SonyNetworkDetailsError.noText(field, byteCount: bytes.count) }
        guard !payload.contains(0) else { throw SonyNetworkDetailsError.embeddedNUL(field) }
        guard let text = String(validating: payload, as: UTF8.self) else { throw SonyNetworkDetailsError.notUTF8(field) }
        return text
    }
}

// MARK: - Redaction

extension SonyWiFiCredentials: CustomStringConvertible {
    /// Lengths and yes/no only, the spike's text: "SSID 21 chars, DIRECT- prefix yes · passphrase 8 chars, 8–63 printable
    /// ASCII yes · BSSID present".
    public var description: String {
        "SSID \(ssid.count) chars, DIRECT- prefix \(ssid.hasPrefix("DIRECT-") ? "yes" : "no")"
            + " · passphrase \(passphrase.count) chars, 8–63 printable ASCII \(Self.isValidPassphrase(passphrase) ? "yes" : "no")"
            + " · BSSID \(bssidPresent ? "present" : "absent")"
    }
}

/// `debugPrint`, `dump`, `po` and a failing test's messages show the redacted text too. The debugger's variables view
/// (`frame variable`, Xcode) shows the stored properties, so keep debugger sessions with a real camera's details out of
/// shared logs and screenshots.
extension SonyWiFiCredentials: CustomDebugStringConvertible, CustomReflectable, CustomPlaygroundDisplayConvertible {
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description], displayStyle: .struct) }
    public var playgroundDescription: Any { description }
}
