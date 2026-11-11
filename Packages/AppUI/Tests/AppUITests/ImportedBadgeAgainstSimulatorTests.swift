import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPSimulator
import SimulatedLink
import Testing
@testable import AppUI

// The Imported badge after the 17.1 bench run (8 Nov): files imported in MTP weren't badged in MTP, and files
// imported in MSC weren't badged in MTP. Shamil's rule of 8 Nov: a file already imported is recognised by its name,
// capture time (to the second) and size, whatever the USB mode, the camera key or the folder.

/// Key material as an MTP link gives it (the device's UUID string on the bench); made up, no real device's.
let benchKeyMaterial = "00000000-0000-0000-0000-00000000c0de"

@MainActor
@Suite("The Imported badge against the simulated camera", .serialized, .timeLimit(.minutes(5)))
struct ImportedBadgeAgainstSimulatorTests {
    /// The bench's q-mtp-browse: in MTP (keyed by the link's material, as the app does, and with no folder, as
    /// ImageCaptureCore gave on 1 Nov), import to Photos and stay on Browse. The badges have to come without leaving
    /// Browse and without anyone calling `refreshImportedStates()` or `ImportModel.refresh()`: the test waits on the
    /// engine alone, so the badges arrive only through the app's own chain (the engine's progress, the import model's
    /// watch, its imported updates, Browse).
    @Test func filesImportedInMTPGetTheBadgeWithoutLeavingBrowse() async throws {
        let bench = try await SimulatorBench.make(card: standInCard(folder: ""), setting: .photos,
                                                  keyMaterial: benchKeyMaterial)
        #expect(bench.key.rawValue.hasPrefix("usb-device:"))
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        browse.selectAllNew()
        #expect(Set(browse.selectedItems.map(\.name)) == importableStills)
        #expect(await browse.importSelected() == .started(5))
        try await bench.untilEngine(.finished(.completed))
        await bench.expectInPhotos(importableStills)

        try await bench.until("the badges after the import") { browse.imported.count == 5 }
        #expect(Set(browse.shown.filter(browse.isImported).map(\.name)) == importableStills)
        browse.selectAllNew()
        #expect(browse.selection.isEmpty)
        #expect(await browse.importSelected() == nil)
        #expect(await bench.link.bytesCalls.count == 5)
        await bench.finish()
    }
}

/// Shamil's rule across USB modes and listings, end to end through the app's models. The imports here go to Photos:
/// a staged file isn't imported (Shamil, 11 Nov), so staging would give no Imported badge.
@MainActor
@Suite("Already imported across modes against the simulated camera", .serialized, .timeLimit(.minutes(5)))
struct AlreadyImportedAcrossModesAgainstSimulatorTests {
    /// The camera in MSC, as the bench saw it: named after the card's volume, every file in DCIM/100MSDCF.
    static func mscLink() -> SimulatedCameraLink {
        SimulatedCameraLink(card: standInCard(), mode: .usb(.massStorage), name: "Untitled",
                            descriptorID: "simulated-camera-msc", chunkSize: 4096)
    }

    /// The same camera in MTP: named by the camera, no folders (as ImageCaptureCore gave on 1 Nov).
    static func mtpLink() -> SimulatedCameraLink {
        SimulatedCameraLink(card: standInCard(folder: ""), mode: .usb(.mtp), name: "ILCE-7CM2",
                            descriptorID: "simulated-camera-mtp", chunkSize: 4096)
    }

    @Test func aFileImportedInMSCShowsAsImportedInMTP() async throws {
        let bench = try await SimulatorBench.make(link: Self.mscLink(), setting: .photos,
                                                  keyMaterial: benchKeyMaterial)
        let mscKey = bench.key
        #expect(mscKey.rawValue.hasPrefix("usb-msc-name:"))
        let msc = bench.browse()
        try await bench.until("the card to be listed in MSC") { msc.phase == .listed }
        msc.selectAllNew()
        #expect(await msc.importSelected() == .started(5))
        try await bench.untilImport(.finished(.completed))
        await bench.expectInPhotos(importableStills)
        try await bench.until("the badges in MSC") { msc.imported.count == 5 }
        await bench.stopBrowsing()

        // Switched to MTP: another camera key, no folders. The files show as imported, on the live card.
        try await bench.plug(Self.mtpLink())
        #expect(bench.key.rawValue.hasPrefix("usb-device:"))
        #expect(bench.key != mscKey)
        let mtp = bench.browse()
        try await bench.until("the card to be listed in MTP") { mtp.phase == .listed }
        try await bench.until("the badges in MTP") { mtp.imported.count == 5 }
        #expect(Set(mtp.shown.filter(mtp.isImported).map(\.name)) == importableStills)
        #expect(mtp.shown.allSatisfy { $0.folder.isEmpty })
        mtp.filter.newOnly = true
        #expect(Set(mtp.shown.map(\.name)) == ["C0001.MP4", "DSC00004.ARW"])
        mtp.filter.newOnly = false
        mtp.selectAllNew()
        #expect(mtp.selection.isEmpty)
        #expect(await mtp.importSelected() == nil)
        #expect(await bench.link.bytesCalls.isEmpty)
        // The rows are MSC's: nothing was written under the MTP key.
        #expect(await bench.catalogue.allRecords.count == 5)
        #expect(await bench.catalogue.allRecords.allSatisfy { $0.identity.camera == mscKey })
        await bench.finish()
    }

