import Testing
import Foundation
@testable import BLEKit

@Suite("CC09's entries decode as the α7C II sent them")
struct StatusEntriesTests {
    @Test func aFullReadHasTenTagsInFortyThreeBytes() throws {
        #expect(Fixtures.cc09ReadWiFiOff.count == 43)
        let entries = try SonyStatusEntries.decode(Fixtures.cc09ReadWiFiOff)
        #expect(entries.map(\.tag.rawValue) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(entries.map(\.value) == [[0, 0], [1], [1], [0, 0, 0], [1], [0], [0], [0], [0], [1]])
    }

    @Test func aNotificationIsOneEntry() throws {
        let entries = try SonyStatusEntries.decode(Data([0x04, 0x00, 0x01, 0x02, 0x00]))
        #expect(entries == [SonyStatusEntry(tag: .wifiStatus, value: [0x02, 0x00])])
    }

    @Test func theTagIsBigEndian() throws {
        // The spike's first parser assumed tag before length; the bytes `04 00 01` make the length 4 and the tag 0x0001.
        let entries = try SonyStatusEntries.decode(Data([0x03, 0x01, 0x00, 0xAA]))
        #expect(entries.first?.tag.rawValue == 0x0100)
        #expect(entries.first?.value == [0xAA])
    }

    @Test func otherCharacteristicsUseTheSameLayout() throws {
        let band = try SonyStatusEntries.decode(Fixtures.ccABRead)
        #expect(band == [SonyStatusEntry(tag: SonyStatusTag(rawValue: 0), value: [0x02, 0x03])])
        let a1 = try SonyStatusEntries.decode(Fixtures.ccA1Notification)
        #expect(a1 == [SonyStatusEntry(tag: SonyStatusTag(rawValue: 0), value: [0x02, 0x01])])
    }

    @Test func aLengthOfTwoIsAnEntryWithAnEmptyValue() throws {
        let entries = try SonyStatusEntries.decode(Data([0x02, 0x00, 0x07]))
        #expect(entries == [SonyStatusEntry(tag: .liveStreaming, value: [])])
        // It sits between full entries without upsetting them.
        let mixed = try SonyStatusEntries.decode(Data([0x03, 0x00, 0x02, 0x01, 0x02, 0x00, 0x03, 0x03, 0x00, 0x05, 0x01]))
        #expect(mixed.map(\.value) == [[1], [], [1]])
    }

    @Test func theLongestEntryDecodes() throws {
        let value = [UInt8](repeating: 0x5A, count: 253)
        let entries = try SonyStatusEntries.decode(Data([0xFF, 0x12, 0x34] + value))
        #expect(entries == [SonyStatusEntry(tag: SonyStatusTag(rawValue: 0x1234), value: value)])
    }

    @Test func duplicatesStayDuplicates() throws {
        let entries = try SonyStatusEntries.decode(Data([0x03, 0x00, 0x01, 0x01, 0x03, 0x00, 0x01, 0x02]))
        #expect(entries.map(\.value) == [[1], [2]])
    }

    @Test func slicesWithAnOffsetDecodeTheSame() throws {
        let padded = Data([0xEE, 0xEE]) + Fixtures.cc09ReadWiFiOff + Data([0xEE])
        let slice = padded[2 ..< (2 + 43)]
        #expect(slice.startIndex == 2)
        #expect(try SonyStatusEntries.decode(slice) == SonyStatusEntries.decode(Fixtures.cc09ReadWiFiOff))
    }

    // MARK: Malformed input throws

    @Test func emptyThrows() {
        #expect(throws: SonyStatusError.empty) { try SonyStatusEntries.decode(Data()) }
    }

