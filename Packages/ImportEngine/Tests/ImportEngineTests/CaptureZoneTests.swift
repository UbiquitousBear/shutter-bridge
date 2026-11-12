import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Section 1's remaining identity items (I14): a file's identity reads its capture time in the zone the link made it
/// in, so a relisting with the phone 9 hours away still matches the catalogue; and files without a capture date are
/// left out and counted (D10).
@Suite("The capture time's zone and files without a capture date", .timeLimit(.minutes(1)))
struct CaptureZoneTests {
    static let london = TimeZone(identifier: "Europe/London")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// One file as a link lists it with the phone in `zone`: the camera's `wallClock` made into a date in `zone`,
    /// which the item records.
    static func listed(_ name: String, at wallClock: String, size: UInt64, in zone: TimeZone, prefix: String,
                       recordsZone: Bool = true) throws -> CameraItem {
        let capture = try #require(CameraItem.captureTime(ptpDateTime: wallClock, defaultTimeZone: zone))
        return CameraItem(id: .init(rawValue: "\(prefix)-\(name)"), folder: "DCIM/100MSDCF", name: name, size: size,
                          captureDate: capture.date, captureTimeZone: recordsZone ? capture.zone : nil)
    }

    /// A RAW+JPEG pair and a lone JPEG, listed with the phone in `zone`.
    static func card(in zone: TimeZone, prefix: String, recordsZone: Bool = true) throws -> [CameraItem] {
        [
            try listed("DSC00001.ARW", at: "20261101T090000", size: 4000, in: zone, prefix: prefix,
                       recordsZone: recordsZone),
            try listed("DSC00001.JPG", at: "20261101T090000", size: 2000, in: zone, prefix: prefix,
                       recordsZone: recordsZone),
            try listed("DSC00002.JPG", at: "20261101T090002", size: 2100, in: zone, prefix: prefix,
                       recordsZone: recordsZone),
        ]
    }

    @Test func theIdentityReadsTheItemsOwnZoneBeforeTheReaders() throws {
        let camera = CameraKey(rawValue: "k")
        let utc = try #require(TimeZone(identifier: "UTC"))
        let tokyo = try Self.listed("DSC00001.ARW", at: "20261101T090000", size: 10, in: Self.tokyo, prefix: "t")
        // Read anywhere, the identity is the camera's own reading.
        for reader in [utc, Self.london, Self.tokyo] {
            #expect(tokyo.identity(camera: camera, timeZone: reader)?.captureDate.rawValue == "20261101T090000")
        }
        // Without the zone the reader's is used, as before I14: 9 hours off when the reader is in UTC.
        var zoneless = tokyo
        zoneless.captureTimeZone = nil
        #expect(zoneless.identity(camera: camera, timeZone: utc)?.captureDate.rawValue == "20261101T000000")
        #expect(zoneless.identity(camera: camera, timeZone: Self.tokyo)?.captureDate.rawValue == "20261101T090000")
    }

