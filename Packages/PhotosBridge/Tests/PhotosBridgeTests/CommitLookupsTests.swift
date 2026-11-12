import Foundation
@testable import PhotosBridge
import Testing

/// The lookups that resolve a pending commit left behind (backlog section 3.1, I15): the Photos query's match rule and
/// `StagedCopyFinder` over temporary folders. `SystemPhotoLibrary.findAsset` itself is CI and bench only.
@Suite("Commit lookups")
struct CommitLookupsTests {
    static let date = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: AssetQuery

    func query(for unit: CommitUnit) throws -> AssetQuery {
        try #require(AssetQuery(AssetCreation(unit: unit, options: PhotosImportOptions())))
    }

    func staged(_ name: String, date: Date? = CommitLookupsTests.date) -> StagedFile {
        StagedFile(url: URL(fileURLWithPath: "/tmp/" + name), filename: name, captureDate: date)
    }

    @Test func aSingleMatchesItsOwnNameAndRoleWithASCIICaseFolded() throws {
        let q = try query(for: .single(staged("DSC00001.ARW")))
        #expect(q.creationDate == Self.date)
        #expect(q.dateRange == Self.date.addingTimeInterval(-1) ... Self.date.addingTimeInterval(1))
        #expect(q.matches([.init(role: .photo, originalFilename: "DSC00001.ARW")]))
        #expect(q.matches([.init(role: .photo, originalFilename: "dsc00001.arw")]))
        #expect(!q.matches([.init(role: .photo, originalFilename: "DSC00002.ARW")]))
        #expect(!q.matches([.init(role: .alternatePhoto, originalFilename: "DSC00001.ARW")]))
        #expect(!q.matches([]))
    }

