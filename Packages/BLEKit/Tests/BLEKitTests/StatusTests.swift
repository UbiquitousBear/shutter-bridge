import Testing
import Foundation
@testable import BLEKit

@Suite("CC09's merged state and the Wi-Fi status")
struct StatusTests {
    @Test func aReadGivesEveryTag() throws {
        let state = try SonyStatus(decoding: Fixtures.cc09ReadWiFiOff)
        #expect(state.values.count == 10)
        #expect(state.wifiStatus == .terminated)
        #expect(state.remoteControlAvailable == true)
        #expect(state.flag(.imageTransferAvailable) == true)
        #expect(state.flag(.timeSet) == true)
        #expect(state.flag(.backgroundTransferAvailable) == true)
        #expect(state.flag(.liveStreaming) == false)
        #expect(state.flag(.movieRecording) == false)
        #expect(state.flag(.streamingMode) == false)
        // Tag 0x0004 is three bytes and tag 0x0001 two: neither is a one-byte flag.
        #expect(state.value(for: SonyStatusTag(rawValue: 4)) == [0, 0, 0])
        #expect(state.flag(SonyStatusTag(rawValue: 4)) == nil)
        #expect(state.flag(.wifiStatus) == nil)
        #expect(state.value(for: SonyStatusTag(rawValue: 0x0063)) == nil)
    }

