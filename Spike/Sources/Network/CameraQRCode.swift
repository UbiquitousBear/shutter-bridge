import Foundation

/// Day 9: what the camera's pairing QR code says. Two payload shapes are accepted:
///
/// - Sony's own, as shown by `Network → Cnct./PC Remote → Smartphone Connect`: `W01:S:…;P:…;C:…;M:…;`.
///   Community notes read S as the SSID (or its suffix), P as the WPA passphrase, C as the camera model and M as
///   the Wi-Fi MAC address. None of that is documented by Sony and all of it is `unverified` on the α7C II, so
///   the parser keeps every key it sees and the spike logs which keys were present (never a secret value).
/// - The common `WIFI:S:<ssid>;T:<WPA|WEP|nopass>;P:<passphrase>;H:<true|false>;;` form (ZXing), with
///   backslash escaping of `\ ; , : "` and optional double quotes around values. Unknown keys are tolerated.
///
/// Foundation only: typechecks on Linux. `description` masks the passphrase; never log `passphrase` itself.
struct CameraQRCode: Equatable, Sendable, CustomStringConvertible {
    enum Format: String, Sendable {
        case sonyW01 = "Sony W01"
        case wifi = "WIFI"
    }

    enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        /// The payload is neither `W01:` nor `WIFI:`. Only a short, non-secret prefix is kept for the log.
        case unrecognised(prefix: String, length: Int)
        /// No SSID-like key was found; `keys` lists the keys that were present.
        case missingSSID(format: Format, keys: [String])

