import Foundation
import Testing
@testable import PhotosBridge

/// A listing entry, as the engine's camera items will look to the rule.
struct Item: PairableFile, Hashable, Sendable, CustomStringConvertible {
    var folder: String
    var name: String
    var date: Date?

    var pairingFolder: String { folder }
    var pairingFilename: String { name }
    var pairingCaptureDate: Date? { date }
    var description: String { "\(folder)/\(name)" }

    init(_ name: String, _ seconds: TimeInterval?, folder: String = "100MSDCF") {
        self.folder = folder
        self.name = name
        date = seconds.map { Date(timeIntervalSince1970: 1_793_142_018 + $0) }
    }
}

@Suite("RAW+JPEG pairing")
struct PairingTests {
    let rule = RawPairingRule()

    @Test("The captured pair: DSC01779.ARW and DSC01779.JPG, same parent and capture second (PTP/IP fixtures)")
    func fixturePair() {
        let arw = Item("DSC01779.ARW", 0, folder: "0x40000010")
        let jpg = Item("DSC01779.JPG", 0, folder: "0x40000010")
        #expect(rule.units([arw, jpg]) == [.pair(raw: arw, processed: jpg)])
        #expect(rule.units([jpg, arw]) == [.pair(raw: arw, processed: jpg)])
        #expect(RawPairingRule.stem(ofFilename: arw.name) == "DSC01779")
    }

    @Test func heifPairsLikeJPEG() {
        let arw = Item("DSC00010.ARW", 0), hif = Item("DSC00010.HIF", 0.4)
        #expect(rule.units([arw, hif]) == [.pair(raw: arw, processed: hif)])
    }

    @Test("Within 1 s pairs, inclusive; beyond it doesn't")
    func tolerance() {
        #expect(rule.pairs(Item("A.ARW", 0), Item("A.JPG", 1)))
        #expect(rule.pairs(Item("A.ARW", 1), Item("A.JPG", 0)))
        #expect(!rule.pairs(Item("A.ARW", 0), Item("A.JPG", 1.5)))
        #expect(RawPairingRule(tolerance: 2).pairs(Item("A.ARW", 0), Item("A.JPG", 1.5)))
    }

    @Test func differentFolderOrStemDoesNotPair() {
        #expect(!rule.pairs(Item("DSC00001.ARW", 0, folder: "100MSDCF"), Item("DSC00001.JPG", 0, folder: "101MSDCF")))
        #expect(!rule.pairs(Item("DSC00001.ARW", 0), Item("DSC00002.JPG", 0)))
    }

    @Test("A counter that wrapped: same folder and stem, a different day, stays two units")
    func wrappedCounter() {
        let old = Item("DSC00001.ARW", 0), new = Item("DSC00001.JPG", 86_400 * 30)
        #expect(rule.units([old, new]) == [.single(old), .single(new)])
    }

    @Test func stemsCompareCaseInsensitively() {
        #expect(rule.pairs(Item("dsc00001.arw", 0), Item("DSC00001.JPG", 0)))
    }

    @Test("Two RAWs, two JPEGs or a video never pair")
    func rolesMustDiffer() {
        #expect(!rule.pairs(Item("A.ARW", 0), Item("A.ARW", 0)))
        #expect(!rule.pairs(Item("A.JPG", 0), Item("A.HIF", 0)))
        #expect(!rule.pairs(Item("C0001.MP4", 0), Item("C0001.JPG", 0)))
        #expect(RawPairingRule.role(ofFilename: "C0001.MP4") == .other)
        #expect(RawPairingRule.role(ofFilename: "x.heic") == .processed)
        #expect(RawPairingRule.role(ofFilename: "ARW") == .other)
    }

    @Test("A file without a capture date doesn't pair")
    func missingDate() {
        let arw = Item("A.ARW", nil), jpg = Item("A.JPG", 0)
        #expect(rule.units([arw, jpg]) == [.single(arw), .single(jpg)])
    }

    @Test("A JPG and a HIF for one ARW: the closer wins, then the JPEG; the other stays single")
    func ambiguousCandidates() {
        let arw = Item("A.ARW", 0), jpg = Item("A.JPG", 0.8), hif = Item("A.HIF", 0.2)
        #expect(rule.units([arw, jpg, hif]) == [.pair(raw: arw, processed: hif), .single(jpg)])
        let jpg2 = Item("A.JPG", 0.2)
        #expect(rule.units([hif, arw, jpg2]) == [.single(hif), .pair(raw: arw, processed: jpg2)])
    }

    @Test("Order follows each unit's first file; every file is in exactly one unit")
    func orderAndCoverage() {
        let files = [Item("DSC1.JPG", 0), Item("DSC2.ARW", 10), Item("DSC1.ARW", 0), Item("C3.MP4", 20), Item("DSC2.JPG", 10)]
        let units = rule.units(files)
        #expect(units == [.pair(raw: files[2], processed: files[0]), .pair(raw: files[1], processed: files[4]), .single(files[3])])
        #expect(Set(units.flatMap(\.files)) == Set(files))
        #expect(units.flatMap(\.files).count == files.count)
    }

    @Test("A card shaped like 5 Nov's: 539 ARW and 286 JPG make 539 units, 286 of them pairs")
    func cardShape() {
        var files: [Item] = []
        for n in 0 ..< 539 {
            let name = String(format: "DSC%05d", n + 1)
            let folder = n < 300 ? "100MSDCF" : "101MSDCF"
            files.append(Item(name + ".ARW", Double(n * 3), folder: folder))
            if n % 539 < 286 { files.append(Item(name + ".JPG", Double(n * 3), folder: folder)) }
        }
        let units = rule.units(files)
        #expect(units.count == 539)
        #expect(units.filter { if case .pair = $0 { true } else { false } }.count == 286)
    }

    @Test func mapCarriesTheShape() {
        let unit = PairingUnit<Item>.pair(raw: Item("A.ARW", 0), processed: Item("A.JPG", 0))
        let staged = unit.map { StagedFile(url: URL(fileURLWithPath: "/tmp/" + $0.name), filename: $0.name, captureDate: $0.date) }
        guard case let .pair(raw, processed) = staged.commitUnit else { Issue.record("not a pair"); return }
        #expect(raw.filename == "A.ARW" && processed.filename == "A.JPG")
    }

    @Test func stems() {
        #expect(RawPairingRule.stem(ofFilename: "DSC00001.ARW") == "DSC00001")
        #expect(RawPairingRule.stem(ofFilename: "a.b.JPG") == "a.b")
        #expect(RawPairingRule.stem(ofFilename: "NOEXT") == "NOEXT")
        #expect(RawPairingRule.stem(ofFilename: ".hidden") == ".hidden")
    }
}
