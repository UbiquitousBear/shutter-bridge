import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Shamil's rule of 8 Nov in the engine: a file already imported is recognised by its name, capture time (to the
/// second) and size, whatever the camera key or the folder, and within a job a file is found again on a listing by
/// the same rule, so a listing that reports another folder neither skips it nor adds it twice.
@Suite("Matching files by content", .timeLimit(.minutes(1)))
struct ContentMatchTests {
    static let mscCamera = CameraKey(rawValue: "usb-msc-name:hashed-volume-name")

    /// A row for `item` as an import in MSC wrote it: another camera key, the card's folder.
    static func importedInMSC(_ h: Harness, _ item: CameraItem) -> CatalogueRecord {
        var identity = h.identity(of: item)
        identity.camera = mscCamera
        identity.folder = "DCIM/100MSDCF"
        return CatalogueRecord(identity: identity, format: item.format, state: .imported,
                               location: .file(relativePath: "Untitled/\(item.name)"))
    }

    /// Files as an MTP link lists them on the bench: no folder.
    static func unfiled(_ items: [CameraItem]) -> [CameraItem] {
        items.map { item in
            var item = item
            item.folder = ""
            return item
        }
    }

    @Test func allNewSkipsAFileImportedUnderAnotherCameraAndFolder() async throws {
        let probe = Harness()
        let card = Self.unfiled(probe.singles(["A.JPG", "B.JPG", "C.JPG"]))
        let row = Self.importedInMSC(probe, card[1])
        await probe.cleanup()
        let h = Harness(catalogue: InMemoryCatalogue(records: [row]))
        let link = h.link(card, mode: .usb(.mtp))
        try await h.start(.allNew, from: link, to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["C.JPG", "A.JPG"])
        #expect(await h.engine.currentProgress.filesTotal == 2)
        // The MSC row is left as it was, and no MTP row is written for that file.
        #expect(try await h.catalogue.record(for: row.identity) == row)
        #expect(await h.record(for: card[1]) == nil)
        #expect(await h.records().count == 3)
        await h.cleanup()
    }

    @Test func pickedFilesImportedUnderAnotherCameraAreLeftOut() async throws {
        let probe = Harness()
        let card = Self.unfiled(probe.singles(["A.JPG", "B.JPG"]))
        let row = Self.importedInMSC(probe, card[0])
        await probe.cleanup()
        let h = Harness(catalogue: InMemoryCatalogue(records: [row]))
        let link = h.link(card, mode: .usb(.mtp))
        try await h.start(.items(card), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["B.JPG"])
        #expect(await h.engine.currentProgress.filesTotal == 1)
        await h.cleanup()
    }

    @Test func appendSkipsAFileImportedUnderAnotherCamera() async throws {
        let probe = Harness()
        let card = Self.unfiled(probe.singles(["A.JPG", "B.JPG", "C.JPG"]))
        let row = Self.importedInMSC(probe, card[2])
        await probe.cleanup()
        let h = Harness(catalogue: InMemoryCatalogue(records: [row]))
        let link = h.link(card, mode: .usb(.mtp))
        await link.script("A.JPG", .hold)
        try await h.start(.items([card[0]]), from: link)
        let a = await link.nextHeldCall("A.JPG")
        #expect(try await h.engine.append([card[2]]) == 0)
        #expect(try await h.engine.append([card[1], card[2]]) == 1)
        a.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "B.JPG"])
        await h.cleanup()
    }

    @Test func appendDoesNotAddAFileAlreadyInTheJobUnderAnotherFolder() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        await link.script("A.JPG", .hold)
        try await h.start(.items(card), from: link)
        let a = await link.nextHeldCall("A.JPG")
        // The same two files as another listing reports them, without their folder.
        #expect(try await h.engine.append(Self.unfiled(card)) == 0)
        #expect(await h.engine.currentProgress.filesTotal == 2)
        a.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "B.JPG"])
        #expect(await h.records().count == 2)
        await h.cleanup()
    }

    /// Browse's pick and the engine's own listing come from two ImageCaptureCore catalogues; if they report a file's
    /// folder differently, the pick is still found (and its row written under the pick's identity).
    @Test func aPickIsFoundOnTheEngineListingWhateverItsFolder() async throws {
        let h = Harness()
        let picked = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(Self.unfiled(h.singles(["A.JPG", "B.JPG"], prefix: "s2")), mode: .usb(.mtp))
        try await h.start(.items(picked), from: link, to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls == ["A.JPG", "B.JPG"])
        let p = await h.engine.currentProgress
        #expect(p.filesDone == 2 && p.filesSkipped == 0)
        await h.cleanup()
    }

    @Test func theRowKeepsTheJobsKeyAndThePicksFolder() async throws {
        let h = Harness()
        let picked = h.singles(["A.JPG"])
        let link = h.link(Self.unfiled(h.singles(["A.JPG"], prefix: "s2")), mode: .usb(.mtp))
        try await h.start(.items(picked), from: link, to: h.stageRoute)
        #expect(await h.waitFinished() == .completed)
        let rows = await h.records()
        #expect(rows.count == 1)
        #expect(rows.first?.identity == h.identity(of: picked[0]))
        #expect(rows.first?.identity.camera == h.camera)
        #expect(rows.first?.identity.folder == "DCIM/100MSDCF")
        await h.cleanup()
    }

    /// A replug whose listing reports the files in another folder (or none): the files left are remapped to their new
    /// handles, not skipped as "no longer on the card".
    @Test func aReplugThatListsTheFolderDifferentlyStillFindsTheFiles() async throws {
        let h = Harness()
        let card1 = h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s1")
        let link1 = h.link(card1, mode: .usb(.mtp))
        await link1.script("B.JPG", .hold)
        try await h.start(.items(card1), from: link1)
        let b = await link1.nextHeldCall("B.JPG")
        link1.send(.removed)
        await h.trace.next(.paused(.cameraRemoved))
        b.release(.fail(.disconnected))

        let link2 = h.link(Self.unfiled(h.singles(["A.JPG", "B.JPG", "C.JPG"], prefix: "s2")), mode: .usb(.mtp))
        try await h.engine.reconnect(link2)
        #expect(await h.waitFinished() == .completed)
        #expect(await link2.bytesCalls == ["B.JPG", "C.JPG"])
        let p = await h.engine.currentProgress
        #expect(p.filesSkipped == 0)
        #expect(p.filesDone == 3)
        // Each row keeps the identity the job picked it under.
        #expect(Set(await h.records().map(\.identity)) == Set(card1.map(h.identity(of:))))
        await h.cleanup()
    }

    @Test func aListingWithOneFileInTwoFoldersQueuesItOnce() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card + Self.unfiled(h.singles(["A.JPG"], prefix: "s1x")))
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls.sorted() == ["A.JPG", "B.JPG"])
        // The second copy isn't dropped silently.
        #expect(h.trace.count { $0 == .sameFileListedTwice("A.JPG") } == 1)
        await h.cleanup()
    }

    @Test func aPickOfOneFileInTwoFoldersImportsItOnceAndSaysSo() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let copy = Self.unfiled(h.singles(["A.JPG"], prefix: "s1x"))
        let link = h.link(card + copy)
        try await h.start(.items([card[0], copy[0], card[1]]), from: link)
        #expect(await h.waitFinished() == .completed)
        #expect(await link.bytesCalls.sorted() == ["A.JPG", "B.JPG"])
        #expect(await h.engine.currentProgress.filesTotal == 2)
        #expect(h.trace.count { $0 == .sameFileListedTwice("A.JPG") } == 1)
        await h.cleanup()
    }
}