    @Test func zeroAndOneLengthsThrow() {
        #expect(throws: SonyStatusError.lengthTooShort(offset: 0, length: 0)) { try SonyStatusEntries.decode(Data([0x00])) }
        #expect(throws: SonyStatusError.lengthTooShort(offset: 0, length: 0)) {
            try SonyStatusEntries.decode(Data([0x00, 0x00, 0x01, 0x02]))
        }
        #expect(throws: SonyStatusError.lengthTooShort(offset: 0, length: 1)) { try SonyStatusEntries.decode(Data([0x01, 0x00])) }
        // A bad entry after good ones is reported at its own offset, and nothing is returned.
        #expect(throws: SonyStatusError.lengthTooShort(offset: 5, length: 1)) {
            try SonyStatusEntries.decode(Data([0x04, 0x00, 0x01, 0x02, 0x00, 0x01, 0x00]))
        }
    }

    @Test func truncatedEntriesThrow() {
        #expect(throws: SonyStatusError.truncated(offset: 0, length: 4, available: 3)) {
            try SonyStatusEntries.decode(Data([0x04, 0x00, 0x01, 0x02]))
        }
        #expect(throws: SonyStatusError.truncated(offset: 0, length: 2, available: 1)) {
            try SonyStatusEntries.decode(Data([0x02, 0x00]))
        }
        #expect(throws: SonyStatusError.truncated(offset: 0, length: 255, available: 2)) {
            try SonyStatusEntries.decode(Data([0xFF, 0x00, 0x01]))
        }
        // The full read cut anywhere inside an entry.
        #expect(throws: (any Error).self) { try SonyStatusEntries.decode(Fixtures.cc09ReadWiFiOff.dropLast()) }
    }

    @Test func trailingBytesRefuseTheWholeValue() {
        let good = Data([0x04, 0x00, 0x01, 0x02, 0x00])
        // A zero byte of padding after the last entry: a zero length.
        #expect(throws: SonyStatusError.lengthTooShort(offset: 5, length: 0)) { try SonyStatusEntries.decode(good + Data([0x00])) }
        // A partial entry after it.
        #expect(throws: SonyStatusError.truncated(offset: 5, length: 3, available: 1)) {
            try SonyStatusEntries.decode(good + Data([0x03, 0x00]))
        }
        #expect(throws: SonyStatusError.truncated(offset: 5, length: 255, available: 0)) {
            try SonyStatusEntries.decode(good + Data([0xFF]))
        }
        // Not even partly decoded: the strict rule gives nothing back.
        #expect(throws: (any Error).self) { try SonyStatusEntries.decode(Fixtures.cc09ReadWiFiOff + Data([0x00, 0x00])) }
    }

    @Test func everyCutOfAReadIsEitherABoundaryOrAnError() throws {
        let read = [UInt8](Fixtures.cc09ReadWiFiOff)
        let boundaries: Set<Int> = [5, 9, 13, 19, 23, 27, 31, 35, 39, 43]
        for cut in 1 ... read.count {
            let prefix = Data(read[..<cut])
            if boundaries.contains(cut) {
                #expect(try SonyStatusEntries.decode(prefix).count == boundaries.filter { $0 <= cut }.count, "cut \(cut)")
            } else {
                #expect(throws: (any Error).self, "cut \(cut)") { try SonyStatusEntries.decode(prefix) }
            }
        }
    }

    @Test func errorsDescribeThemselves() {
        #expect(SonyStatusError.empty.description == "status value is empty")
        #expect(SonyStatusError.lengthTooShort(offset: 5, length: 0).description.contains("byte 5"))
        #expect(SonyStatusError.truncated(offset: 2, length: 9, available: 3).description.contains("only 3"))
    }

    // MARK: Tags and masking

    @Test func tagsHaveTheNotesNames() {
        #expect(SonyStatusTag.wifiStatus.name == "Wi-Fi status")
        #expect(SonyStatusTag.remoteControlAvailable.name == "remote control available")
        #expect(SonyStatusTag(rawValue: 0x0004).name == nil)
        #expect(SonyStatusTag(rawValue: 0x0006).name == nil)
        #expect(SonyStatusTag(rawValue: 0xBEEF).name == nil)
        #expect(SonyStatusTag.wifiStatus.description == "0x0001 (Wi-Fi status)")
        #expect(SonyStatusTag(rawValue: 0x0004).description == "0x0004")
        #expect(SonyStatusTag(rawValue: 0xBEEF).description == "0xBEEF")
        let named: [SonyStatusTag] = [.wifiStatus, .imageTransferAvailable, .remoteControlAvailable, .timeSet, .liveStreaming,
                                      .movieRecording, .streamingMode, .backgroundTransferAvailable]
        #expect(named.map(\.rawValue) == [1, 2, 3, 5, 7, 8, 9, 10])
        #expect(named.allSatisfy { $0.name != nil })
    }

    @Test func entriesPrintMasked() {
        #expect(SonyStatusEntry(tag: .wifiStatus, value: [0x02, 0x00]).description == "0x0001 (Wi-Fi status) = 02 00")
        #expect(SonyStatusEntry(tag: SonyStatusTag(rawValue: 4), value: [0x41, 0x42, 0x01]).description == "0x0004 = ·· ·· 01")
        #expect(SonyStatusEntry(tag: .timeSet, value: []).description == "0x0005 (time set) = 0 B")
    }

    @Test func maskingHidesBytesAboveF() {
        #expect(SonyMasking.maskedHex([]) == "0 B")
        #expect(SonyMasking.maskedHex([0x00, 0x01, 0x0F, 0x10, 0xFF]) == "00 01 0F ·· ··")
        #expect(SonyMasking.maskedHex([UInt8](repeating: 0x0A, count: 64)).hasSuffix("0A"))
        let long = SonyMasking.maskedHex([UInt8](repeating: 0x41, count: 65))
        #expect(long.hasSuffix("… (65 B)"))
        #expect(!long.contains("41"))
        for b in UInt8.min ... UInt8.max {
            #expect(SonyMasking.maskedByte(b) == (b <= 0x0F ? (b < 0x10 ? "0" : "") + String(b, radix: 16, uppercase: true) : "··"))
        }
    }
}
