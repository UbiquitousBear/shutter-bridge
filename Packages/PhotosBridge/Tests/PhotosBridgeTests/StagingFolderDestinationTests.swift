import Foundation
import Testing
@testable import PhotosBridge

/// Staging's placement, with temporary directories as the root. The placement guarantees are the Files folder's of
/// 8 Nov, moved into `FolderPlacer` unchanged (these were `FilesFolderDestinationTests`), now under the staging
/// layout Staging/camera/capture day.
@Suite("Staging destination (temporary directories)")
struct StagingFolderDestinationTests {
    /// 27 Oct 2026, 23:00:18 UTC: still the 27th in London (GMT by then), already the 28th in Paris.
    let date = Date(timeIntervalSince1970: 1_793_142_018)
    let utc = TimeZone(identifier: "UTC")!
    /// The day folder `date` lands in, in UTC.
    let day = "2026-10-27"

    func root(_ s: Scratch) -> URL { s.root.appendingPathComponent("Documents", isDirectory: true) }

    func destination(_ s: Scratch, camera: String = "ILCE-7CM2", place: StagingPlace = .iCloudDrive,
                     zone: TimeZone? = nil, mover: any StagedFileMover = PlainFileMover()) -> StagingFolderDestination {
        StagingFolderDestination(root: root(s), place: place, cameraName: camera, timeZone: zone ?? utc, mover: mover)
    }

    func staged(_ paths: String..., place: StagingPlace = .iCloudDrive) -> ImportResult {
        .staged(place: place, paths.map { FileLocation(relativePath: $0) })
    }

    func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    func dayFolder(_ d: StagingFolderDestination, _ day: String) -> URL {
        d.cameraFolderURL.appendingPathComponent(day, isDirectory: true)
    }

    // MARK: - Layout

    @Test("A file is moved to Staging/camera/day, keeps its bytes and gets the capture date")
    func movesAndDates() async throws {
        let s = try Scratch()
        let file = try s.stage("DSC02018.ARW", date: date, bytes: "raw bytes")
        let d = destination(s)
        let result = try await d.commit(.single(file))
        let path = "Staging/ILCE-7CM2/\(day)/DSC02018.ARW"
        #expect(result == staged(path))
        let placed = FileLocation(relativePath: path).url(in: root(s))
        #expect(try contents(placed) == "raw bytes", "byte for byte")
        #expect(!FileManager.default.fileExists(atPath: file.url.path), "moved, not copied")
        let mtime = try #require(try modificationDate(placed))
        #expect(abs(mtime.timeIntervalSince(date)) < 1)
        #expect(d.kind == .staging)
        #expect(d.cameraFolderPath == "Staging/ILCE-7CM2")
        #expect(d.cameraFolderURL == root(s).appendingPathComponent("Staging/ILCE-7CM2", isDirectory: true))
    }

