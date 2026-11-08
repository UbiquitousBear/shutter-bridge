// Seeded garbage in, throw or succeed out, never a crash: every decoder gets random bytes, truncations and mutations of
// valid values, and where it succeeds the result is checked against an independent oracle. A trap would end the whole
// test process, so a pass means no input in these streams crashed anything. Every base seed is a literal; a failure
// prints "seed 0x… iteration N" and replays identically.

import Testing
import Foundation
@testable import BLEKit

@Suite("Garbage input never crashes a decoder")
struct GarbageInputTests {
    static let iterations = 3000

    func label(_ seed: UInt64, _ i: Int) -> Comment { "seed 0x\(String(seed, radix: 16)) iteration \(i)" }

    // MARK: Status entries

    /// A valid value: 0 to 6 random entries (values 0 to 20 bytes, edge-biased), and the entries.
    func validStatus(_ g: inout SplitMix64) -> (data: Data, entries: [SonyStatusEntry]) {
        var entries: [SonyStatusEntry] = []
        for _ in 0 ..< g.int(1 ... 6) {
            let tag = UInt16(g.u8()) << 8 | UInt16(g.u8())
            entries.append(SonyStatusEntry(tag: SonyStatusTag(rawValue: tag), value: g.bytes(g.length(20))))
        }
        return (Fixtures.encode(entries), entries)
    }

    /// The decoder's answer worked out a second way: walk the bytes with offsets, nil when any entry is malformed.
    func oracle(_ bytes: [UInt8]) -> [SonyStatusEntry]? {
        var out: [SonyStatusEntry] = []
        var at = 0
        while at < bytes.count {
            let length = Int(bytes[at])
            if length < 2 || at + 1 + length > bytes.count { return nil }
            let tag = UInt16(bytes[at + 1]) << 8 | UInt16(bytes[at + 2])
            out.append(SonyStatusEntry(tag: SonyStatusTag(rawValue: tag), value: Array(bytes[(at + 3) ..< (at + 1 + length)])))
            at += 1 + length
        }
        return out.isEmpty ? nil : out
    }