    @Test func badgesSurviveAnMTPRelistWhoseFoldersDiffer() async throws {
        let bench = try await SimulatorBench.make(card: standInCard(folder: ""), setting: .photos,
                                                  keyMaterial: benchKeyMaterial)
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        browse.selectAllNew()
        #expect(await browse.importSelected() == .started(5))
        try await bench.untilImport(.finished(.completed))
        try await bench.until("the badges after the import") { browse.imported.count == 5 }
        await bench.stopBrowsing()

        // Plugged in again, and this time ImageCaptureCore reports the folders.
        let again = await bench.replug(listing: standInCard())
        await again.holdCatalogue()
        let next = bench.browse()
        try await bench.until("the badges on the last-known card") {
            next.lastKnownListedAt != nil && next.imported.count == 5
        }
        await again.releaseCatalogue()
        try await bench.until("the live card") { next.phase == .listed }
        #expect(next.shown.contains { $0.folder == "DCIM/100MSDCF" })
        #expect(Set(next.shown.filter(next.isImported).map(\.name)) == importableStills)
        // And still after the catalogue has answered for the live card.
        await next.refreshImportedStates()
        #expect(Set(next.shown.filter(next.isImported).map(\.name)) == importableStills)
        next.selectAllNew()
        #expect(next.selection.isEmpty)
        #expect(await again.bytesCalls.isEmpty)
        await bench.finish()
    }

    /// Build 17.1 matched per camera, so a file imported twice has two rows. It counts once: the badge shows and
    /// nothing is imported a third time. Neither row is under the key and folder Browse asks for (the MSC key, and
    /// another MTP device's key, both in DCIM/100MSDCF), so only matching by content can give the badges.
    @Test func aFileImportedTwiceBy17_1CountsOnce() async throws {
        let bench = try await SimulatorBench.make(card: standInCard(folder: ""), setting: .photos,
                                                  keyMaterial: benchKeyMaterial)
        let mscKey = CameraKeys.key(for: Self.mscLink().descriptor, material: nil)
        let otherDeviceKey = CameraKeys.key(for: Self.mtpLink().descriptor,
                                            material: "00000000-0000-0000-0000-0000000000ff")
        #expect(otherDeviceKey != bench.key && mscKey != bench.key)
        for object in await bench.link.card.objects {
            guard let date = CaptureDate(rawValue: object.captureDateRaw) else { continue }
            for (camera, folder) in [(mscKey, "DCIM/100MSDCF"), (otherDeviceKey, "DCIM/100MSDCF")] {
                let identity = ObjectIdentity(camera: camera, folder: folder, filename: object.filename,
                                              captureDate: date, size: object.size)
                await bench.catalogue.upsert(CatalogueRecord(identity: identity, format: .other, state: .imported))
            }
        }
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        try await bench.until("the badges") { browse.imported.count == importableStills.count + 1 }   // and the clip
        #expect(Set(browse.shown.filter(browse.isImported).map(\.name)) == importableStills.union(["C0001.MP4"]))
        browse.selectAllNew()
        #expect(browse.selection.isEmpty)
        #expect(await browse.importSelected() == nil)
        #expect(await bench.link.bytesCalls.isEmpty)
        #expect(await bench.catalogue.allRecords.count == 12)
        #expect(await bench.catalogue.allRecords.allSatisfy { $0.identity.camera != bench.key })
        await bench.finish()
    }

    /// The bench log names what the fixed build needs to tell causes apart, and no key: each file imported with the
    /// identity its row went under, each badge read and why, and each listing with its newest files.
    @Test func theBenchLogTellsWhyABadgeShowsWithoutNamingTheKey() async throws {
        let bench = try await SimulatorBench.make(card: standInCard(folder: ""), setting: .photos,
                                                  keyMaterial: benchKeyMaterial)
        let browse = bench.browse()
        try await bench.until("the card to be listed") { browse.phase == .listed }
        browse.selectAllNew()
        #expect(await browse.importSelected() == .started(5))
        try await bench.untilImport(.finished(.completed))
        try await bench.until("the badges after the import") { browse.imported.count == 5 }
        let lines = bench.log.lines
        let tag = CameraKeyTags.shared.tag(for: bench.key)
        #expect(tag.hasSuffix(" (usb-device)"))
        #expect(lines.contains { $0.hasPrefix("browse: listed 7 files in ")
            && $0.contains("key \(tag), 7 with no folder") && $0.contains("newest: DSC00005.HIF 20261102T100010 12000 B, C0001.MP4 20261102T100005 300000 B, "
                + "DSC00003.JPG 20261102T100000 22000 B") })
        #expect(lines.contains(
            "import: imported DSC00005.HIF 20261102T100010 12000 B folder \"\" key \(tag) → Photos"))
        #expect(lines.contains("import: job ended completed: 5 imported, key \(tag)"))
        #expect(lines.contains { $0.hasPrefix("browse: badges refreshed after import (rev ")
            && $0.hasSuffix("): 7 shown, 6 dated, 5 imported, key \(tag)") })
        // No key, no hash of one, no material.
        let hash = String(bench.key.rawValue.drop { $0 != ":" }.dropFirst())
        for line in lines {
            #expect(!line.contains(hash.prefix(8)), "\(line)")
            #expect(!line.contains(benchKeyMaterial), "\(line)")
        }
        await bench.finish()
    }
}