    @Test func aPairMatchesOnlyAPairsAssetRoleForRole() throws {
        let q = try query(for: .pair(raw: staged("DSC00001.ARW"), processed: staged("DSC00001.JPG")))
        #expect(q.resources.map(\.role) == [.photo, .alternatePhoto])
        #expect(q.matches([.init(role: .alternatePhoto, originalFilename: "DSC00001.ARW"),
                           .init(role: .photo, originalFilename: "DSC00001.JPG")]))
        // A lone ARW's or a lone JPG's asset isn't the pair's, nor are the roles swapped.
        #expect(!q.matches([.init(role: .photo, originalFilename: "DSC00001.ARW")]))
        #expect(!q.matches([.init(role: .photo, originalFilename: "DSC00001.JPG")]))
        #expect(!q.matches([.init(role: .photo, originalFilename: "DSC00001.ARW"),
                            .init(role: .alternatePhoto, originalFilename: "DSC00001.JPG")]))
        let single = try query(for: .single(staged("DSC00001.ARW")))
        #expect(!single.matches([.init(role: .alternatePhoto, originalFilename: "DSC00001.ARW"),
                                 .init(role: .photo, originalFilename: "DSC00001.JPG")]))
    }

    @Test func foldingIsASCIIOnly() throws {
        let q = try query(for: .single(staged("ÉTÉ.JPG")))
        #expect(q.matches([.init(role: .photo, originalFilename: "ÉTÉ.jpg")]))
        #expect(!q.matches([.init(role: .photo, originalFilename: "été.jpg")]))
    }

    @Test func anAssetGivenNoDateHasNoQuery() {
        #expect(AssetQuery(AssetCreation(unit: .single(staged("A.JPG", date: nil)),
                                         options: PhotosImportOptions())) == nil)
    }

    @Test func aLibraryThatCannotSearchSaysSo() async {
        let library = FakePhotoLibrary()
        let q = AssetQuery(creationDate: Self.date, resources: [])
        #expect(await library.findAsset(q) == .cannotSearch)
    }

    // MARK: StagedCopyFinder

    final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedCopyFinder-\(UUID().uuidString)", isDirectory: true)
        let folder = "Staging/ILCE-7CM2/2026-10-26"
        var url: URL { root.appendingPathComponent(folder, isDirectory: true) }

        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        func put(_ name: String, size: Int, date: Date? = nil) throws {
            let file = url.appendingPathComponent(name)
            try Data(repeating: 1, count: size).write(to: file)
            if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
        }

        func find(_ wanted: [StagedCopyFinder.Wanted]) -> [String]? {
            StagedCopyFinder().find(wanted, in: folder, under: root)?.map(\.relativePath)
        }

        func path(_ name: String) -> String { folder + "/" + name }
    }

    @Test func findsTheNameOrItsNumberedFormWithTheSize() throws {
        let f = Folder()
        try f.put("DSC00001.ARW", size: 10)
        try f.put("DSC00001 (2).ARW", size: 40)
        #expect(f.find([.init(filename: "DSC00001.ARW", size: 40)]) == [f.path("DSC00001 (2).ARW")])
        #expect(f.find([.init(filename: "DSC00001.ARW", size: 10)]) == [f.path("DSC00001.ARW")])
        #expect(f.find([.init(filename: "DSC00001.ARW", size: 41)]) == nil, "a size no copy has")
        #expect(f.find([.init(filename: "DSC00002.ARW", size: 40)]) == nil)
    }

    @Test func theHighestMatchingNumberWins() throws {
        let f = Folder()
        try f.put("DSC00001.ARW", size: 40)
        try f.put("DSC00001 (2).ARW", size: 40)
        try f.put("DSC00001 (10).ARW", size: 40)
        try f.put("DSC00001 (11).ARW", size: 5)
        #expect(f.find([.init(filename: "DSC00001.ARW", size: 40)]) == [f.path("DSC00001 (10).ARW")])
    }

    @Test func aPairMatchesOnlyUnderOneNumber() throws {
        let f = Folder()
        try f.put("DSC00001.JPG", size: 3)          // another file's name: the pair was numbered
        try f.put("DSC00001 (2).ARW", size: 40)
        try f.put("DSC00001 (2).JPG", size: 20)
        try f.put("DSC00001 (3).ARW", size: 40)     // a lone half under a higher number
        let pair: [StagedCopyFinder.Wanted] = [.init(filename: "DSC00001.ARW", size: 40),
                                               .init(filename: "DSC00001.JPG", size: 20)]
        #expect(f.find(pair) == [f.path("DSC00001 (2).ARW"), f.path("DSC00001 (2).JPG")])
        try FileManager.default.removeItem(at: f.url.appendingPathComponent("DSC00001 (2).JPG"))
        #expect(f.find(pair) == nil, "one half alone is not the pair")
    }

    @Test func namesFoldASCIICaseAndAreMadeSafeAsThePlacerMakesThem() throws {
        let f = Folder()
        try f.put("dsc00001 (2).arw", size: 40)
        try f.put("A_B.JPG", size: 7)
        #expect(f.find([.init(filename: "DSC00001.ARW", size: 40)]) == [f.path("dsc00001 (2).arw")])
        #expect(f.find([.init(filename: "A/B.JPG", size: 7)]) == [f.path("A_B.JPG")])
    }

    @Test func onlyRegularFilesCount() throws {
        let f = Folder()
        // An evicted iCloud file shows as a placeholder; a folder may carry the name.
        try f.put(".DSC00001.ARW.icloud", size: 40)
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("DSC00001 (2).ARW"),
                                                withIntermediateDirectories: true)
        #expect(f.find([.init(filename: "DSC00001.ARW", size: 40)]) == nil)
    }

    @Test func theModificationDateBreaksATieWithinOneNumber() throws {
        let f = Folder()
        try f.put("DSC00001.ARW", size: 40, date: Self.date.addingTimeInterval(-3600))
        try f.put("dsc00001.arw", size: 40, date: Self.date)
        // Only a case-sensitive volume holds both; elsewhere the second write replaced the first.
        let names = try FileManager.default.contentsOfDirectory(atPath: f.url.path)
        let expected = names.count == 2 ? "dsc00001.arw" : names[0]
        #expect(f.find([.init(filename: "DSC00001.ARW", size: 40, modificationDate: Self.date)]) == [f.path(expected)])
    }

    // MARK: Only a file placed at or after the commit began

    /// A staged copy placed before the commit began (an older photo with the same name and size, after a file-number
    /// reset) isn't the commit's copy; the one placed since is. Times are given per name, since a status-change time
    /// can't be set on a file.
    @Test func anOlderFileWithTheSameNameAndSizeIsNotFound() throws {
        let f = Folder()
        try f.put("DSC00001.ARW", size: 40)          // an older photo's copy
        try f.put("DSC00001 (2).ARW", size: 40)      // placed by the commit that was killed
        let began = Self.date
        let placed: [String: Date] = [
            "DSC00001.ARW": began.addingTimeInterval(-3600),
            "DSC00001 (2).ARW": began.addingTimeInterval(1),
        ]
        let finder = StagedCopyFinder { url, _ in placed[url.lastPathComponent] }
        let wanted = [StagedCopyFinder.Wanted(filename: "DSC00001.ARW", size: 40, commitBegan: began)]
        #expect(finder.find(wanted, in: f.folder, under: f.root)?.map(\.relativePath) == [f.path("DSC00001 (2).ARW")])

        // Only the older one is there: the commit's file was never placed, so nothing is found.
        try FileManager.default.removeItem(at: f.url.appendingPathComponent("DSC00001 (2).ARW"))
        #expect(finder.find(wanted, in: f.folder, under: f.root) == nil)
        // Without the commit's begin time nothing is checked, as before.
        let unchecked = [StagedCopyFinder.Wanted(filename: "DSC00001.ARW", size: 40)]
        #expect(finder.find(unchecked, in: f.folder, under: f.root)?.map(\.relativePath) == [f.path("DSC00001.ARW")])
    }

    @Test func aFilePlacedJustBeforeTheCommitBeganCountsWithinTheSlack() throws {
        let f = Folder()
        try f.put("A.JPG", size: 1)
        let began = Self.date
        let wanted = [StagedCopyFinder.Wanted(filename: "A.JPG", size: 1, commitBegan: began)]
        let slack = StagedCopyFinder.placementSlack
        let within = StagedCopyFinder { _, _ in began.addingTimeInterval(-slack + 0.5) }
        #expect(within.find(wanted, in: f.folder, under: f.root)?.map(\.relativePath) == [f.path("A.JPG")])
        let before = StagedCopyFinder { _, _ in began.addingTimeInterval(-slack - 0.5) }
        #expect(before.find(wanted, in: f.folder, under: f.root) == nil)
        // A file whose time can't be read is a doubtful one.
        let unreadable = StagedCopyFinder { _, _ in nil }
        #expect(unreadable.find(wanted, in: f.folder, under: f.root) == nil)
    }

    @Test func aPairNeedsBothFilesPlacedSinceTheCommitBegan() throws {
        let f = Folder()
        try f.put("DSC00001.ARW", size: 40)
        try f.put("DSC00001.JPG", size: 20)
        let began = Self.date
        let placed: [String: Date] = ["DSC00001.ARW": began, "DSC00001.JPG": began.addingTimeInterval(-3600)]
        let finder = StagedCopyFinder { url, _ in placed[url.lastPathComponent] }
        let pair: [StagedCopyFinder.Wanted] = [.init(filename: "DSC00001.ARW", size: 40, commitBegan: began),
                                               .init(filename: "DSC00001.JPG", size: 20, commitBegan: began)]
        #expect(finder.find(pair, in: f.folder, under: f.root) == nil, "the JPEG is an older file's")
    }

    /// The real status-change time of a file written now is after a commit that began a minute ago and before one that
    /// begins in an hour (so the default reading works on this platform).
    @Test func theDefaultReadingUsesTheFilesStatusChangeTime() throws {
        let f = Folder()
        try f.put("A.JPG", size: 1, date: Self.date) // the placer's capture date doesn't make it older
        let now = Date()
        let past = [StagedCopyFinder.Wanted(filename: "A.JPG", size: 1, commitBegan: now.addingTimeInterval(-60))]
        let future = [StagedCopyFinder.Wanted(filename: "A.JPG", size: 1, commitBegan: now.addingTimeInterval(3600))]
        #expect(f.find(past) == [f.path("A.JPG")])
        #expect(f.find(future) == nil)
    }

    @Test func aMissingFolderOrOneThatIsNotAPlainPathFindsNothing() throws {
        let f = Folder()
        try f.put("A.JPG", size: 1)
        let finder = StagedCopyFinder()
        let wanted = [StagedCopyFinder.Wanted(filename: "A.JPG", size: 1)]
        #expect(finder.find(wanted, in: "Staging/Other/2026-10-26", under: f.root) == nil)
        #expect(finder.find(wanted, in: "", under: f.root) == nil)
        #expect(finder.find(wanted, in: "/" + f.folder, under: f.root) == nil)
        #expect(finder.find(wanted, in: "Staging/../" + f.folder, under: f.root) == nil)
        #expect(finder.find([], in: f.folder, under: f.root) == nil)
    }

    @Test func theNumberRule() {
        #expect(StagedCopyFinder.number(of: "A.JPG", for: "A.JPG") == 1)
        #expect(StagedCopyFinder.number(of: "A (2).JPG", for: "A.JPG") == 2)
        #expect(StagedCopyFinder.number(of: "A (12).jpg", for: "A.JPG") == 12)
        #expect(StagedCopyFinder.number(of: "A (1).JPG", for: "A.JPG") == nil)
        #expect(StagedCopyFinder.number(of: "A (02).JPG", for: "A.JPG") == nil)
        #expect(StagedCopyFinder.number(of: "A (x).JPG", for: "A.JPG") == nil)
        #expect(StagedCopyFinder.number(of: "A ().JPG", for: "A.JPG") == nil)
        #expect(StagedCopyFinder.number(of: "A (2).JPEG", for: "A.JPG") == nil)
        #expect(StagedCopyFinder.number(of: "README (3)", for: "README") == 3)
        // The same rule `FilesFolderNaming.numbered` writes by.
        #expect(StagedCopyFinder.number(of: FilesFolderNaming.numbered("DSC00001.ARW", 7), for: "DSC00001.ARW") == 7)
    }
}
