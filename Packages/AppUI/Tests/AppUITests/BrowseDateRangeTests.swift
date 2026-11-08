import Foundation
import Testing
@testable import AppUI

@Suite("Browse: the date filter's whole days")
struct BrowseDateRangeTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 5 Nov 2026 00:00 UTC, plus `seconds`.
    func at(_ seconds: TimeInterval, day: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_793_836_800 + Double(day) * 86_400 + seconds)
    }

    @Test func aRangeCoversWholeDays() {
        let range = BrowseFilter.days(from: at(13 * 3600), through: at(9 * 3600, day: 2), calendar: calendar)
        #expect(range.lowerBound == at(0))
        #expect(range.contains(at(0)))
        #expect(range.contains(at(86_399, day: 2)))
        #expect(!range.contains(at(0, day: 3)))
        #expect(!range.contains(at(-1)))
    }

    @Test func daysInTheWrongOrderAreSwapped() {
        let range = BrowseFilter.days(from: at(10, day: 2), through: at(10), calendar: calendar)
        #expect(range.lowerBound == at(0))
        #expect(range.contains(at(86_000, day: 2)))
    }

    @Test func oneDayIsAValidRange() {
        let range = BrowseFilter.days(from: at(5), through: at(5), calendar: calendar)
        #expect(range.contains(at(0)) && range.contains(at(86_399)))
        #expect(!range.contains(at(0, day: 1)))
    }

    @Test func movingTheFirstDayPastTheLastMovesTheLastToo() throws {
        let bounds = at(0) ... at(0, day: 5)
        var filter = BrowseFilter()
        filter.limitDates(from: at(0), to: at(0, day: 1), calendar: calendar)
        filter.setFirstDay(at(100, day: 3), bounds: bounds, calendar: calendar)
        let range = try #require(filter.dateRange)
        #expect(range.lowerBound == at(0, day: 3))
        #expect(range.contains(at(86_399, day: 3)) && !range.contains(at(0, day: 4)))
    }

    @Test func movingTheLastDayBeforeTheFirstMovesTheFirstToo() throws {
        let bounds = at(0) ... at(0, day: 5)
        var filter = BrowseFilter()
        filter.limitDates(from: at(0, day: 3), to: at(0, day: 4), calendar: calendar)
        filter.setLastDay(at(100, day: 1), bounds: bounds, calendar: calendar)
        let range = try #require(filter.dateRange)
        #expect(range.lowerBound == at(0, day: 1))
        #expect(!range.contains(at(0, day: 2)))
    }

    @Test func settingADayWithNoRangeStartsFromTheCardsBounds() throws {
        let bounds = at(0) ... at(0, day: 5)
        var filter = BrowseFilter()
        filter.setLastDay(at(10, day: 2), bounds: bounds, calendar: calendar)
        let range = try #require(filter.dateRange)
        #expect(range.lowerBound == at(0))
        #expect(!range.contains(at(0, day: 3)))
        #expect(filter.isActive)
    }
}