    @Test func aCardListedInLondonAndRelisted9HoursEastHasNothingNew() async throws {
        let h = Harness()   // the engine reads in UTC
        let inLondon = try Self.card(in: Self.london, prefix: "s1")
        try await h.start(.allNew, from: h.link(inLondon))
        #expect(await h.waitFinished() == .completed)
        let rows = await h.records()
        #expect(rows.count == 3 && rows.allSatisfy { $0.state == .imported })
        #expect(Set(rows.map(\.identity.captureDate.rawValue)) == ["20261101T090000", "20261101T090002"])

        // After the flight: the same card, its dates now made 9 hours east.
        let inTokyo = try Self.card(in: Self.tokyo, prefix: "s2")
        #expect(zip(inLondon, inTokyo).allSatisfy { a, b in
            guard let london = a.captureDate, let tokyo = b.captureDate else { return false }
            return london.timeIntervalSince(tokyo) == TimeInterval(9 * 3600)
        })
        // Browse's diff and the engine's pick both read the catalogue by these identities.
        #expect(try await h.engine.picksToDo(.newItems(inTokyo), camera: h.camera, for: h.photosRoute).isEmpty)
        let mark = h.trace.count
        let relisting = h.link(inTokyo)
        try await h.start(.allNew, from: relisting)
        #expect(await h.waitFinished(after: mark) == .completed)
        #expect(await relisting.bytesCalls.isEmpty)
        #expect(await h.records().count == 3)
        let progress = await h.engine.currentProgress
        #expect(progress.filesTotal == 0 && progress.filesUndated == 0)

        // What the zone is for: without it the relisting reads 9 hours off in the engine's zone and is all new.
        let zoneless = try Self.card(in: Self.tokyo, prefix: "s3", recordsZone: false)
        #expect(try await h.engine.picksToDo(.newItems(zoneless), camera: h.camera, for: h.photosRoute).count == 3)
        await h.cleanup()
    }

    @Test func anEngineThatHasMovedZoneStillMatchesAListingMadeBeforeTheMove() async throws {
        let h = Harness()
        let inLondon = try Self.card(in: Self.london, prefix: "s1")
        try await h.start(.allNew, from: h.link(inLondon))
        #expect(await h.waitFinished() == .completed)
        // The phone is now in Tokyo; the items are the ones listed in London (an IP relist keeps them).
        let moved = ImportEngine(catalogue: h.catalogue,
                                 stagingDirectory: h.root.appendingPathComponent("moved", isDirectory: true),
                                 timeZone: Self.tokyo)
        #expect(try await moved.picksToDo(.newItems(inLondon), camera: h.camera, for: h.photosRoute).isEmpty)
        await h.cleanup()
    }

    @Test func aWholeCardLeavesOutUndatedStillsAndCountsThem() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let undated = [h.item("X.JPG", size: 500, date: nil), h.item("Y.ARW", size: 700, date: nil)]
        let clip = h.item("C0001.MP4", size: 9000, date: nil)
        try await h.start(.allNew, from: h.link(card + undated + [clip]))
        #expect(await h.waitFinished() == .completed)
        let progress = await h.engine.currentProgress
        #expect(progress.filesUndated == 2)
        #expect(progress.filesSkipped == 2)
        #expect(progress.filesImported == 2)
        #expect(progress.filesTotal == 4)   // the clip is left out unsaid, as Browse never offers it
        let files = await h.engine.currentFiles
        #expect(Set(files.filter { $0.phase == .skipped(.noCaptureDate) }.map(\.item.name)) == ["X.JPG", "Y.ARW"])
        #expect(h.trace.log.contains(.skipped("X.JPG", .noCaptureDate)))
        #expect(h.trace.log.contains(.skipped("Y.ARW", .noCaptureDate)))
        #expect(await h.records().count == 2)   // no row: nothing to key one by
        await h.cleanup()
    }

    @Test func aDateRangeLeavesOutUndatedStillsUnsaid() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let range = Harness.t0.addingTimeInterval(-60) ... Harness.t0.addingTimeInterval(60)
        try await h.start(.dateRange(range), from: h.link(card + [h.item("X.JPG", size: 500, date: nil)]))
        #expect(await h.waitFinished() == .completed)
        let progress = await h.engine.currentProgress
        #expect(progress.filesUndated == 0 && progress.filesSkipped == 0 && progress.filesTotal == 1)
        await h.cleanup()
    }

    @Test func undatedStillsHandedOverWithTheNewOnesAreCountedOnce() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let x = h.item("X.JPG", size: 500, date: nil)
        let link = h.link(card + [x])
        await link.script("A.JPG", .hold)
        // *Select All New* hands the undated still over with the new ones; the job leaves it out and counts it.
        try await h.start(.newItems([card[0], x, x]), from: link)
        let held = await link.nextHeldCall("A.JPG")
        #expect(await h.engine.currentProgress.filesUndated == 1)
        // Handed over again while the job runs: still one, and it isn't counted as added.
        #expect(try await h.engine.append([card[1], x], newOnly: true) == 1)
        #expect(await h.engine.currentProgress.filesUndated == 1)
        // A still the job hasn't seen is counted; a video without a date isn't.
        let y = h.item("Y.ARW", size: 700, date: nil)
        #expect(try await h.engine.append([y, h.item("C0001.MP4", size: 9000, date: nil)], newOnly: true) == 0)
        #expect(await h.engine.currentProgress.filesUndated == 2)
        held.release()
        #expect(await h.waitFinished() == .completed)
        let progress = await h.engine.currentProgress
        #expect(progress.filesUndated == 2 && progress.filesSkipped == 2 && progress.filesImported == 2)
        #expect(await h.engine.currentFiles.filter { $0.phase == .skipped(.noCaptureDate) }.map(\.item.name)
            == ["X.JPG", "Y.ARW"])
        // The job's record matches its last progress (I9).
        await h.engine.settleJobRecords()
        let records = try await h.catalogue.jobs(camera: nil)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.filesTotal == progress.filesTotal && record.filesSkipped == progress.filesSkipped
            && record.filesImported == progress.filesImported && record.bytesTotal == progress.bytesTotal)
        await h.cleanup()
    }
}
