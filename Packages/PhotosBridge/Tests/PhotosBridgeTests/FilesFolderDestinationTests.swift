import Foundation
import Testing
@testable import PhotosBridge

@Suite("Files destination (temporary directories)")
struct FilesFolderDestinationTests {
    let date = Date(timeIntervalSince1970: 1_793_142_018)

    func documents(_ s: Scratch) -> URL { s.root.appendingPathComponent("Documents", isDirectory: true) }

    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    @Test("A file is moved into the camera's folder, keeps its bytes and gets the capture date")
    func movesAndDates() async throws {
        let s = try Scratch()
        let staged = try s.stage("DSC02018.ARW", date: date, bytes: "raw bytes")
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "ILCE-7CM2")
        let result = try await d.commit(.single(staged))
        #expect(result == .files([FileLocation(relativePath: "ILCE-7CM2/DSC02018.ARW")]))
        let placed = FileLocation(relativePath: "ILCE-7CM2/DSC02018.ARW").url(inDocuments: documents(s))
        #expect(try contents(placed) == "raw bytes")
        #expect(!FileManager.default.fileExists(atPath: staged.url.path), "moved, not copied")
        let mtime = try #require(try modificationDate(placed))
        #expect(abs(mtime.timeIntervalSince(date)) < 1)
        #expect(d.kind == .filesFolder)
        #expect(d.folderURL.lastPathComponent == "ILCE-7CM2")
    }

    @Test("Both files of a pair are kept under their own names")
    func pairKeepsBoth() async throws {
        let s = try Scratch()
        let raw = try s.stage("DSC01779.ARW", date: date), jpg = try s.stage("DSC01779.JPG", date: date)
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "ILCE-7CM2")
        let result = try await d.commit(.pair(raw: raw, processed: jpg))
        #expect(result == .files([FileLocation(relativePath: "ILCE-7CM2/DSC01779.ARW"),
                                  FileLocation(relativePath: "ILCE-7CM2/DSC01779.JPG")]))
        let names = try FileManager.default.contentsOfDirectory(atPath: d.folderURL.path).sorted()
        #expect(names == ["DSC01779.ARW", "DSC01779.JPG"])
    }

    @Test("A name already present is never overwritten: the new file gets the next free number")
    func neverOverwrites() async throws {
        let s = try Scratch()
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "ILCE-7CM2")
        _ = try await d.commit(.single(try s.stage("DSC00001.ARW", bytes: "first")))
        let second = try await d.commit(.single(try s.stage("DSC00001.ARW", bytes: "second")))
        let third = try await d.commit(.single(try s.stage("dsc00001.arw", bytes: "third")))
        #expect(second == .files([FileLocation(relativePath: "ILCE-7CM2/DSC00001 (2).ARW")]))
        #expect(third == .files([FileLocation(relativePath: "ILCE-7CM2/dsc00001 (3).arw")]), "compared case-insensitively")
        #expect(try contents(d.folderURL.appendingPathComponent("DSC00001.ARW")) == "first")
        #expect(try contents(d.folderURL.appendingPathComponent("DSC00001 (2).ARW")) == "second")
    }

    @Test("When one file of a pair clashes, both take the same number so the pair keeps one stem")
    func pairClash() async throws {
        let s = try Scratch()
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "ILCE-7CM2")
        _ = try await d.commit(.single(try s.stage("DSC00001.ARW", bytes: "old raw")))
        let result = try await d.commit(.pair(raw: try s.stage("DSC00001.ARW"), processed: try s.stage("DSC00001.JPG")))
        #expect(result == .files([FileLocation(relativePath: "ILCE-7CM2/DSC00001 (2).ARW"),
                                  FileLocation(relativePath: "ILCE-7CM2/DSC00001 (2).JPG")]))
        #expect(try contents(d.folderURL.appendingPathComponent("DSC00001.ARW")) == "old raw")
    }

    @Test("A file the person put there by hand is not overwritten either")
    func foreignFile() async throws {
        let s = try Scratch()
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "ILCE-7CM2")
        try FileManager.default.createDirectory(at: d.folderURL, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: d.folderURL.appendingPathComponent("DSC00005.JPG"))
        let result = try await d.commit(.single(try s.stage("DSC00005.JPG")))
        #expect(result == .files([FileLocation(relativePath: "ILCE-7CM2/DSC00005 (2).JPG")]))
        #expect(try contents(d.folderURL.appendingPathComponent("DSC00005.JPG")) == "mine")
    }

    @Test("One folder per camera")
    func folderPerCamera() async throws {
        let s = try Scratch()
        let a = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "ILCE-7CM2")
        let b = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "ILCE-7M4")
        _ = try await a.commit(.single(try s.stage("DSC00001.JPG")))
        _ = try await b.commit(.single(try s.stage("DSC00001.JPG")))
        let folders = try FileManager.default.contentsOfDirectory(atPath: documents(s).path).sorted()
        #expect(folders == ["ILCE-7CM2", "ILCE-7M4"])
    }

    @Test("No capture date: the file is placed and keeps its own date")
    func noDate() async throws {
        let s = try Scratch()
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "Cam")
        #expect(try await d.commit(.single(try s.stage("A.JPG"))) == .files([FileLocation(relativePath: "Cam/A.JPG")]))
    }

    @Test("A missing staged file fails before anything is placed")
    func missingStaged() async throws {
        let s = try Scratch()
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "Cam")
        let ok = try s.stage("A.ARW")
        let gone = StagedFile(url: s.root.appendingPathComponent("gone.part"), filename: "A.JPG", captureDate: nil)
        await #expect(throws: ImportDestinationFailure.stagedFileMissing) {
            try await d.commit(.pair(raw: ok, processed: gone))
        }
        #expect(FileManager.default.fileExists(atPath: ok.url.path))
    }

    @Test("A unit whose two files share a name (ignoring case, once made safe) is rejected, not looped on")
    func sameNamePair() async throws {
        let s = try Scratch()
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "Cam")
        let upper = try s.stage("DSC1.ARW"), lower = try s.stage("dsc1.arw")
        await #expect(throws: ImportDestinationFailure.rejected(detail: "two files of one unit share a name")) {
            try await d.commit(.pair(raw: upper, processed: lower))
        }
        // Equal only after the separator is replaced.
        let slash = try s.stage("A/B.JPG"), underscore = try s.stage("a_b.jpg")
        await #expect(throws: ImportDestinationFailure.rejected(detail: "two files of one unit share a name")) {
            try await d.commit(.pair(raw: slash, processed: underscore))
        }
        for f in [upper, lower, slash, underscore] { #expect(FileManager.default.fileExists(atPath: f.url.path)) }
        // The destination still works afterwards.
        #expect(try await d.commit(.single(try s.stage("C.JPG"))) == .files([FileLocation(relativePath: "Cam/C.JPG")]))
    }

    @Test("If the second file of a pair can't be placed, the first goes back to staging")
    func pairRollback() async throws {
        let s = try Scratch()
        let d = FilesFolderDestination(documentsDirectory: documents(s), cameraName: "Cam")
        let raw = try s.stage("A.ARW")
        let jpg = try s.stage("A.JPG")
        // A name the file system refuses (over 255 bytes) makes the second move fail after the first succeeded.
        let long = StagedFile(url: jpg.url, filename: String(repeating: "x", count: 300) + ".JPG", captureDate: nil)
        await #expect(throws: ImportDestinationFailure.self) {
            try await d.commit(.pair(raw: raw, processed: long))
        }
        #expect(FileManager.default.fileExists(atPath: raw.url.path), "the ARW is back in staging")
        #expect(FileManager.default.fileExists(atPath: jpg.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.folderURL.path).isEmpty)
    }
}

