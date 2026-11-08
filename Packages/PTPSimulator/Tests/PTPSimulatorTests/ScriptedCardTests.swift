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

    @Test func shootingMoreContinuesTheCard() throws {
        var card = try #require(ScriptedCard.shoot([.jpeg, .jpeg], start: "20261231T235958", firstNumber: 9998))
        let added = card.shootMore([.rawPlusJPEG, .jpeg])
        #expect(added.map(\.filename) == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.JPG"])
        #expect(added.map(\.folder) == ["DCIM/101MSDCF", "DCIM/101MSDCF", "DCIM/101MSDCF"])
        #expect(added.map(\.captureDateRaw) == ["20270101T000002", "20270101T000002", "20270101T000004"])
        #expect(added.map(\.handle.rawValue) == [3, 4, 5] && card.objects.count == 5)
        var empty = ScriptedCard(objects: [])
        #expect(empty.shootMore([.raw]).map(\.filename) == ["DSC00001.ARW"])
    }

    @Test func scaledCardsKeepEverythingButTheSizes() throws {
        let card = try #require(ScriptedCard.rawPlusJPEG(pairs: 50))
        let small = card.scaled(down: 1000)
        #expect(small.objects.map(\.filename) == card.objects.map(\.filename))
        #expect(small.handles == card.handles)
        #expect(zip(small.objects, card.objects).allSatisfy { $0.size == $1.size / 1000 })
        let total = small.objects.reduce(UInt64(0)) { $0 + $1.size }
        #expect((2_900_000 ... 3_300_000).contains(total))
        #expect(card.scaled(down: 0) == card)
        #expect(card.scaled(down: .max).objects.allSatisfy { $0.size == 1 })
    }

    @Test func framesShotOntoAScaledCardAreScaledToo() throws {
        let full = try #require(ScriptedCard.shoot([.rawPlusJPEG, .rawPlusJPEG, .rawPlusJPEG, .jpeg]))
        var small = full.scaled(down: 10).scaled(down: 100)
        #expect(small.sizeDivisor == 1000 && full.sizeDivisor == 1)
        var grown = full
        let fullAdded = grown.shootMore([.rawPlusJPEG])
        let added = small.shootMore([.rawPlusJPEG])
        #expect(added.map(\.filename) == fullAdded.map(\.filename))
        #expect(added.map(\.size) == fullAdded.map { $0.size / 1000 })
        #expect(small.objects.allSatisfy { $0.size < 50_000 })
        // The divisor saturates rather than overflowing; every size is still at least a byte.
        var tiny = full.scaled(down: 1 << 40).scaled(down: 1 << 40)
        #expect(tiny.sizeDivisor == .max)
        #expect(tiny.shootMore([.raw]).map(\.size) == [1])
    }

    @Test func contentIsDeterministicPerObjectAndRange() throws {
        let h1 = PTPObjectHandle(rawValue: 1), h2 = PTPObjectHandle(rawValue: 2)
        let whole = ScriptedCard.content(of: h1, in: 0 ..< 1000)
        #expect(whole.count == 1000)
        #expect(ScriptedCard.content(of: h1, in: 300 ..< 700) == whole.subdata(in: 300 ..< 700))
        #expect(ScriptedCard.content(of: h2, in: 0 ..< 1000) != whole)
        for (i, byte) in whole.enumerated() { #expect(Int(byte) == (i + 7919) % 251) }
        // Handles 251 apart have the same phase; the XOR term keeps their bytes apart.
        let h252 = PTPObjectHandle(rawValue: 252), h1001 = PTPObjectHandle(rawValue: 1001)
        #expect(ScriptedCard.content(of: h252, in: 0 ..< 251) != ScriptedCard.content(of: h1, in: 0 ..< 251))
        #expect(ScriptedCard.content(of: h1001, in: 0 ..< 251) != ScriptedCard.content(of: PTPObjectHandle(rawValue: 750), in: 0 ..< 251))
        let big = try #require(ScriptedCard.rawPlusJPEG(pairs: 200)).scaled(down: 100_000)
        let prefixes = big.handles.map { ScriptedCard.content(of: $0, in: 0 ..< 251) }
        #expect(Set(prefixes).count == big.handles.count)
        #expect(ScriptedCard.content(of: h1, in: 5 ..< 5).isEmpty)
        let far = ScriptedCard.content(of: h2, in: 0x1_0000_0000 ..< 0x1_0000_0004)
        #expect(far.map(Int.init) == (0 ..< 4).map { Int((0x1_0000_0000 + UInt64($0) + 2 * 7919) % 251) })
        let card = try #require(ScriptedCard.shoot([.jpeg])).scaled(down: 1000)
        #expect(card.content(of: card.handles[0], in: 0 ..< card.objects[0].size + 1) == nil)
        #expect(card.content(of: PTPObjectHandle(rawValue: 9), in: 0 ..< 1) == nil)
    }
}
