import CameraTransport
import Foundation
import Testing
@testable import AppUI

@Suite("Browse grid layout")
struct CardLayoutTests {
    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func daysNewestFirstThenUndated() {
        let day: TimeInterval = 86_400
        let items = [
            item("A.ARW", at: 0),
            item("B.JPG", at: day + 60),
            item("C.ARW", at: nil),
            item("D.HIF", at: day + 120),
            item("E.JPG", at: 30),
        ]
        let sections = CardLayout.sections(items, calendar: utc)
        #expect(sections.map { $0.items.map(\.name) } == [["D.HIF", "B.JPG"], ["E.JPG", "A.ARW"], ["C.ARW"]])
        #expect(sections.last?.day == nil)
        #expect(sections.last?.id == "undated")
        #expect(sections[0].day == utc.startOfDay(for: items[1].captureDate!))
        #expect(Set(sections.map(\.id)).count == sections.count)
        // 1_793_000_000 is 2026-10-26 (UTC), the fakes' base instant.
        #expect(sections[1].id == "2026-10-26")
    }

    @Test func emptyCardHasNoSections() {
        #expect(CardLayout.sections([], calendar: utc).isEmpty)
    }

    @Test func kindsAndBadges() {
        #expect(CardLayout.kind(of: item("A.ARW")) == .photo(badge: "RAW"))
        #expect(CardLayout.kind(of: item("A.HIF")) == .photo(badge: "HEIF"))
        #expect(CardLayout.kind(of: item("A.JPG")) == .photo(badge: nil))
        #expect(CardLayout.kind(of: item("C0001.MP4")) == .video)
        #expect(CardLayout.kind(of: item("C0001M01.XML")) == .other)
        #expect(CardLayout.kind(of: item("A.JPG")).offersJPEGActions)
        #expect(!CardLayout.kind(of: item("C0001.MP4")).offersJPEGActions)
        #expect(!CardLayout.kind(of: item("C0001M01.XML")).offersJPEGActions)
    }
}