@Suite("Files folder names")
struct FilesFolderNamingTests {
    @Test func folderNames() {
        #expect(FilesFolderNaming.folderName(forCamera: "ILCE-7CM2") == "ILCE-7CM2")
        #expect(FilesFolderNaming.folderName(forCamera: "α7C II") == "α7C II")
        #expect(FilesFolderNaming.folderName(forCamera: "a/b:c\\d") == "a_b_c_d")
        #expect(FilesFolderNaming.folderName(forCamera: "  ..hidden  ") == "hidden")
        #expect(FilesFolderNaming.folderName(forCamera: "") == "Camera")
        #expect(FilesFolderNaming.folderName(forCamera: "...") == "Camera")
        #expect(FilesFolderNaming.folderName(forCamera: "tab\there") == "tab_here")
        #expect(FilesFolderNaming.folderName(forCamera: "Inbox") == "Inbox camera")
        #expect(FilesFolderNaming.folderName(forCamera: String(repeating: "z", count: 200)).count == 64)
    }

    @Test func fileNames() {
        #expect(FilesFolderNaming.fileName(forCameraFile: "DSC00001.ARW") == "DSC00001.ARW")
        #expect(FilesFolderNaming.fileName(forCameraFile: "../x") == "_x")
        #expect(FilesFolderNaming.fileName(forCameraFile: ".") == "unnamed")
        #expect(FilesFolderNaming.numbered("DSC00001.ARW", 2) == "DSC00001 (2).ARW")
        #expect(FilesFolderNaming.numbered("NOEXT", 3) == "NOEXT (3)")
    }
}