        var description: String {
            switch self {
            case .empty:
                return "empty QR payload"
            case .unrecognised(let prefix, let length):
                return "not a Wi-Fi pairing code (\(length) characters\(prefix.isEmpty ? "" : ", starts \"\(prefix)\""))"
            case .missingSSID(let format, let keys):
                return "\(format.rawValue) code without an SSID key (keys present: \(keys.isEmpty ? "none" : keys.joined(separator: ", ")))"
            }
        }
    }

    let format: Format
    /// The network to join. For Sony codes this may be built from S and C; see `ssidIsDerived`.
    let ssid: String
    /// True when the SSID was assembled from fields rather than read verbatim (Sony W01 hypothesis).
    let ssidIsDerived: Bool
    /// The WPA passphrase, if the code carries one. Secret: never log or save it.
    let passphrase: String?
    /// WIFI: T field (WPA, WEP, nopass …). Nil for Sony codes.
    let security: String?
    let isHidden: Bool
    /// Sony W01: C field, read as the camera model (`unverified`).
    let model: String?
    /// Sony W01: M field, read as the camera's Wi-Fi MAC address (`unverified`).
    let macAddress: String?
    /// Every key present, upper-cased, in payload order. Safe to log.
    let keysPresent: [String]
    /// Keys the parser did not interpret. Safe to log (keys only).
    let unknownKeys: [String]
    /// Observations worth a log line (e.g. how the SSID was derived). Contain no secret values.
    let notes: [String]

    var description: String {
        var parts = ["\(format.rawValue) code", "SSID \"\(ssid)\"\(ssidIsDerived ? " (derived, unverified)" : "")"]
        parts.append("passphrase \(passphrase == nil ? "none" : "••••")")
        if let security { parts.append("security \(security)") }
        if isHidden { parts.append("hidden network") }
        if let model { parts.append("model \(model)") }
        if let macAddress { parts.append("MAC \(macAddress)") }
        parts.append("keys [\(keysPresent.joined(separator: ", "))]")
        return parts.joined(separator: " · ")
    }

    // MARK: Parsing

    static func parse(_ payload: String) throws -> CameraQRCode {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        let upper = trimmed.uppercased()
        if upper.hasPrefix("W01:") {
            return try parseSony(fields(trimmed.dropFirst(4)))
        }
        if upper.hasPrefix("WIFI:") {
            return try parseWiFi(fields(trimmed.dropFirst(5)))
        }
        throw ParseError.unrecognised(prefix: safePrefix(trimmed), length: trimmed.count)
    }

    private static func parseSony(_ fields: [Field]) throws -> CameraQRCode {
        let keys = fields.map(\.key)
        let s = value("S", in: fields)
        let model = value("C", in: fields)
        let mac = value("M", in: fields)
        let passphrase = value("P", in: fields)
        guard let s, !s.isEmpty else { throw ParseError.missingSSID(format: .sonyW01, keys: keys) }

        var notes: [String] = []
        let ssid: String
        let derived: Bool
        if s.uppercased().hasPrefix("DIRECT-") {
            ssid = s
            derived = false
            notes.append("S holds a full DIRECT- SSID")
        } else if let model, !model.isEmpty {
            // Sony bodies show SSIDs like "DIRECT-xxxx:ILCE-7M4"; assume S is the xxxx part and C the model.
            ssid = "DIRECT-\(s):\(model)"
            derived = true
            notes.append("SSID built as DIRECT-<S>:<C> (unverified); compare it with the SSID on the camera screen and edit it before joining if it differs")
        } else {
            ssid = s
            derived = false
            notes.append("S used verbatim as the SSID (no C key to build DIRECT-<S>:<C>); unverified")
        }
        let known: Set<String> = ["S", "P", "C", "M"]
        let unknown = keys.filter { !known.contains($0) }
        if !unknown.isEmpty { notes.append("unknown W01 keys: \(unknown.joined(separator: ", "))") }
        if passphrase == nil { notes.append("no P key: no passphrase in the code") }
        return CameraQRCode(format: .sonyW01, ssid: ssid, ssidIsDerived: derived, passphrase: passphrase,
                            security: nil, isHidden: false, model: model, macAddress: mac,
                            keysPresent: keys, unknownKeys: unknown, notes: notes)
    }

    private static func parseWiFi(_ fields: [Field]) throws -> CameraQRCode {
        let keys = fields.map(\.key)
        guard let ssid = value("S", in: fields), !ssid.isEmpty else { throw ParseError.missingSSID(format: .wifi, keys: keys) }
        let security = value("T", in: fields)
        var passphrase = value("P", in: fields)
        if let p = passphrase, p.isEmpty { passphrase = nil }
        if security?.lowercased() == "nopass" { passphrase = nil }
        let hidden = value("H", in: fields)?.lowercased() == "true"
        let known: Set<String> = ["S", "T", "P", "H"]
        let unknown = keys.filter { !known.contains($0) }
        var notes: [String] = []
        if !unknown.isEmpty { notes.append("unknown WIFI keys: \(unknown.joined(separator: ", "))") }
        if let security, security.uppercased() == "WEP" { notes.append("WEP network: the join uses WPA settings and will fail") }
        return CameraQRCode(format: .wifi, ssid: ssid, ssidIsDerived: false, passphrase: passphrase,
                            security: security, isHidden: hidden, model: nil, macAddress: nil,
                            keysPresent: keys, unknownKeys: unknown, notes: notes)
    }

    // MARK: Field splitting

    struct Field: Equatable, Sendable {
        let key: String
        let value: String
    }

    /// Splits `K:V;K:V;…` honouring backslash escapes. A `:` or `;` preceded by `\` is literal. Values wrapped in
    /// double quotes lose the quotes. Keys are upper-cased; empty fields (the trailing `;;`) are dropped.
    static func fields(_ body: Substring) -> [Field] {
        var out: [Field] = []
        var key = ""
        var value = ""
        var inValue = false
        var escaping = false

        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces).uppercased()
            if !k.isEmpty || !value.isEmpty {
                out.append(Field(key: k, value: unquote(value)))
            }
            key = ""
            value = ""
            inValue = false
        }

        for ch in body {
            if escaping {
                if inValue { value.append(ch) } else { key.append(ch) }
                escaping = false
                continue
            }
            switch ch {
            case "\\":
                escaping = true
            case ";":
                flush()
            case ":" where !inValue:
                inValue = true
            default:
                if inValue { value.append(ch) } else { key.append(ch) }
            }
        }
        if escaping {
            if inValue { value.append("\\") } else { key.append("\\") }
        }
        flush()
        return out
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func value(_ key: String, in fields: [Field]) -> String? {
        fields.first { $0.key == key }?.value
    }

    /// Up to the first colon of an unrecognised payload, if that looks like a format tag ("W02:", "MECARD:").
    /// Anything else is withheld: an unknown payload might itself contain a password.
    private static func safePrefix(_ s: String) -> String {
        guard let colon = s.firstIndex(of: ":") else { return "" }
        let head = s[..<colon]
        guard head.count <= 8, head.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "" }
        return String(head) + ":"
    }
}
