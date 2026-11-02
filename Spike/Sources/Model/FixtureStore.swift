import Foundation
import CryptoKit   // CameraSerialTag
import PTPKit

/// Where captured camera bytes go on the phone, laid out exactly like the repo's `Fixtures/a7c2/` folder:
///
///     Documents/fixtures/a7c2/<usb|ptpip|ble>/<name>     e.g. usb/deviceinfo.bin, ptpip/objectinfo-arw.bin
///     Documents/fixtures/a7c2/<link>/FIRMWARE            "ILCE-7CM2 2.00" from GetDeviceInfo
///
/// Documents is visible in the Files app (UIFileSharingEnabled), and the Log tab shares the whole folder as a
/// zip, so the folder can be copied straight over `Fixtures/a7c2/` on the Mac; `make fixtures` then copies the
/// files the unit tests need into PTPKit.
///
/// Naming (keep in step with Fixtures/README.md and PTPKit's fixture tests): `deviceinfo.bin`,
/// `storageinfo.bin`, `storageids.bin`, `objecthandles.bin`, `objectinfo-<ext>.bin` (arw, jpg, hif, mp4),
/// `event-<name>.bin` (USB: one PTP event container; PTP/IP: one whole Event packet), `<what>.sha256` text,
/// and for BLE `advert-<on|asleep|off>.json` (latest snapshot per power state) plus
/// `advert-<on|asleep|off>-<connected|unlinked|unpaired>.json` (the same snapshot per Creators' App pairing
/// context; the owner's camera is normally paired with Creators' App).
///
/// Never write a Wi-Fi password, SSID passphrase or QR payload here. DeviceInfo goes through `saveDeviceInfo`,
/// which zeroes the camera's serial number: it must never reach the public repo.
@MainActor
enum FixtureStore {
    enum Link: String, CaseIterable, Sendable {
        case usb, ptpip, ble
    }

    static var root: URL {
        URL.documentsDirectory.appending(path: "fixtures/a7c2", directoryHint: .isDirectory)
    }

    static func folder(_ link: Link) -> URL {
        root.appending(path: link.rawValue, directoryHint: .isDirectory)
    }

