import Testing
import Foundation
@testable import BLEKit

@Suite("CC06 and CC07 decode, and the credentials never print their values")
struct CredentialsTests {
    let ssid = Fixtures.ssid
    let passphrase = Fixtures.passphrase

    func decode(_ ssidValue: Data, _ passphraseValue: Data, bssid: Data? = nil) throws -> SonyWiFiCredentials {
        try SonyWiFiCredentials.decode(ssidValue: ssidValue, passphraseValue: passphraseValue, bssidValue: bssid)
    }

    // MARK: Decoding

    @Test func textFollowsTheThreeBytePrefix() throws {
        let credentials = try decode(Fixtures.networkValue(ssid), Fixtures.networkValue(passphrase))
        #expect(credentials.ssid == ssid)
        #expect(credentials.passphrase == passphrase)
        #expect(!credentials.bssidPresent)
        #expect(SonyWiFiCredentials.prefixLength == 3)
    }

    @Test func thePrefixIsNotLookedAt() throws {
        for prefix in [[UInt8](repeating: 0, count: 3), [0xFF, 0xFF, 0xFF], [0x41, 0x42, 0x43]] {
            let credentials = try decode(Fixtures.networkValue(ssid, prefix: prefix), Fixtures.networkValue(passphrase, prefix: prefix))
            #expect(credentials.ssid == ssid)
            #expect(credentials.passphrase == passphrase)
        }
    }

    @Test func trailingZeroBytesAreDropped() throws {
        let credentials = try decode(Fixtures.networkValue(ssid, padding: 4), Fixtures.networkValue(passphrase, padding: 1))
        #expect(credentials.ssid == ssid)
        #expect(credentials.passphrase == passphrase)
    }

    @Test func bssidIsPresentWhenCC0CHasAValue() throws {
        #expect(try decode(Fixtures.networkValue(ssid), Fixtures.networkValue(passphrase), bssid: Data([1, 2, 3, 4, 5, 6])).bssidPresent)
        #expect(try !decode(Fixtures.networkValue(ssid), Fixtures.networkValue(passphrase), bssid: Data()).bssidPresent)
        #expect(try !decode(Fixtures.networkValue(ssid), Fixtures.networkValue(passphrase), bssid: nil).bssidPresent)
    }

    @Test func slicesWithAnOffsetDecode() throws {
        let padded = Data([0xEE]) + Fixtures.networkValue(ssid)
        let slice = padded[1...]
        #expect(slice.startIndex == 1)
        #expect(try decode(slice, Fixtures.networkValue(passphrase)).ssid == ssid)
    }

