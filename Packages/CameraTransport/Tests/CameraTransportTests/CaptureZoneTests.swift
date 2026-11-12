import Foundation
import PTPKit
import Testing
@testable import CameraTransport

/// Each listed item carries the zone its capture date was made in (backlog Iteration 2, section 1, I14), so the
/// camera's own wall-clock reading can be had back however far the phone has travelled since.
@Suite("The capture time's zone on listed items")
struct CaptureZoneTests {
    static let london = TimeZone(identifier: "Europe/London")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// The wall-clock fields of `date` read in `zone`.
    static func wallClock(_ date: Date?, in zone: TimeZone?) -> DateComponents? {
        guard let date, let zone else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    static let nineAM = DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 0, second: 0)

    @Test func aZonelessStringIsMadeInTheGivenZone() throws {
        let capture = try #require(CameraItem.captureTime(ptpDateTime: "20261101T090000", defaultTimeZone: Self.tokyo))
        #expect(capture.date == PTPDateTime.parse("20261101T090000", defaultTimeZone: Self.tokyo))
        #expect(capture.zone == Self.tokyo)
        #expect(Self.wallClock(capture.date, in: capture.zone) == Self.nineAM)
    }

    @Test func aStringThatNamesItsZoneKeepsThatZone() throws {
        for (raw, offset) in [("20261101T090000Z", 0), ("20261101T090000+0900", 9 * 3600),
                              ("20261101T090000.5-0130", -(3600 + 1800)), ("20261101T090000.+0100", 3600)] {
            let capture = try #require(CameraItem.captureTime(ptpDateTime: raw, defaultTimeZone: Self.london),
                                       "\(raw)")
            #expect(capture.date == PTPDateTime.parse(raw, defaultTimeZone: Self.london), "\(raw)")
            #expect(capture.zone.secondsFromGMT(for: capture.date) == offset, "\(raw)")
            // Read back in its own zone, the date is the string's wall-clock part (`CaptureDate(ptpDateTime:)`).
            #expect(Self.wallClock(capture.date, in: capture.zone) == Self.nineAM, "\(raw)")
        }
    }

    @Test func anUnreadableStringHasNoCaptureTime() {
        for raw in ["", "20261101", "2026-11-01T09:00:00", "20261101T0900xx"] {
            #expect(CameraItem.captureTime(ptpDateTime: raw, defaultTimeZone: Self.london) == nil, "\(raw)")
        }
    }

    @Test func theAutoupdatingZoneIsFixedOnTheItem() {
        var item = CameraItem(id: .init(rawValue: "a"), folder: "DCIM", name: "A.JPG", size: 1, captureDate: Date(),
                              captureTimeZone: .autoupdatingCurrent)
        // An autoupdating zone equals only another autoupdating one.
        #expect(item.captureTimeZone != TimeZone.autoupdatingCurrent)
        #expect(item.captureTimeZone?.identifier == TimeZone.autoupdatingCurrent.identifier)
        item.captureTimeZone = .autoupdatingCurrent
        #expect(item.captureTimeZone != TimeZone.autoupdatingCurrent)
        item.captureTimeZone = Self.tokyo
        #expect(item.captureTimeZone == Self.tokyo)
        #expect(CameraItem(id: .init(rawValue: "b"), folder: "", name: "B.JPG", size: 1, captureDate: nil)
            .captureTimeZone == nil)
    }

    private func info(_ name: String, date: String) -> PTPObjectInfo {
        PTPObjectInfo(storageID: PTPStorageID(rawValue: 0x0001_0001), objectFormat: .exifJPEG, protectionStatus: 0,
                      objectCompressedSize: 100, thumbFormat: .undefined, thumbCompressedSize: 0, thumbPixWidth: 0,
                      thumbPixHeight: 0, imagePixWidth: 0, imagePixHeight: 0, imageBitDepth: 0,
                      parentObject: PTPObjectHandle(rawValue: 0), associationType: 0, associationDescription: 0,
                      sequenceNumber: 0, filename: name, captureDateRaw: date, modificationDateRaw: "", keywords: "")
    }

    @Test func theIPListingRecordsTheZoneItReadTheCardIn() throws {
        let handle = PTPObjectHandle(rawValue: 0x4000_10A3)
        let london = try #require(IPListing.item(handle: handle, info: info("DSC1.JPG", date: "20261101T090000"),
                                                 folders: [:], timeZone: Self.london))
        let tokyo = try #require(IPListing.item(handle: handle, info: info("DSC1.JPG", date: "20261101T090000"),
                                                folders: [:], timeZone: Self.tokyo))
        #expect(london.captureTimeZone == Self.london && tokyo.captureTimeZone == Self.tokyo)
        // Nine hours apart as instants, the same reading of the camera's clock.
        let london9 = try #require(london.captureDate), tokyo9 = try #require(tokyo.captureDate)
        #expect(london9.timeIntervalSince(tokyo9) == TimeInterval(9 * 3600))
        #expect(Self.wallClock(london.captureDate, in: london.captureTimeZone) == Self.nineAM)
        #expect(Self.wallClock(tokyo.captureDate, in: tokyo.captureTimeZone) == Self.nineAM)
        // A file with no date has no zone either.
        let undated = try #require(IPListing.item(handle: handle, info: info("DSC2.JPG", date: ""), folders: [:],
                                                  timeZone: Self.london))
        #expect(undated.captureDate == nil && undated.captureTimeZone == nil)
    }

    @Test func anItemKeptByARelistKeepsTheZoneItWasMadeIn() throws {
        let handle = PTPObjectHandle(rawValue: 0x4000_10A3)
        let known = try #require(IPListing.item(handle: handle, info: info("DSC1.JPG", date: "20261101T090000"),
                                                folders: [:], timeZone: Self.london))
        let (kept, unseen) = IPListing.reuse([known], listed: [handle])
        #expect(unseen.isEmpty)
        #expect(kept[handle]?.captureTimeZone == Self.london)
    }

    @Test func theUSBListingPassesOnTheCataloguesZone() throws {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entry = USBCatalogueEntry(id: .init(rawValue: "usb-1"), ancestorsNearestFirst: ["100MSDCF", "DCIM"],
                                      name: "DSC04512.ARW", fileSize: 10, creationDate: date,
                                      creationTimeZone: Self.tokyo)
        #expect(USBListing.item(from: entry)?.captureTimeZone == Self.tokyo)
        var undated = entry
        undated.creationDate = nil
        #expect(USBListing.item(from: undated)?.captureTimeZone == nil)
        var unknown = entry
        unknown.creationTimeZone = nil
        #expect(USBListing.item(from: unknown)?.captureTimeZone == nil)
        #expect(USBListing.item(from: unknown)?.captureDate == date)
    }

    @Test func aStagedEntryPassesItsZoneToItsItem() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("never-read-\(UUID().uuidString)")
        let entries = [
            StagedEntry(folder: "DCIM", name: "A.JPG", captureDate: date, size: 1, url: url,
                        captureTimeZone: Self.tokyo),
            StagedEntry(folder: "DCIM", name: "B.JPG", captureDate: date, size: 1, url: url),
        ]
        let link = StagingFolderLink(descriptor: CameraDescriptor(id: .init(rawValue: "s"), name: "Staging",
                                                                  mode: .wifi(.otherNetwork)),
                                     entries: entries)
        let items = try await link.list()
        #expect(items.first { $0.name == "A.JPG" }?.captureTimeZone == Self.tokyo)
        #expect(items.first { $0.name == "B.JPG" }?.captureTimeZone == nil)
    }
}
