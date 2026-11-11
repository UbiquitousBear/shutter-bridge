import Catalogue
import Foundation
import PhotosBridge
import Testing
@testable import AppUI

@Suite("Cull units: pairs, days and counts")
struct CullUnitTests {
    @Test func aRawAndItsJPGAreOneUnitShownByTheJPG() {
        let raw = cullFile("DSC00001.ARW"), jpg = cullFile("DSC00001.JPG")
        let days = CullDay.days(of: [jpg, raw])
        #expect(days.count == 1)
        let unit = days[0].units[0]
        #expect(days[0].units.count == 1)
        #expect(unit.isPair)
        #expect(unit.files == [raw, jpg])
        #expect(unit.id == raw.contentKey)
        #expect(unit.keys == [raw.contentKey, jpg.contentKey])
        #expect(unit.previewSource == .image(jpg, pairedWithRAW: true))
    }

    @Test func aLoneRawIsShownByItsEmbeddedPreviewThenARender() {
        let raw = cullFile("DSC00002.ARW")
        let unit = CullDay.days(of: [raw])[0].units[0]
        #expect(!unit.isPair)
        #expect(unit.previewSource == .raw(raw))
        #expect(unit.previewSource.file == raw)
    }

    @Test func aLoneJPGOrHEIFIsShownAsItIsAndAVideoHasNoPreview() {
        let jpg = cullFile("DSC00003.JPG", at: "20261105T140001")
        let hif = cullFile("DSC00004.HIF", at: "20261105T140002")
        let video = cullFile("C0001.MP4", at: "20261105T140003")
        let units = CullDay.days(of: [jpg, hif, video])[0].units
        #expect(units.map(\.previewSource) == [.image(jpg, pairedWithRAW: false), .image(hif, pairedWithRAW: false),
                                               PreviewSource.none])
        #expect(units[2].previewSource.file == nil)
    }

    @Test func aPairWithAHIFIsShownByTheHIF() {
        let raw = cullFile("DSC00005.ARW"), hif = cullFile("DSC00005.HIF")
        #expect(CullDay.days(of: [raw, hif])[0].units[0].previewSource == .image(hif, pairedWithRAW: true))
    }

    @Test func theRuleDecidesWhoPairs() {
        // Same stem but different folder, or more than a second apart, or the other camera: not pairs.
        let a = [cullFile("DSC00006.ARW"), cullFile("DSC00006.JPG", folder: "101MSDCF")]
        #expect(CullDay.days(of: a)[0].units.count == 2)
        let b = [cullFile("DSC00007.ARW"), cullFile("DSC00007.JPG", at: "20261105T140005")]
        #expect(CullDay.days(of: b)[0].units.count == 2)
        let c = [cullFile("DSC00008.ARW", camera: "cam-a"), cullFile("DSC00008.JPG", camera: "cam-b")]
        #expect(CullDay.days(of: c).count == 2)
        #expect(CullDay.days(of: c).allSatisfy { $0.units.count == 1 })
        // A looser rule pairs the second.
        #expect(CullDay.days(of: b, rule: RawPairingRule(tolerance: 10))[0].units.count == 1)
    }

    @Test func daysComeNewestFirstPerCameraAndUnitsInShootingOrder() {
        let files = [
            cullFile("DSC00003.ARW", at: "20261105T140003"),
            cullFile("DSC00001.ARW", at: "20261103T100000"),
            cullFile("DSC00002.ARW", at: "20261105T140001"),
            cullFile("DSC00004.ARW", at: "20261104T090000"),
            cullFile("DSC00009.ARW", at: "20261105T120000", camera: "cam-b"),
        ]
        let days = CullDay.days(of: files)
        #expect(days.map { "\($0.camera.rawValue) \($0.day)" }
            == ["cam-a 20261105", "cam-a 20261104", "cam-a 20261103", "cam-b 20261105"])
        #expect(days[0].units.map { $0.files[0].identity.filename } == ["DSC00002.ARW", "DSC00003.ARW"])
        #expect(days[0].id == CullDay.ID(camera: CameraKey(rawValue: "cam-a"), day: "20261105"))
    }

    @Test func sameSecondUnitsAreOrderedByName() {
        let files = [cullFile("DSC00012.ARW"), cullFile("DSC00010.ARW"), cullFile("DSC00011.ARW")]
        #expect(CullDay.days(of: files)[0].units.map { $0.files[0].identity.filename }
            == ["DSC00010.ARW", "DSC00011.ARW", "DSC00012.ARW"])
    }

    @Test func aSecondStagedCopyOfOneFileIsDropped() {
        let one = cullFile("DSC00001.ARW"), again = cullFile("dsc00001.arw", folder: "elsewhere")
        let days = CullDay.days(of: [one, again])
        #expect(days[0].units.count == 1)
        #expect(days[0].units[0].files == [one])
    }

    @Test func noFilesNoDays() {
        #expect(CullDay.days(of: []).isEmpty)
    }

    @Test func countsAreInUnitsAndAPairIsOne() {
        let files = [cullFile("DSC00001.ARW", at: "20261105T140001"), cullFile("DSC00001.JPG", at: "20261105T140001"),
                     cullFile("DSC00002.ARW", at: "20261105T140002"), cullFile("DSC00003.ARW", at: "20261105T140003"),
                     cullFile("DSC00004.ARW", at: "20261105T140004")]
        let day = CullDay.days(of: files)[0]
        #expect(day.units.count == 4)
        // A pair's mark may sit under either file's key.
        let marks: [ObjectIdentity.ContentKey: CullMark] = [
            files[1].contentKey: CullMark(decision: .keep),
            files[2].contentKey: CullMark(decision: .reject, rating: 2),
            files[3].contentKey: CullMark(decision: nil, rating: 4),
        ]
        let counts = day.counts(marks: marks)
        #expect(counts.units == 4)
        #expect(counts.files == 5)
        #expect(counts.kept == 1)
        #expect(counts.rejected == 1)
        #expect(counts.unmarked == 2)
    }

    @Test func aMarkRatingIsClampedToZeroToFive() {
        #expect(CullMark(decision: .keep, rating: 9).rating == 5)
        #expect(CullMark(decision: nil, rating: -3).rating == 0)
        #expect(CullMark().isUnmarked)
        #expect(!CullMark(rating: 1).isUnmarked)
    }
}