    @Test func randomBytesToTheEntryDecoder() {
        let seed: UInt64 = 0x5EED_0B1E_0001
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            let bytes = g.bytes(g.length(64))
            let result = try? SonyStatusEntries.decode(Data(bytes))
            #expect(result == oracle(bytes), label(seed, i))
        }
    }

    @Test func validValuesRoundTrip() throws {
        let seed: UInt64 = 0x5EED_0B1E_0002
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            let (data, entries) = validStatus(&g)
            #expect(try SonyStatusEntries.decode(data) == entries, label(seed, i))
        }
    }

    @Test func truncatedAndMutatedValues() {
        let seed: UInt64 = 0x5EED_0B1E_0003
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            var bytes = [UInt8](validStatus(&g).data)
            switch g.below(3) {
            case 0: bytes = Array(bytes.prefix(g.int(0 ... bytes.count)))
            case 1: bytes[g.int(0 ... bytes.count - 1)] = g.u8()
            default: bytes += g.bytes(g.int(1 ... 4))
            }
            let result = try? SonyStatusEntries.decode(Data(bytes))
            #expect(result == oracle(bytes), label(seed, i))
        }
    }

    @Test func slicesOfGarbage() {
        let seed: UInt64 = 0x5EED_0B1E_0004
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            let lead = g.bytes(g.int(0 ... 5)), body = g.bytes(g.length(40)), tail = g.bytes(g.int(0 ... 5))
            let whole = Data(lead + body + tail)
            let slice = whole[lead.count ..< (lead.count + body.count)]
            let result = try? SonyStatusEntries.decode(slice)
            #expect(result == oracle(body), label(seed, i))
            // The state decoder and the advertisement and credential decoders take the same slice without trouble.
            _ = try? SonyStatus(decoding: slice)
            _ = try? SonyAdvertisement(manufacturerData: slice)
            _ = try? SonyWiFiCredentials.decode(ssidValue: slice, passphraseValue: slice)
        }
    }

    // MARK: Merging

    @Test func randomMergesMatchAnOracleAndFailuresChangeNothing() {
        let seed: UInt64 = 0x5EED_0B1E_0005
        for i in 0 ..< Self.iterations / 3 {
            var g = SplitMix64.iteration(i, of: seed)
            var state = SonyStatus()
            var model: [UInt16: [UInt8]] = [:]
            for _ in 0 ..< g.int(1 ... 8) {
                var bytes: [UInt8]
                if g.chance(3) {
                    bytes = g.bytes(g.length(30))
                } else {
                    bytes = [UInt8](validStatus(&g).data)
                    if g.chance(4) { bytes.append(g.u8()) }
                }
                let before = state
                if let entries = oracle(bytes) {
                    var expectedChanges = 0
                    var next = model
                    for e in entries { next[e.tag.rawValue] = e.value }
                    for (tag, value) in next where model[tag] != value { expectedChanges += 1 }
                    let changes = try? state.merge(Data(bytes))
                    #expect(changes?.count == expectedChanges, label(seed, i))
                    #expect(changes?.map(\.tag.rawValue) == changes?.map(\.tag.rawValue).sorted(), label(seed, i))
                    model = next
                } else {
                    #expect(throws: (any Error).self, label(seed, i)) { try state.merge(Data(bytes)) }
                    #expect(state == before, label(seed, i))
                }
                #expect(Dictionary(uniqueKeysWithValues: state.values.map { ($0.key.rawValue, $0.value) }) == model, label(seed, i))
                // The accessors never trap, whatever the state holds.
                _ = state.wifiStatus
                _ = state.remoteControlAvailable
                _ = state.description
            }
        }
    }

    // MARK: Network details

    /// CC06/CC07-shaped bytes: a 3-byte prefix, text (printable or not, UTF-8 or not), padding, sometimes cut short.
    func networkBytes(_ g: inout SplitMix64) -> [UInt8] {
        var out = g.bytes(3)
        switch g.below(5) {
        case 0: out += g.bytes(g.length(70))
        case 1: out += Array(g.printable(g.length(70)).utf8)
        case 2: out += Array(g.printable(g.int(8 ... 63)).utf8)
        case 3: out += Array(g.printable(g.int(1 ... 32)).utf8) + [0xE2, 0x82]
        default: out += Array(g.printable(g.int(0 ... 40)).utf8) + [UInt8](repeating: 0, count: g.int(0 ... 4))
        }
        if g.chance(6) { out = Array(out.prefix(g.int(0 ... out.count))) }
        return out
    }

    @Test func randomNetworkValues() throws {
        let seed: UInt64 = 0x5EED_0B1E_0006
        var successes = 0
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            let ssidBytes = networkBytes(&g)
            let passBytes = networkBytes(&g)
            let bssid: Data? = g.chance(2) ? nil : Data(g.bytes(g.length(9)))
            guard let credentials = try? SonyWiFiCredentials.decode(ssidValue: Data(ssidBytes), passphraseValue: Data(passBytes), bssidValue: bssid) else {
                continue
            }
            successes += 1
            // Whatever decoded satisfies the rules the decoder promises.
            #expect((1 ... 32).contains(credentials.ssid.utf8.count), label(seed, i))
            #expect(!credentials.ssid.utf8.contains(0), label(seed, i))
            #expect(SonyWiFiCredentials.isValidPassphrase(credentials.passphrase), label(seed, i))
            #expect(credentials.bssidPresent == !(bssid?.isEmpty ?? true), label(seed, i))
            // And the text is what follows the prefix, less trailing zeros.
            var tail = Array(ssidBytes.dropFirst(3))
            while tail.last == 0 { tail.removeLast() }
            #expect(Array(credentials.ssid.utf8) == tail, label(seed, i))
            // Redaction holds for whatever the camera might send.
            #expect(!credentials.description.contains(credentials.passphrase), label(seed, i))
            #expect(!"\(Mirror(reflecting: credentials).children.map { "\($0.value)" })".contains(credentials.passphrase), label(seed, i))
        }
        // The generator reaches the success path, or the loop above proves nothing.
        #expect(successes > 50, "only \(successes) of \(Self.iterations) network values decoded")
    }

    @Test func randomPassphrasesAgainstTheRule() {
        let seed: UInt64 = 0x5EED_0B1E_0007
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            var scalars: [Unicode.Scalar] = []
            for _ in 0 ..< g.length(70) {
                let raw: UInt32 = g.chance(4) ? UInt32(g.int(0 ... 0x2FF)) : UInt32(g.int(0x20 ... 0x7E))
                scalars.append(Unicode.Scalar(raw) ?? "?")
            }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            let text = String(view)
            let expected = (8 ... 63).contains(scalars.count) && scalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
            #expect(SonyWiFiCredentials.isValidPassphrase(text) == expected, label(seed, i))
        }
    }

    // MARK: Advertisement

    @Test func randomManufacturerData() {
        let seed: UInt64 = 0x5EED_0B1E_0008
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            let bytes = g.bytes(g.length(40))
            if let advert = try? SonyAdvertisement(manufacturerData: Data(bytes)) {
                #expect(bytes.count >= 2, label(seed, i))
                #expect(advert.companyID == UInt16(bytes[0]) | UInt16(bytes[1]) << 8, label(seed, i))
                #expect(advert.payload == Array(bytes.dropFirst(2)), label(seed, i))
                #expect(advert.isSony == (bytes[0] == 0x2D && bytes[1] == 0x01), label(seed, i))
            } else {
                #expect(bytes.count < 2, label(seed, i))
            }
        }
    }

    @Test func randomNames() {
        let seed: UInt64 = 0x5EED_0B1E_0009
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            var name = g.printable(g.length(20))
            if g.chance(4) { name.insert(contentsOf: g.element(["ilce", "ILCE", "Sony", "sOnY"]), at: name.index(name.startIndex, offsetBy: g.int(0 ... name.count))) }
            let expected = name.uppercased().contains("ILCE") || name.uppercased().contains("SONY")
            #expect(SonyAdvertisement.nameLooksLikeCamera(name) == expected, label(seed, i))
        }
    }

    // MARK: Identifiers

    @Test func randomUUIDsAndCodes() {
        let seed: UInt64 = 0x5EED_0B1E_000A
        for i in 0 ..< Self.iterations {
            var g = SplitMix64.iteration(i, of: seed)
            var b = g.bytes(16)
            // Half the draws are shaped like the camera's UUIDs, with one random byte changed or not.
            if g.chance(2) {
                let tail = g.chance(2) ? SonyBluetooth.sonyTail : SonyBluetooth.bluetoothBaseTail
                b = [0, 0, g.u8(), g.u8()] + tail
                if g.chance(2) { b[g.int(0 ... 15)] = g.u8() }
            }
            let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            let code = SonyBluetooth.shortCode(of: uuid)
            let expected: UInt16? = b[0] == 0 && b[1] == 0 && (Array(b[4...]) == SonyBluetooth.sonyTail || Array(b[4...]) == SonyBluetooth.bluetoothBaseTail)
                ? UInt16(b[2]) << 8 | UInt16(b[3]) : nil
            #expect(code == expected, label(seed, i))
            if let c = CameraControlCharacteristic(uuid: uuid) { #expect(c.rawValue == code, label(seed, i)) }
            _ = SonyService(uuid: uuid)
            // Random strings as codes.
            let text = String(decoding: g.bytes(g.int(0 ... 6)), as: UTF8.self)
            if let c = CameraControlCharacteristic(code: text) { #expect(c.code == text.uppercased(), label(seed, i)) }
            // Random strings as CoreBluetooth UUID text: hex of 4 and 8 digits expands, the 36-character form agrees with
            // the uuid it names, anything else is nil.
            let hexDigits = Array("0123456789abcdefABCDEF")
            let hex = String((0 ..< g.element([0, 1, 3, 4, 4, 4, 5, 8, 8, 9, 35, 36])).map { _ in hexDigits[g.int(0 ... hexDigits.count - 1)] })
            var candidates = [text, hex]
            if g.chance(2) {
                // A well-formed 36-character string, sometimes with one character replaced.
                var chars = Array(uuid.uuidString)
                if g.chance(2) { chars[g.int(0 ... 35)] = g.element(Array("G+- é0f")) }
                candidates.append(String(chars))
            }
            for candidate in candidates {
                let parsed = SonyBluetooth.uuid(bluetoothString: candidate)
                let isHex = candidate.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
                if (candidate.utf8.count == 4 || candidate.utf8.count == 8) && isHex {
                    #expect(parsed != nil, label(seed, i))
                    #expect(parsed.map { SonyBluetooth.bytes(of: $0)[4...] } == SonyBluetooth.bluetoothBaseTail[...], label(seed, i))
                    let lead = candidate.utf8.count == 4 ? "0000" : ""
                    #expect(parsed.map { String($0.uuidString.prefix(8)).lowercased() } == lead + candidate.lowercased(), label(seed, i))
                } else if candidate.utf8.count == 36 {
                    // Foundation's own parser is lenient (it takes a space or "+" in a hex position), so it is the oracle only
                    // for text that is strictly dashes at 8, 13, 18 and 23 and hex digits elsewhere.
                    let strict = candidate.utf8.enumerated().allSatisfy { index, c in
                        [8, 13, 18, 23].contains(index) ? c == 0x2D : ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66))
                    }
                    #expect(parsed == (strict ? UUID(uuidString: candidate) : nil), "\(candidate.debugDescription) \(label(seed, i))")
                } else {
                    #expect(parsed == nil, label(seed, i))
                }
            }
        }
    }

    @Test func randomBytesToTheMasker() {
        let seed: UInt64 = 0x5EED_0B1E_000B
        for i in 0 ..< Self.iterations / 3 {
            var g = SplitMix64.iteration(i, of: seed)
            let bytes = g.bytes(g.length(100))
            let text = SonyMasking.maskedHex(bytes)
            // Nothing above 0x0F survives: only hex digits, spaces, the mask and the length note.
            #expect(text.allSatisfy { "0123456789ABCDEF ·…()B".contains($0) || $0.isNumber }, label(seed, i))
            if bytes.count <= 64 { #expect(text.split(separator: " ").count == (bytes.isEmpty ? 2 : bytes.count), label(seed, i)) }
        }
    }
}