    @Test func theWiFiStatusFollowsTheNotifications() throws {
        var state = try SonyStatus(decoding: Fixtures.cc09ReadWiFiOff)
        // CC08 = 0x01: 0 → 1 → 2, then the camera switches it off by itself: 2 → 3 → 0 (all measured on the α7C II).
        var seen: [WiFiStatus] = []
        for value: UInt8 in [1, 2, 3, 0] {
            try state.merge(Fixtures.wifiStatusNotification(value))
            seen.append(try #require(state.wifiStatus))
        }
        #expect(seen == [.launching, .launched, .terminating, .terminated])
        // The other tags kept the values the read gave.
        #expect(state.remoteControlAvailable == true)
        #expect(state.values.count == 10)
    }

    @Test func mergeReportsWhatChanged() throws {
        var state = try SonyStatus(decoding: Fixtures.cc09ReadWiFiOff)
        let changes = try state.merge(Fixtures.wifiStatusNotification(2))
        #expect(changes == [SonyStatusChange(tag: .wifiStatus, old: [0, 0], new: [2, 0])])
        #expect(changes.map(\.description) == ["0x0001 (Wi-Fi status) 00 00 → 02 00"])
        // The same value again changes nothing.
        #expect(try state.merge(Fixtures.wifiStatusNotification(2)).isEmpty)
        // A second read: two tags differ, reported in tag order.
        var second = [UInt8](Fixtures.cc09ReadWiFiOff)
        second[8] = 0   // tag 0x0002's value, 1 → 0
        second[12] = 0  // tag 0x0003's value, 1 → 0
        let more = try state.merge(Data(second))
        #expect(more.map(\.tag.rawValue) == [0x0001, 0x0002, 0x0003])
        #expect(state.remoteControlAvailable == false)
        #expect(state.wifiStatus == .terminated)
    }

    @Test func aNewTagHasNoOldValue() throws {
        var state = SonyStatus()
        #expect(state.isEmpty)
        #expect(state.wifiStatus == nil)
        let changes = try state.merge(Fixtures.cc09ReadWiFiOff)
        #expect(changes.count == 10)
        #expect(changes.allSatisfy { $0.old == nil })
        #expect(changes.first?.description == "0x0001 (Wi-Fi status) = 00 00")
    }

    @Test func aNotificationOfAnotherTagLeavesTheWiFiStatusUnknown() throws {
        let state = try SonyStatus(decoding: Data([0x03, 0x00, 0x03, 0x00]))
        #expect(state.wifiStatus == nil)
        #expect(state.remoteControlAvailable == false)
    }

    @Test func aWiFiStatusEntryWithNoValueIsUnknown() throws {
        let state = try SonyStatus(decoding: Data([0x02, 0x00, 0x01]))
        #expect(state.values[.wifiStatus] == [])
        #expect(state.wifiStatus == nil)
    }

    @Test func valuesOutsideZeroToThreeAreKept() throws {
        let state = try SonyStatus(decoding: Fixtures.wifiStatusNotification(7))
        #expect(state.wifiStatus == .unknown(7))
        #expect(state.wifiStatus?.description == "unknown (07)")
        #expect(try SonyStatus(decoding: Fixtures.wifiStatusNotification(0x41)).wifiStatus?.description == "unknown (··)")
    }

    @Test func wifiStatusNamesAndRawValues() {
        #expect([0, 1, 2, 3].map { WiFiStatus(rawValue: $0).description } == ["terminated", "launching", "launched", "terminating"])
        for raw in UInt8.min ... UInt8.max {
            #expect(WiFiStatus(rawValue: raw).rawValue == raw)
        }
        #expect(WiFiStatus(rawValue: 4) == .unknown(4))
        #expect(WiFiStatus(rawValue: 2) == .launched)
    }

    @Test func flagsAreOnlyZeroOrOneInOneByte() throws {
        var state = SonyStatus()
        state.merge([
            SonyStatusEntry(tag: .timeSet, value: [2]),
            SonyStatusEntry(tag: .liveStreaming, value: [1, 0]),
            SonyStatusEntry(tag: .movieRecording, value: []),
            SonyStatusEntry(tag: .streamingMode, value: [1]),
        ])
        #expect(state.flag(.timeSet) == nil)
        #expect(state.flag(.liveStreaming) == nil)
        #expect(state.flag(.movieRecording) == nil)
        #expect(state.flag(.streamingMode) == true)
        #expect(state.remoteControlAvailable == nil)
    }

    @Test func laterEntriesOfOneValueWin() throws {
        let state = try SonyStatus(decoding: Data([0x03, 0x00, 0x01, 0x01, 0x03, 0x00, 0x01, 0x02]))
        #expect(state.wifiStatus == .launched)
        #expect(state.values.count == 1)
    }

    @Test func aBadValueChangesNothing() throws {
        var state = try SonyStatus(decoding: Fixtures.cc09ReadWiFiOff)
        let before = state
        // A good entry followed by garbage: refused whole, so the good entry isn't merged either.
        let garbage = Data([0x04, 0x00, 0x01, 0x02, 0x00, 0x00])
        #expect(throws: SonyStatusError.lengthTooShort(offset: 5, length: 0)) { try state.merge(garbage) }
        #expect(state == before)
        #expect(state.wifiStatus == .terminated)
        #expect(throws: SonyStatusError.empty) { try state.merge(Data()) }
        #expect(state == before)
        #expect(throws: SonyStatusError.empty) { try SonyStatus(decoding: Data()) }
    }

    @Test func removeAllClearsTheLinksState() throws {
        var state = try SonyStatus(decoding: Fixtures.cc09ReadWiFiOff)
        state.removeAll()
        #expect(state.isEmpty)
        #expect(state == SonyStatus())
        #expect(state.wifiStatus == nil)
    }

    @Test func descriptionIsMasked() throws {
        let state = try SonyStatus(decoding: Fixtures.wifiStatusNotification(2))
        #expect(state.description == "Wi-Fi status launched; 0x0001 (Wi-Fi status) = 02 00")
        #expect(SonyStatus().description == "Wi-Fi status unknown; no entries")
        let odd = SonyStatus(entries: [SonyStatusEntry(tag: SonyStatusTag(rawValue: 4), value: [0x53, 0x4E])])
        #expect(odd.description == "Wi-Fi status unknown; 0x0004 = ·· ··")
    }
}

private extension SonyStatus {
    init(entries: [SonyStatusEntry]) {
        self.init()
        merge(entries)
    }
}