    @Test("The result names the place: iCloud Drive, or this iPhone with the reason")
    func placeInResult() async throws {
        let s = try Scratch()
        let local = destination(s, place: .onThisIPhone(.iCloudDriveOff))
        #expect(try await local.commit(.single(try s.stage("A.JPG", date: date)))
            == staged("Staging/ILCE-7CM2/\(day)/A.JPG", place: .onThisIPhone(.iCloudDriveOff)))
        #expect(local.place == .onThisIPhone(.iCloudDriveOff))
    }

    @Test("The day is the camera's clock in the job's zone, around midnight too")
    func dayInTheJobsZone() async throws {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let london = TimeZone(identifier: "Europe/London")!
        #expect(StagingFolderDestination.dayFolderName(for: date, in: utc) == "2026-10-27")
        #expect(StagingFolderDestination.dayFolderName(for: date, in: london) == "2026-10-27")
        #expect(StagingFolderDestination.dayFolderName(for: date, in: paris) == "2026-10-28")
        let lastSecond = Date(timeIntervalSince1970: 1_794_182_399) // 8 Nov 2026, 23:59:59 UTC
        let midnight = Date(timeIntervalSince1970: 1_794_182_400)   // 9 Nov 2026, 00:00:00 UTC
        #expect(StagingFolderDestination.dayFolderName(for: lastSecond, in: utc) == "2026-11-08")
        #expect(StagingFolderDestination.dayFolderName(for: midnight, in: utc) == "2026-11-09")
        #expect(StagingFolderDestination.dayFolderName(for: nil, in: utc) == "Undated")
        #expect(StagingFolderDestination.dayFolderName(for: Date(timeIntervalSince1970: -70_000_000_000), in: utc)
            == "Undated", "a year outside 0001–9999")

        let s = try Scratch()
        let d = destination(s, zone: paris)
        #expect(try await d.commit(.single(try s.stage("A.ARW", date: lastSecond)))
            == staged("Staging/ILCE-7CM2/2026-11-09/A.ARW"), "00:59:59 on the 9th in Paris")
    }

    @Test("A file with no capture date goes to Undated and keeps its own date")
    func noDate() async throws {
        let s = try Scratch()
        let d = destination(s, camera: "Cam")
        #expect(try await d.commit(.single(try s.stage("A.JPG"))) == staged("Staging/Cam/Undated/A.JPG"))
    }

    @Test("Both files of a pair land in one folder, the RAW's day, under their own names")
    func pairKeepsBoth() async throws {
        let s = try Scratch()
        let nextDay = date.addingTimeInterval(3_600) // the JPEG a second later would do; an hour crosses midnight
        let raw = try s.stage("DSC01779.ARW", date: date), jpg = try s.stage("DSC01779.JPG", date: nextDay)
        let d = destination(s)
        let result = try await d.commit(.pair(raw: raw, processed: jpg))
        #expect(result == staged("Staging/ILCE-7CM2/\(day)/DSC01779.ARW", "Staging/ILCE-7CM2/\(day)/DSC01779.JPG"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dayFolder(d, day).path).sorted()
        #expect(names == ["DSC01779.ARW", "DSC01779.JPG"])
    }

    @Test("The commit target is the day folder the commit then places the files in, a pair's in the RAW's day")
    func commitTargetMatchesTheCommit() async throws {
        let s = try Scratch()
        let paris = TimeZone(identifier: "Europe/Paris")!
        let d = destination(s, place: .onThisIPhone(.iCloudDriveOff), zone: paris)
        let raw = try s.stage("DSC01779.ARW", date: date), jpg = try s.stage("DSC01779.JPG", date: date)
        let unit = CommitUnit.pair(raw: raw, processed: jpg)
        let target = d.commitTarget(for: unit)
        #expect(target == .stagingFolder(place: .onThisIPhone(.iCloudDriveOff),
                                         folderPath: "Staging/ILCE-7CM2/2026-10-28"))
        guard case let .staged(_, locations) = try await d.commit(unit),
              case let .stagingFolder(_, folderPath) = target else {
            Issue.record("not staged")
            return
        }
        #expect(locations.map { ($0.relativePath as NSString).deletingLastPathComponent } == [folderPath, folderPath])
        let undated = d.commitTarget(for: .single(try s.stage("A.JPG")))
        #expect(undated == .stagingFolder(place: .onThisIPhone(.iCloudDriveOff), folderPath: "Staging/ILCE-7CM2/Undated"))
    }

    @Test("One folder per camera, and per day within it")
    func folderPerCameraAndDay() async throws {
        let s = try Scratch()
        let a = destination(s, camera: "ILCE-7CM2")
        let b = destination(s, camera: "ILCE-7M4")
        _ = try await a.commit(.single(try s.stage("DSC00001.JPG", date: date)))
        _ = try await a.commit(.single(try s.stage("DSC00002.JPG", date: date.addingTimeInterval(86_400))))
        _ = try await b.commit(.single(try s.stage("DSC00001.JPG", date: date)))
        let staging = root(s).appendingPathComponent("Staging")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted() == ["ILCE-7CM2", "ILCE-7M4"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.cameraFolderURL.path).sorted()
            == ["2026-10-27", "2026-10-28"])
    }

    // MARK: - The placement guarantees (FolderPlacer; were the Files folder's)

    @Test("A name already present is never overwritten: the new file gets the next free number")
    func neverOverwrites() async throws {
        let s = try Scratch()
        let d = destination(s)
        _ = try await d.commit(.single(try s.stage("DSC00001.ARW", date: date, bytes: "first")))
        let second = try await d.commit(.single(try s.stage("DSC00001.ARW", date: date, bytes: "second")))
        let third = try await d.commit(.single(try s.stage("dsc00001.arw", date: date, bytes: "third")))
        #expect(second == staged("Staging/ILCE-7CM2/\(day)/DSC00001 (2).ARW"))
        #expect(third == staged("Staging/ILCE-7CM2/\(day)/dsc00001 (3).arw"), "compared case-insensitively")
        #expect(try contents(dayFolder(d, day).appendingPathComponent("DSC00001.ARW")) == "first")
        #expect(try contents(dayFolder(d, day).appendingPathComponent("DSC00001 (2).ARW")) == "second")
    }

    @Test("When one file of a pair clashes, both take the same number so the pair keeps one stem")
    func pairClash() async throws {
        let s = try Scratch()
        let d = destination(s)
        _ = try await d.commit(.single(try s.stage("DSC00001.ARW", date: date, bytes: "old raw")))
        let result = try await d.commit(.pair(raw: try s.stage("DSC00001.ARW", date: date),
                                              processed: try s.stage("DSC00001.JPG", date: date)))
        #expect(result == staged("Staging/ILCE-7CM2/\(day)/DSC00001 (2).ARW",
                                 "Staging/ILCE-7CM2/\(day)/DSC00001 (2).JPG"))
        #expect(try contents(dayFolder(d, day).appendingPathComponent("DSC00001.ARW")) == "old raw")
    }

    @Test("A file the person put there by hand is not overwritten either")
    func foreignFile() async throws {
        let s = try Scratch()
        let d = destination(s)
        try FileManager.default.createDirectory(at: dayFolder(d, day), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dayFolder(d, day).appendingPathComponent("DSC00005.JPG"))
        let result = try await d.commit(.single(try s.stage("DSC00005.JPG", date: date)))
        #expect(result == staged("Staging/ILCE-7CM2/\(day)/DSC00005 (2).JPG"))
        #expect(try contents(dayFolder(d, day).appendingPathComponent("DSC00005.JPG")) == "mine")
    }

    @Test("An iCloud placeholder '.NAME.icloud' (an evicted file) counts as NAME taken")
    func iCloudPlaceholder() async throws {
        let s = try Scratch()
        let d = destination(s)
        try FileManager.default.createDirectory(at: dayFolder(d, day), withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(to: dayFolder(d, day).appendingPathComponent(".DSC00001.ARW.icloud"))
        let result = try await d.commit(.pair(raw: try s.stage("DSC00001.ARW", date: date),
                                              processed: try s.stage("DSC00001.JPG", date: date)))
        #expect(result == staged("Staging/ILCE-7CM2/\(day)/DSC00001 (2).ARW",
                                 "Staging/ILCE-7CM2/\(day)/DSC00001 (2).JPG"))
        let placeholder = dayFolder(d, day).appendingPathComponent(".DSC00001.ARW.icloud")
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
    }

    @Test func placeholderNames() {
        #expect(FolderPlacer.takenNames([".DSC00001.ARW.icloud"]) == [".dsc00001.arw.icloud", "dsc00001.arw"])
        #expect(FolderPlacer.takenNames(["DSC00001.ARW"]) == ["dsc00001.arw"])
        // Not placeholders: no leading dot, or nothing between the dot and the suffix.
        #expect(FolderPlacer.takenNames(["A.icloud"]) == ["a.icloud"])
        #expect(FolderPlacer.takenNames([".icloud"]) == [".icloud"])
    }

    @Test("A missing staged file fails before anything is placed")
    func missingStaged() async throws {
        let s = try Scratch()
        let d = destination(s, camera: "Cam")
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
        let d = destination(s, camera: "Cam")
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
        #expect(try await d.commit(.single(try s.stage("C.JPG"))) == staged("Staging/Cam/Undated/C.JPG"))
    }

    @Test("If the second file of a pair can't be placed, the first goes back to staging")
    func pairRollback() async throws {
        let s = try Scratch()
        let d = destination(s, camera: "Cam")
        let raw = try s.stage("A.ARW")
        let jpg = try s.stage("A.JPG")
        // A name the file system refuses (over 255 bytes) makes the second move fail after the first succeeded.
        let long = StagedFile(url: jpg.url, filename: String(repeating: "x", count: 300) + ".JPG", captureDate: nil)
        await #expect(throws: ImportDestinationFailure.self) {
            try await d.commit(.pair(raw: raw, processed: long))
        }
        #expect(FileManager.default.fileExists(atPath: raw.url.path), "the ARW is back in staging")
        #expect(FileManager.default.fileExists(atPath: jpg.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dayFolder(d, "Undated").path).isEmpty)
    }

    @Test("The mover is the destination's: a refused second move takes the first back through it")
    func injectedMoverTakesBack() async throws {
        let s = try Scratch()
        let mover = ScriptedMover(failOnPlace: 2, error: CocoaError(.fileWriteNoPermission))
        let d = destination(s, mover: mover)
        let raw = try s.stage("A.ARW", date: date), jpg = try s.stage("A.JPG", date: date)
        await #expect(throws: ImportDestinationFailure.self) {
            try await d.commit(.pair(raw: raw, processed: jpg))
        }
        #expect(mover.calls == ["place A.ARW", "place A.JPG", "takeBack A.ARW"])
        #expect(FileManager.default.fileExists(atPath: raw.url.path))
        #expect(FileManager.default.fileExists(atPath: jpg.url.path))
    }

    @Test("A mover that keeps dates (iCloud Drive) isn't asked to set them again; the date travels with the file")
    func dateTravelsWithoutASecondWrite() async throws {
        let s = try Scratch()
        let mover = ScriptedMover(setsDateAfterPlacing: false)
        let d = destination(s, mover: mover)
        let result = try await d.commit(.single(try s.stage("A.ARW", date: date)))
        #expect(result == staged("Staging/ILCE-7CM2/\(day)/A.ARW"))
        let placed = FileLocation(relativePath: "Staging/ILCE-7CM2/\(day)/A.ARW").url(in: root(s))
        let mtime = try #require(try modificationDate(placed))
        #expect(abs(mtime.timeIntervalSince(date)) < 1)
    }

    // MARK: - Errors

    @Test("No room is .notEnoughSpace; iCloud Drive gone is .stagingUnavailable; a vanished file is missing")
    func errorMapping() {
        let enospc = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(FolderPlacer.failure(enospc) == .notEnoughSpace)
        #expect(FolderPlacer.failure(CocoaError(.fileWriteOutOfSpace)) == .notEnoughSpace)
        #expect(FolderPlacer.failure(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                                             userInfo: [NSUnderlyingErrorKey: enospc])) == .notEnoughSpace)
        let unavailable = NSError(domain: NSCocoaErrorDomain, code: 4353) // NSUbiquitousFileUnavailableError
        #expect(FolderPlacer.failure(unavailable) == .stagingUnavailable)
        #expect(FolderPlacer.failure(NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                                             userInfo: [NSUnderlyingErrorKey: unavailable])) == .stagingUnavailable)
        #expect(FolderPlacer.failure(CocoaError(.fileNoSuchFile)) == .stagedFileMissing)
        #expect(FolderPlacer.failure(CocoaError(.fileReadNoSuchFile)) == .stagedFileMissing)
        guard case .rejected = FolderPlacer.failure(CocoaError(.fileWriteNoPermission)) else {
            Issue.record("anything else is rejected")
            return
        }
    }

    @Test("A move refused because iCloud Drive went away fails the unit as .stagingUnavailable, nothing placed")
    func iCloudGoneMidJob() async throws {
        let s = try Scratch()
        let mover = ScriptedMover(failOnPlace: 1, error: NSError(domain: NSCocoaErrorDomain, code: 4353))
        let d = destination(s, mover: mover)
        let file = try s.stage("A.ARW", date: date)
        await #expect(throws: ImportDestinationFailure.stagingUnavailable) {
            try await d.commit(.single(file))
        }
        #expect(FileManager.default.fileExists(atPath: file.url.path), "still staged, for the fallback")
    }
}