    /// Saves `data` as `<link>/<name>`, replacing an earlier capture of the same name, and logs it. `detail` is
    /// added to the log line.
    @discardableResult
    static func save(_ data: Data, link: Link, name: String, log: SpikeLog?, detail: String? = nil) -> URL? {
        let dir = folder(link)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: name)
            try data.write(to: url, options: .atomic)
            log?.note("fixture saved: \(link.rawValue)/\(name) (\(data.count) bytes\(detail.map { ", \($0)" } ?? ""))")
            return url
        } catch {
            log?.warn("could not save fixture \(link.rawValue)/\(name): \(error)")
            return nil
        }
    }

    /// Saves a GetDeviceInfo dataset as `<link>/deviceinfo.bin` with its SerialNumber zeroed. If the dataset can't
    /// be walked to that field, nothing is saved and the log says why.
    @discardableResult
    static func saveDeviceInfo(_ data: Data, link: Link, log: SpikeLog?) -> URL? {
        let name = "deviceinfo.bin"
        do {
            return save(try zeroingSerialNumber(in: data), link: link, name: name, log: log, detail: "serial zeroed")
        } catch {
            log?.warn("fixture not saved: \(link.rawValue)/\(name): could not walk DeviceInfo to the SerialNumber to zero it (\(error))")
            return nil
        }
    }

    /// `data` with every character of DeviceInfo's SerialNumber replaced by "0": same length, every other byte
    /// unchanged. Walks ISO 15740 §5.1.1 up to the field: StandardVersion u16, VendorExtensionID u32,
    /// VendorExtensionVersion u16, VendorExtensionDesc string, FunctionalMode u16, five u16 arrays (operations,
    /// events, device properties, capture formats, image formats), Manufacturer, Model, DeviceVersion strings,
    /// then SerialNumber. A PTP string is a u8 count of UTF-16LE code units including the NUL, then the units;
    /// each non-NUL unit becomes 0x30 0x00. Throws if the dataset ends before the SerialNumber does.
    nonisolated static func zeroingSerialNumber(in data: Data) throws -> Data {
        var reader = PTPReader(data)
        _ = try reader.u16()
        _ = try reader.u32()
        _ = try reader.u16()
        _ = try reader.string()
        _ = try reader.u16()
        for _ in 0 ..< 5 { _ = try reader.u16Array() }
        for _ in 0 ..< 3 { _ = try reader.string() }
        let countAt = reader.offset
        _ = try reader.string()   // throws if the serial's code units run past the end
        var bytes = [UInt8](data)   // zero-based, whatever `data`'s startIndex
        let units = Int(bytes[countAt])
        for unit in 0 ..< units {
            let at = countAt + 1 + unit * 2
            if bytes[at] == 0 && bytes[at + 1] == 0 { continue }
            bytes[at] = 0x30
            bytes[at + 1] = 0x00
        }
        return Data(bytes)
    }

    /// Saves a UPnP device description as `ptpip/ssdp-description.xml` with the text of every serialNumber element
    /// zeroed, as scripts/redact-fixtures.py does before a commit, and the camera's hardware ID (the UDN's last
    /// group, which also appears in other fields) zeroed everywhere in it. Refuses (and logs why) if the zeroed bytes
    /// still parse to a serialNumber that isn't all zeros (CDATA, an entity: forms the zeroing pattern can't reach).
    @discardableResult
    static func saveSSDPDescription(_ data: Data, log: SpikeLog?) -> URL? {
        let name = "ssdp-description.xml"
        guard let serialZeroed = zeroingSSDPSerial(in: data) else {
            log?.warn("fixture not saved: ptpip/\(name): could not zero the serialNumber in it")
            return nil
        }
        guard let hardwareZeroed = zeroingSSDPHardwareID(in: serialZeroed.data) else {
            log?.warn("fixture not saved: ptpip/\(name): could not zero the camera's hardware ID (the UDN's last group) in it")
            return nil
        }
        let zeroed = (data: hardwareZeroed.data, characters: serialZeroed.characters)
        // Every serialNumber element, CDATA included, not just the first one the summary shows.
        if let parsed = SSDPDeviceDescription.parse(zeroed.data),
           parsed.allSerialNumbers.contains(where: { value in value.contains { $0 != "0" && !$0.isWhitespace } }) {
            log?.warn("fixture not saved: ptpip/\(name): after zeroing, the XML parser still reads a serialNumber that isn't all zeros (CDATA or an entity?)")
            return nil
        }
        // The same check for the hardware ID, on the UDN the parser reads (the root device's): a UDN in CDATA or
        // written with an entity escapes the zeroing pattern. Never logs the value.
        if let parsed = SSDPDeviceDescription.parse(zeroed.data), hasNonZeroHardwareID(udn: parsed.udn) {
            log?.warn("fixture not saved: ptpip/\(name): after zeroing, the XML parser still reads a UDN whose last group isn't all zeros (CDATA or an entity?)")
            return nil
        }
        // The ID itself is never logged, only how often it was replaced.
        let hardwareDetail = hardwareZeroed.occurrences > 0
            ? "hardware ID zeroed (\(hardwareZeroed.occurrences) occurrence(s))"
            : "no non-zero hardware ID in a UDN"
        return save(zeroed.data, link: .ptpip, name: name, log: log,
                    detail: (zeroed.characters > 0 ? "serial zeroed" : "no serialNumber in it") + ", " + hardwareDetail)
    }

    /// True when `udn`'s last group (after the last "-") is 12 hex digits, not all of them zero: a hardware ID.
    nonisolated static func hasNonZeroHardwareID(udn: String) -> Bool {
        guard let last = udn.split(separator: "-").last, last.count == 12, last.allSatisfy({ $0.isHexDigit }) else {
            return false
        }
        return last.contains { $0 != "0" }
    }

    /// A UDN element as DeviceDescriptionParser sees one (any namespace prefix, attributes or case), whose value is
    /// `uuid:` and a UUID. Group 1 is the UUID's last group, 12 hex digits: the camera's hardware ID (a MAC-like
    /// number; the PTP/IP responder GUID in Init_Command_Ack ends in the same digits).
    nonisolated private static let ssdpUDNPattern =
        #"<(?:[\w.-]+:)?UDN\b[^>]*>\s*uuid:[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-([0-9A-F]{12})"#

    /// `data` with every occurrence, in any case, of each UDN's hardware ID (see `ssdpUDNPattern`) replaced by
    /// "000000000000", wherever it appears (the UDN, USN-like fields, a presentation URL), every other byte
    /// unchanged, and how many occurrences were replaced; nil if that can't be done byte for byte. An ID that is all
    /// zeros already is left alone. ISO Latin-1 keeps the edit byte for byte, as in `zeroingSSDPSerial`.
    nonisolated static func zeroingSSDPHardwareID(in data: Data) -> (data: Data, occurrences: Int)? {
        guard let text = String(data: data, encoding: .isoLatin1),
              let pattern = try? NSRegularExpression(pattern: ssdpUDNPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = NSMutableString(string: text)
        let zeros = "000000000000"
        var ids: Set<String> = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range(at: 1)
            guard range.location != NSNotFound, range.length == 12 else { continue }
            let id = ns.substring(with: range).lowercased()
            if id != zeros { ids.insert(id) }
        }
        var replaced = 0
        for id in ids {
            // Hex digits only, so a literal, case-insensitive search needs no escaping.
            replaced += ns.replaceOccurrences(of: id, with: zeros, options: [.caseInsensitive, .literal],
                                              range: NSRange(location: 0, length: ns.length))
        }
        guard replaced > 0 else { return (data, 0) }
        guard let out = (ns as String).data(using: .isoLatin1), out.count == data.count else { return nil }
        return (out, replaced)
    }

    /// A serialNumber element as DeviceDescriptionParser sees one (it matches local names): any namespace prefix,
    /// attributes or spaces in the tag, any case. Its text ends at the closing tag, at the next tag if it is never
    /// closed, or at the end of a truncated description. Same pattern as scripts/redact-fixtures.py.
    nonisolated private static let ssdpSerialPattern =
        #"<(?:[\w.-]+:)?serialNumber\b[^>]*>(.*?)(?:</(?:[\w.-]+:)?serialNumber\s*>|(?=<)|\Z)"#

    /// `data` with every non-whitespace byte of each serialNumber element's text replaced by "0", every other byte
    /// unchanged (the same rule as scripts/redact-fixtures.py), and how many bytes were replaced; nil if that can't
    /// be done. ISO Latin-1 maps each byte to one character and back, so the edit is byte for byte whatever the
    /// encoding.
    nonisolated static func zeroingSSDPSerial(in data: Data) -> (data: Data, characters: Int)? {
        guard let text = String(data: data, encoding: .isoLatin1),
              let pattern = try? NSRegularExpression(pattern: ssdpSerialPattern,
                                                     options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = NSMutableString(string: text)
        var replaced = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let range = match.range(at: 1)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            let value = ns.substring(with: range)
            // Per scalar (each one byte here); whitespace is space, tab, CR and LF only, as in the Python.
            var zeroedValue = String.UnicodeScalarView()
            for scalar in value.unicodeScalars {
                if scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n" || scalar == "0" {
                    zeroedValue.append(scalar)
                } else {
                    zeroedValue.append("0")
                    replaced += 1
                }
            }
            let zeroedText = String(zeroedValue)
            if zeroedText != value { ns.replaceCharacters(in: range, with: zeroedText) }
        }
        guard replaced > 0 else { return (data, 0) }
        guard let out = (ns as String).data(using: .isoLatin1), out.count == data.count else { return nil }
        return (out, replaced)
    }

    @discardableResult
    static func saveText(_ text: String, link: Link, name: String, log: SpikeLog?) -> URL? {
        save(Data(text.utf8), link: link, name: name, log: log)
    }

    /// Records the camera model and firmware the fixtures in `link` came from (Fixtures/README.md asks for it).
    static func recordFirmware(model: String, version: String, link: Link, log: SpikeLog?) {
        saveText("\(model) \(version)\n", link: link, name: "FIRMWARE", log: log)
    }

    /// Every captured file, relative to `root`, for the Log tab.
    static func inventory() -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = root.standardizedFileURL.path(percentEncoded: false)
        var out: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            out.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent)
        }
        return out.sorted()
    }

    /// Zips the fixtures folder for sharing, using the file coordinator's `.forUploading` option (the system's own
    /// zip, no third-party code). The zip lands in the temporary directory.
    static func zipArchive() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileNoSuchFile))
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinationError) { zipped in
            let dest = FileManager.default.temporaryDirectory.appending(path: "a7c2-fixtures-\(Int(Date().timeIntervalSince1970)).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipped, to: dest)
                result = .success(dest)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func clear(log: SpikeLog?) {
        try? FileManager.default.removeItem(at: root)
        log?.note("fixtures cleared")
    }
}

/// What the spike uses in place of the camera's serial number in object identities and resume paths
/// (`Imports/<tag>/<file>.part`), both of which reach the exported log: the serial must never reach the public
/// repo, and findings are written from that log.
///
/// "sn-" and the first 12 hex digits of HMAC-SHA-256(serial) under a random key made once per install and kept in
/// UserDefaults. Stable for the life of the install, so identity equality and resume matching work over USB and
/// Wi-Fi alike; one-way. A plain SHA-256 would not do: a camera serial has few enough digits that its hash can be
/// reversed by trying them all. An empty serial stays empty.
enum CameraSerialTag {
    private static let keyDefaultsKey = "spike.cameraSerialTag.key"

    static func tag(_ serial: String) -> String {
        guard !serial.isEmpty else { return "" }
        let code = HMAC<SHA256>.authenticationCode(for: Data(serial.utf8), using: key)
        return "sn-" + code.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The same keyed tag for another identifier that must not reach the log as it is (an MTP
    /// PersistentUniqueObjectIdentifier may embed the serial): "id-" and 12 hex digits.
    static func tag(bytes: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: bytes, using: key)
        return "id-" + code.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static var key: SymmetricKey {
        let defaults = UserDefaults.standard
        if let stored = defaults.data(forKey: keyDefaultsKey), stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        let fresh = SymmetricKey(size: .bits256)
        defaults.set(fresh.withUnsafeBytes { Data($0) }, forKey: keyDefaultsKey)
        return fresh
    }
}