    @Test func aValueWithNoTextThrows() {
        for count in 0 ... 3 {
            let value = Data([UInt8](repeating: 0x41, count: count))
            #expect(throws: SonyNetworkDetailsError.noText(.ssid, byteCount: count)) { try decode(value, Fixtures.networkValue(passphrase)) }
            #expect(throws: SonyNetworkDetailsError.noText(.passphrase, byteCount: count)) { try decode(Fixtures.networkValue(ssid), value) }
        }
        // Only zero bytes after the prefix.
        #expect(throws: SonyNetworkDetailsError.noText(.ssid, byteCount: 7)) {
            try decode(Data(Fixtures.prefix + [0, 0, 0, 0]), Fixtures.networkValue(passphrase))
        }
    }

    @Test func textThatIsNotUTF8Throws() {
        let bad = Data(Fixtures.prefix + [0x44, 0xFF, 0xFE, 0x45])
        #expect(throws: SonyNetworkDetailsError.notUTF8(.ssid)) { try decode(bad, Fixtures.networkValue(passphrase)) }
        #expect(throws: SonyNetworkDetailsError.notUTF8(.passphrase)) { try decode(Fixtures.networkValue(ssid), bad) }
        // A truncated multi-byte sequence.
        let cut = Data(Fixtures.prefix + [0x41, 0xE2, 0x82])
        #expect(throws: SonyNetworkDetailsError.notUTF8(.ssid)) { try decode(cut, Fixtures.networkValue(passphrase)) }
    }

    @Test func aZeroByteInsideTheTextThrows() {
        let inner = Data(Fixtures.prefix + Array("abcd".utf8) + [0] + Array("efgh1234".utf8))
        #expect(throws: SonyNetworkDetailsError.embeddedNUL(.ssid)) { try decode(inner, Fixtures.networkValue(passphrase)) }
        #expect(throws: SonyNetworkDetailsError.embeddedNUL(.passphrase)) { try decode(Fixtures.networkValue(ssid), inner) }
    }

    @Test func theNameIsOneToThirtyTwoBytes() throws {
        let thirtyTwo = String(repeating: "n", count: 32)
        #expect(try decode(Fixtures.networkValue(thirtyTwo), Fixtures.networkValue(passphrase)).ssid == thirtyTwo)
        let thirtyThree = String(repeating: "n", count: 33)
        #expect(throws: SonyNetworkDetailsError.ssidLength(byteCount: 33)) {
            try decode(Fixtures.networkValue(thirtyThree), Fixtures.networkValue(passphrase))
        }
        // The limit counts bytes: eleven three-byte characters are 33 bytes.
        let wide = String(repeating: "\u{20AC}", count: 11)
        #expect(throws: SonyNetworkDetailsError.ssidLength(byteCount: 33)) {
            try decode(Fixtures.networkValue(wide), Fixtures.networkValue(passphrase))
        }
        #expect(throws: SonyNetworkDetailsError.ssidLength(byteCount: 0)) { try SonyWiFiCredentials(ssid: "", passphrase: passphrase) }
    }

    @Test func theNameIsCheckedBeforeThePassphrase() {
        #expect(throws: SonyNetworkDetailsError.noText(.ssid, byteCount: 0)) { try decode(Data(), Data()) }
        #expect(throws: SonyNetworkDetailsError.noText(.passphrase, byteCount: 0)) { try decode(Fixtures.networkValue(ssid), Data()) }
    }

    @Test func initRefusesWhatDecodeRefuses() {
        #expect(throws: SonyNetworkDetailsError.embeddedNUL(.ssid)) { try SonyWiFiCredentials(ssid: "a\u{0}b", passphrase: passphrase) }
        #expect(throws: SonyNetworkDetailsError.invalidPassphrase(characterCount: 5)) { try SonyWiFiCredentials(ssid: ssid, passphrase: "short") }
        #expect(throws: Never.self) { try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase, bssidPresent: true) }
    }

    // MARK: The passphrase rule

    @Test func passphraseIsEightToSixtyThreePrintableASCII() {
        func valid(_ s: String) -> Bool { SonyWiFiCredentials.isValidPassphrase(s) }
        #expect(!valid(""))
        #expect(!valid(String(repeating: "a", count: 7)))
        #expect(valid(String(repeating: "a", count: 8)))
        #expect(valid(String(repeating: "a", count: 63)))
        #expect(!valid(String(repeating: "a", count: 64)))
        #expect(valid("pass word 12"))                     // 0x20 is printable
        #expect(valid("~~~~~~~~"))                         // 0x7E is the last
        #expect(!valid("pass\tword12"))                    // a tab
        #expect(!valid("password\u{7F}"))                  // DEL
        #expect(!valid("p\u{E4}ssword1"))                  // ä
        #expect(!valid("password\u{1F512}"))               // an astral scalar: 9 scalars, none ASCII
        #expect(!valid("pass\u{0}word1"))
        #expect(!valid("passwor\n"))
    }

    @Test func invalidPassphrasesThrowWithTheirLengthOnly() {
        for (text, count) in [("short", 5), (String(repeating: "x", count: 64), 64), ("p\u{E4}ssword1", 9)] {
            #expect(throws: SonyNetworkDetailsError.invalidPassphrase(characterCount: count)) {
                try decode(Fixtures.networkValue(ssid), Fixtures.networkValue(text))
            }
        }
    }

    // MARK: Redaction

    /// Every way a value gets printed, as one list of strings.
    func surfaces(of credentials: SonyWiFiCredentials) -> [String] {
        var dumped = ""
        dump(credentials, to: &dumped)
        var printed = ""
        print(credentials, to: &printed)
        var debugPrinted = ""
        debugPrint(credentials, to: &debugPrinted)
        var reflected = ""
        for child in Mirror(reflecting: credentials).children { reflected += "\(child.label ?? "")=\(child.value);" }
        return [
            "\(credentials)", String(describing: credentials), String(reflecting: credentials), credentials.description,
            credentials.debugDescription, "\(credentials.playgroundDescription)", dumped, printed, debugPrinted, reflected,
            "\([credentials])", "\(Optional(credentials) as Any)", "\(["k": credentials])",
        ]
    }

    @Test func nothingPrintsTheValues() throws {
        let credentials = try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase, bssidPresent: true)
        let all = surfaces(of: credentials)
        #expect(all.count == 13)
        for text in all {
            #expect(!text.contains(ssid))
            #expect(!text.contains(passphrase))
            for fragment in ["ab12", "TEST-CAM", "test-pass", "pass-1234", "1234"] {
                #expect(!text.contains(fragment), "a surface printed \(fragment)")
            }
            #expect(text.contains("SSID 20 chars"))
            #expect(text.contains("passphrase 14 chars"))
        }
    }

    @Test func theDescriptionIsLengthsAndYesNoOnly() throws {
        let credentials = try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase, bssidPresent: true)
        #expect(credentials.description
            == "SSID 20 chars, DIRECT- prefix yes · passphrase 14 chars, 8–63 printable ASCII yes · BSSID present")
        let plain = try SonyWiFiCredentials(ssid: "home-net", passphrase: "12345678")
        #expect(plain.description
            == "SSID 8 chars, DIRECT- prefix no · passphrase 8 chars, 8–63 printable ASCII yes · BSSID absent")
        #expect(credentials.debugDescription == credentials.description)
        #expect(credentials.playgroundDescription as? String == credentials.description)
    }

    @Test func theMirrorHasOneRedactedChild() throws {
        let credentials = try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase)
        let mirror = Mirror(reflecting: credentials)
        #expect(mirror.children.count == 1)
        #expect(mirror.children.first?.label == "redacted")
        #expect(mirror.children.first?.value as? String == credentials.description)
        // Unlike a stored-property mirror, it has no `ssid` or `passphrase` child.
        #expect(!mirror.children.contains { $0.label == "ssid" || $0.label == "passphrase" })
    }

    @Test func testFailureMessagesAreRedactedToo() throws {
        // #expect prints its operands with String(reflecting:); that is the redacted text.
        let credentials = try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase)
        #expect(String(reflecting: credentials) == credentials.description)
        #expect(String(reflecting: Optional(credentials)).contains("SSID 20 chars"))
        #expect(!String(reflecting: Optional(credentials)).contains(passphrase))
    }

    @Test func itIsNotEncodableOrDecodable() throws {
        let credentials = try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase)
        #expect((credentials as Any) is Encodable == false)
        #expect((credentials as Any) is Decodable == false)
        requireSendable(credentials)   // compile-time: every public type is Sendable
    }

    @Test func errorsNeverCarryTheValues() {
        let secret = "s3cret-Pass"   // 11 printable characters, valid: build an invalid one around it
        let tooLong = secret + String(repeating: "x", count: 60)
        let failures: [any Error] = [
            capture { try SonyWiFiCredentials(ssid: ssid, passphrase: tooLong) },
            capture { try SonyWiFiCredentials(ssid: String(repeating: "N", count: 40) + secret, passphrase: passphrase) },
            capture { try decode(Fixtures.networkValue(ssid), Fixtures.networkValue(tooLong)) },
            capture { try decode(Data(Fixtures.prefix + Array(secret.utf8) + [0xFF]), Fixtures.networkValue(passphrase)) },
            capture { try decode(Data(Fixtures.prefix + Array(secret.utf8) + [0] + Array(secret.utf8)), Fixtures.networkValue(passphrase)) },
            capture { try decode(Data(Fixtures.prefix), Fixtures.networkValue(passphrase)) },
        ]
        #expect(failures.count == 6)
        for error in failures {
            for text in ["\(error)", String(describing: error), String(reflecting: error), (error as? SonyNetworkDetailsError)?.description ?? ""] {
                #expect(!text.contains(secret))
                #expect(!text.contains("xxxx"))
                #expect(!text.contains(ssid))
                #expect(!text.contains(passphrase))
            }
        }
        #expect(SonyNetworkDetailsError.invalidPassphrase(characterCount: 5).description
            == "password is 5 characters, or not printable ASCII; needs 8 to 63 printable ASCII")
        #expect(SonyNetworkDetailsError.noText(.ssid, byteCount: 3).description == "CC06 (network name) is 3 B, with no text after the 3-byte prefix")
    }

    func requireSendable<T: Sendable>(_ value: T) {}

    /// The error a throwing closure throws; a failing expectation if it doesn't throw.
    func capture(_ body: () throws -> Any) -> any Error {
        do {
            _ = try body()
        } catch {
            return error
        }
        Issue.record("expected a throw")
        return SonyNetworkDetailsError.notUTF8(.ssid)
    }

    @Test func equalCredentialsCompareEqual() throws {
        let a = try SonyWiFiCredentials(ssid: ssid, passphrase: passphrase)
        let b = try decode(Fixtures.networkValue(ssid), Fixtures.networkValue(passphrase))
        #expect(a == b)
        #expect(try a != SonyWiFiCredentials(ssid: ssid, passphrase: "other-pass-1"))
        #expect(try a != SonyWiFiCredentials(ssid: ssid, passphrase: passphrase, bssidPresent: true))
    }
}
