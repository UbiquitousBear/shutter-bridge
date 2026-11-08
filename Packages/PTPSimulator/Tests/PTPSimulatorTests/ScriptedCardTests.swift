import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

@Suite("Scripted cards")
struct ScriptedCardTests {
    @Test func exitCriteriaCardIsFiftyPairs() throws {
        let card = try #require(ScriptedCard.rawPlusJPEG(pairs: 50))
        #expect(card.objects.count == 100)
        #expect(Set(card.handles).count == 100)
        let infos = card.handles.compactMap(card.objectInfo(for:))
        #expect(infos.filter { $0.mediaKind == .raw }.count == 50)
        #expect(infos.filter { $0.mediaKind == .jpeg }.count == 50)
        // About 3.1 GB, near the backlog's 3.2 GB for 100 files at the measured sizes.
        let total = card.objects.reduce(UInt64(0)) { $0 + $1.size }
        #expect((2_900_000_000 ... 3_300_000_000).contains(total))
    }

    @Test func pairsShareFolderStemAndSecond() throws {
        let card = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusHEIF, .raw]))
        #expect(card.objects.map(\.filename)
                == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.ARW", "DSC00002.HIF", "DSC00003.ARW"])
        let infos = card.handles.compactMap(card.objectInfo(for:))
        #expect(infos[0].pairStem == infos[1].pairStem)
        #expect(infos[0].captureDateRaw == infos[1].captureDateRaw)
        #expect(card.objects[0].folder == card.objects[1].folder)
        #expect(infos[2].captureDateRaw == "20261101T090002")
        #expect(infos[3].mediaKind == .heif)
    }

    @Test func numbersWrapIntoTheNextFolder() throws {
        let card = try #require(ScriptedCard.shoot([.jpeg, .jpeg, .jpeg], start: "20261231T235958", firstNumber: 9998))
        #expect(card.objects.map(\.filename) == ["DSC09998.JPG", "DSC09999.JPG", "DSC00001.JPG"])
        #expect(card.objects.map(\.folder) == ["DCIM/100MSDCF", "DCIM/100MSDCF", "DCIM/101MSDCF"])
        #expect(card.objects.map(\.captureDateRaw) == ["20261231T235958", "20270101T000000", "20270101T000002"])
    }

    @Test func objectInfoRoundTripsThroughPTPKit() throws {
        let card = try #require(ScriptedCard.shoot([.rawPlusJPEG]))
        for h in card.handles {
            let info = try #require(card.objectInfo(for: h))
            #expect(try PTPObjectInfo.decode(info.encode()) == info)
            #expect(info.storageID == ScriptedCard.defaultStorageID)
        }
        #expect(card.objectInfo(for: PTPObjectHandle(rawValue: 999)) == nil)
    }

    @Test func objectsOfFourGiBReportTheSentinel() throws {
        let big = ScriptedCard.Object(handle: PTPObjectHandle(rawValue: 1), folder: "PRIVATE/M4ROOT/CLIP",
                                      filename: "C0001.MP4", size: 0x1_0000_0001, captureDateRaw: "20261101T090000",
                                      format: .mp4)
        let info = try #require(ScriptedCard(objects: [big]).objectInfo(for: big.handle))
        #expect(info.sizeExceeds32Bits)
        #expect(info.identity(cameraSerial: "k", size: big.size).size == 0x1_0000_0001)
    }

    @Test func badScriptsAreNil() {
        #expect(ScriptedCard.shoot([.raw], start: "not a date") == nil)
        #expect(ScriptedCard.shoot([.raw], firstNumber: 0) == nil)
        #expect(ScriptedCard.shoot([.raw], firstNumber: 10_000) == nil)
        #expect(ScriptedCard.rawPlusJPEG(pairs: 0)?.objects.isEmpty == true)
    }
}