/// A mover that records its calls, moves with `FileManager`, and can refuse its nth `place`.
final class ScriptedMover: StagedFileMover, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var places = 0
    private let failOnPlace: Int?
    private let error: (any Error)?
    let setsDateAfterPlacing: Bool

    init(failOnPlace: Int? = nil, error: (any Error)? = nil, setsDateAfterPlacing: Bool = true) {
        self.failOnPlace = failOnPlace
        self.error = error
        self.setsDateAfterPlacing = setsDateAfterPlacing
    }

    var calls: [String] { lock.withLock { log } }

    func place(_ staged: URL, at target: URL) throws {
        let n: Int = lock.withLock {
            places += 1
            log.append("place \(target.lastPathComponent)")
            return places
        }
        if n == failOnPlace, let error { throw error }
        try FileManager.default.moveItem(at: staged, to: target)
    }

    func takeBack(_ target: URL, to staged: URL) throws {
        lock.withLock { log.append("takeBack \(target.lastPathComponent)") }
        try FileManager.default.moveItem(at: target, to: staged)
    }
}

@Suite("Folder names")
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
        #expect(FilesFolderNaming.folderName(forCamera: "Staging") == "Staging camera")
        #expect(FilesFolderNaming.folderName(forCamera: "staging") == "staging camera")
        #expect(FilesFolderNaming.folderName(forCamera: "Staging 2") == "Staging 2")
        #expect(FilesFolderNaming.folderName(forCamera: String(repeating: "z", count: 200)).count == 64)
    }

    @Test("A camera named Staging, Inbox, hidden or very long gets a safe folder under Staging")
    func stagingCameraFolders() throws {
        let s = try Scratch()
        func path(_ camera: String) -> String {
            StagingFolderDestination(root: s.root, place: .iCloudDrive, cameraName: camera,
                                     timeZone: TimeZone(identifier: "UTC")!).cameraFolderPath
        }
        #expect(path("Staging") == "Staging/Staging camera")
        #expect(path("Inbox") == "Staging/Inbox camera")
        #expect(path(".hidden") == "Staging/hidden")
        #expect(path(String(repeating: "z", count: 200)) == "Staging/" + String(repeating: "z", count: 64))
    }

    @Test func fileNames() {
        #expect(FilesFolderNaming.fileName(forCameraFile: "DSC00001.ARW") == "DSC00001.ARW")
        #expect(FilesFolderNaming.fileName(forCameraFile: "../x") == "_x")
        #expect(FilesFolderNaming.fileName(forCameraFile: ".") == "unnamed")
        #expect(FilesFolderNaming.numbered("DSC00001.ARW", 2) == "DSC00001 (2).ARW")
        #expect(FilesFolderNaming.numbered("NOEXT", 3) == "NOEXT (3)")
    }
}
