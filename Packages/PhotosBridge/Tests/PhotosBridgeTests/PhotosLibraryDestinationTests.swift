import Foundation
import Testing
@testable import PhotosBridge

/// A Photos library in memory: albums by identifier, saved assets, and failures to inject.
actor FakePhotoLibrary: PhotoLibraryClient {
    private var status: PhotosAuthorisation
    private let answer: PhotosAuthorisation
    private(set) var requests = 0
    private(set) var albums: [String: (title: String, canAdd: Bool, assets: [String])] = [:]
    private(set) var saved: [(asset: AssetCreation, albums: [String])] = []
    private(set) var createdAlbumTitles: [String] = []
    private var counter = 0
    var saveFailure: PhotoLibraryFailure?
    var createFailure: PhotoLibraryFailure?
    /// How long `createAlbum` suspends before it creates, so concurrent commits overlap inside it.
    var createDelay: Duration?

    init(authorisation: PhotosAuthorisation = .authorised, answer: PhotosAuthorisation = .authorised) {
        status = authorisation
        self.answer = answer
    }

    func authorisation() -> PhotosAuthorisation { status }

    func requestReadWriteAuthorisation() -> PhotosAuthorisation {
        requests += 1
        if status == .notDetermined { status = answer }
        return status
    }

    func album(withIdentifier identifier: String) -> AlbumLookup {
        guard let album = albums[identifier] else { return .missing }
        return .found(canAddContent: album.canAdd)
    }

    func createAlbum(titled title: String) async throws(PhotoLibraryFailure) -> String {
        if let createDelay { try? await Task.sleep(for: createDelay) }
        if let createFailure { throw createFailure }
        counter += 1
        let id = "ALBUM-\(counter)/L0/040"
        albums[id] = (title, true, [])
        createdAlbumTitles.append(title)
        return id
    }

    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) throws(PhotoLibraryFailure) -> String {
        if let saveFailure { throw saveFailure }
        counter += 1
        let id = "ASSET-\(counter)/L0/001"
        saved.append((asset, albumIdentifiers))
        for a in albumIdentifiers where albums[a]?.canAdd == true { albums[a]?.assets.append(id) }
        return id
    }

    func setAuthorisation(_ s: PhotosAuthorisation) { status = s }
    func setSaveFailure(_ f: PhotoLibraryFailure?) { saveFailure = f }
    func setCreateFailure(_ f: PhotoLibraryFailure?) { createFailure = f }
    func setCreateDelay(_ d: Duration?) { createDelay = d }
    func deleteAlbum(_ id: String) { albums[id] = nil }
    func addAlbum(_ id: String, title: String, canAdd: Bool) { albums[id] = (title, canAdd, []) }
}

struct FakeMetadata: PhotoMetadataReader {
    var byName: [String: GPSLocation]
    func gpsLocation(ofFileAt url: URL) async -> GPSLocation? { byName[url.lastPathComponent] }
}

/// A temporary folder with staged files in it, removed at the end of each test.
final class Scratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A staged file named like a download in progress, holding `bytes`.
    func stage(_ cameraName: String, date: Date? = nil, bytes: String? = nil, in folder: String = "staging") throws -> StagedFile {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".part")
        try Data((bytes ?? cameraName).utf8).write(to: url)
        return StagedFile(url: url, filename: cameraName, captureDate: date)
    }
}

@Suite("Photos destination logic (fake library)")
struct PhotosLibraryDestinationTests {
    let date = Date(timeIntervalSince1970: 1_793_142_018)

    func plan(_ choice: PhotosImportOptions.Albums = .perCamera) -> AlbumPlan {
        AlbumPlan(choice: choice, cameraKey: "serial-1", cameraName: "ILCE-7CM2", importID: "job-1", importDate: date,
                  importTitle: "ILCE-7CM2, 8 Nov")
    }

    @Test("A pair is one asset: JPEG as .photo, ARW as .alternatePhoto, RAW original by default, capture date on it")
    func pairIsOneAsset() async throws {
        let s = try Scratch()
        let raw = try s.stage("DSC01779.ARW", date: date), jpg = try s.stage("DSC01779.JPG", date: date)
        let library = FakePhotoLibrary()
        let d = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(), albumPlan: plan())
        let result = try await d.commit(.pair(raw: raw, processed: jpg))
        guard case let .photosAsset(id) = result else { Issue.record("not an asset: \(result)"); return }
        #expect(id.hasPrefix("ASSET-"))
        let saved = await library.saved
        #expect(saved.count == 1)
        let asset = try #require(saved.first?.asset)
        #expect(asset.resources.map(\.role) == [.photo, .alternatePhoto])
        #expect(asset.resources.map(\.originalFilename) == ["DSC01779.JPG", "DSC01779.ARW"])
        #expect(asset.resources.map(\.fileURL) == [jpg.url, raw.url])
        #expect(asset.originalChoice == .raw)
        #expect(asset.creationDate == date)
        // Consumed after a successful save.
        #expect(!FileManager.default.fileExists(atPath: raw.url.path))
        #expect(!FileManager.default.fileExists(atPath: jpg.url.path))
    }

    @Test("The commit target is the library, whatever the albums")
    func commitTargetIsTheLibrary() throws {
        let s = try Scratch()
        let d = PhotosLibraryDestination(library: FakePhotoLibrary(), albumStore: InMemoryAlbumIdentifierStore(),
                                         albumPlan: plan(.perImport))
        #expect(d.commitTarget(for: .single(try s.stage("A.JPG", date: date))) == .photosLibrary)
        let e = PhotosLibraryDestination(library: FakePhotoLibrary(), albumStore: InMemoryAlbumIdentifierStore(),
                                         albumPlan: plan())
        #expect(e.commitTarget(for: .pair(raw: try s.stage("A.ARW"), processed: try s.stage("A.JPG"))) == .photosLibrary)
    }

    @Test("The person's original choice is passed through; a lone file has none")
    func originalChoice() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        let d = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(),
                                         options: PhotosImportOptions(pairOriginal: .processed), albumPlan: plan())
        _ = try await d.commit(.pair(raw: try s.stage("A.ARW"), processed: try s.stage("A.HIF")))
        _ = try await d.commit(.single(try s.stage("B.ARW", date: date)))
        let saved = await library.saved
        #expect(saved[0].asset.originalChoice == .processed)
        #expect(saved[1].asset.originalChoice == nil)
        #expect(saved[1].asset.resources.map(\.role) == [.photo])
    }

    @Test("The album is created once, stored, and found by its identifier after a relaunch")
    func albumCreatedOnceAndFound() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        let store = InMemoryAlbumIdentifierStore()
        let first = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan())
        _ = try await first.commit(.single(try s.stage("A.JPG")))
        _ = try await first.commit(.single(try s.stage("B.JPG")))
        // A new destination (the next import, or a relaunch) with the same store.
        let second = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan())
        _ = try await second.commit(.single(try s.stage("C.JPG")))
        #expect(await library.createdAlbumTitles == ["ILCE-7CM2"])
        let stored = try #require(await store.albumIdentifier(forKey: "camera:serial-1"))
        #expect(await library.saved.allSatisfy { $0.albums == [stored] })
        #expect(await library.albums[stored]?.assets.count == 3)
    }

    @Test("Overlapping commits create the album once and both photos go into it")
    func concurrentCommitsCreateOnce() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        await library.setCreateDelay(.milliseconds(50))
        let store = InMemoryAlbumIdentifierStore()
        let d = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan(.both))
        let a = try s.stage("A.JPG"), b = try s.stage("B.JPG"), c = try s.stage("C.JPG")
        async let first = d.commit(.single(a))
        async let second = d.commit(.single(b))
        async let third = d.commit(.single(c))
        _ = try await (first, second, third)
        #expect(await library.createdAlbumTitles == ["ILCE-7CM2", "ILCE-7CM2, 8 Nov"])
        let stored = await store.all
        #expect(await library.saved.allSatisfy { Set($0.albums) == Set(stored.values) })
        for id in stored.values { #expect(await library.albums[id]?.assets.count == 3) }
    }

    @Test("Another album with the same title doesn't matter: the identifier finds ours")
    func titleClash() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        await library.addAlbum("SOMEONE-ELSES", title: "ILCE-7CM2", canAdd: true)
        await library.addAlbum("OURS", title: "ILCE-7CM2", canAdd: true)
        let store = InMemoryAlbumIdentifierStore(["camera:serial-1": "OURS"])
        let d = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan())
        _ = try await d.commit(.single(try s.stage("A.JPG")))
        #expect(await library.saved.first?.albums == ["OURS"])
        #expect(await library.createdAlbumTitles.isEmpty)
    }

    @Test("A deleted album is made again and the new identifier stored")
    func deletedAlbum() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        let store = InMemoryAlbumIdentifierStore(["camera:serial-1": "GONE"])
        let d = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan())
        _ = try await d.commit(.single(try s.stage("A.JPG")))
        let stored = try #require(await store.albumIdentifier(forKey: "camera:serial-1"))
        #expect(stored != "GONE")
        #expect(await library.createdAlbumTitles == ["ILCE-7CM2"])
    }

    @Test("An album that refuses new content: the photo is saved without it, noted, and the album not replaced")
    func albumRefusesContent() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        await library.addAlbum("SHARED", title: "ILCE-7CM2", canAdd: false)
        let store = InMemoryAlbumIdentifierStore(["camera:serial-1": "SHARED"])
        let d = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan())
        _ = try await d.commit(.single(try s.stage("A.JPG")))
        #expect(await library.saved.first?.albums == [])
        #expect(await d.albumIssues == [.doesNotAcceptPhotos(key: "camera:serial-1")])
        #expect(await store.albumIdentifier(forKey: "camera:serial-1") == "SHARED")
        #expect(await library.createdAlbumTitles.isEmpty)
    }

    @Test("Both albums: per camera and per import, each created once")
    func bothAlbums() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        let store = InMemoryAlbumIdentifierStore()
        let d = PhotosLibraryDestination(library: library, albumStore: store, albumPlan: plan(.both))
        _ = try await d.commit(.single(try s.stage("A.JPG")))
        _ = try await d.commit(.single(try s.stage("B.JPG")))
        #expect(await library.createdAlbumTitles == ["ILCE-7CM2", "ILCE-7CM2, 8 Nov"])
        #expect(await library.saved.allSatisfy { $0.albums.count == 2 })
        #expect(await store.all.keys.sorted() == ["camera:serial-1", "import:job-1"])
    }

    @Test("3311 on a save is a denial, not a failed file, and the staged files stay for staging")
    func deniedSave() async throws {
        let s = try Scratch()
        let raw = try s.stage("A.ARW"), jpg = try s.stage("A.JPG")
        let library = FakePhotoLibrary()
        await library.setSaveFailure(PhotoLibraryFailure(domain: "PHPhotosErrorDomain", code: 3311))
        let d = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(), albumPlan: plan())
        await #expect(throws: ImportDestinationFailure.photosAccessDenied) {
            try await d.commit(.pair(raw: raw, processed: jpg))
        }
        #expect(FileManager.default.fileExists(atPath: raw.url.path))
        #expect(FileManager.default.fileExists(atPath: jpg.url.path))

        // The engine's next step: the staging folder takes the same staged files.
        let staging = StagingFolderDestination(root: s.root.appendingPathComponent("Documents"),
                                               place: .onThisIPhone(.containerUnavailable), cameraName: "ILCE-7CM2",
                                               timeZone: TimeZone(identifier: "UTC")!)
        let result = try await staging.commit(.pair(raw: raw, processed: jpg))
        #expect(result == .staged(place: .onThisIPhone(.containerUnavailable),
                                  [FileLocation(relativePath: "Staging/ILCE-7CM2/Undated/A.ARW"),
                                   FileLocation(relativePath: "Staging/ILCE-7CM2/Undated/A.JPG")]))
    }

    @Test("3311 while creating the album is a denial too")
    func deniedAlbum() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        await library.setCreateFailure(PhotoLibraryFailure(domain: "PHPhotosErrorDomain", code: 3311))
        let d = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(), albumPlan: plan())
        await #expect(throws: ImportDestinationFailure.photosAccessDenied) {
            try await d.commit(.single(try s.stage("A.JPG")))
        }
        #expect(await library.saved.isEmpty)
    }

    @Test("Another album failure saves the photo without the album and notes it")
    func albumCreateFails() async throws {
        let s = try Scratch()
        let library = FakePhotoLibrary()
        await library.setCreateFailure(PhotoLibraryFailure(domain: "PHPhotosErrorDomain", code: -1, detail: "x"))
        let d = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(), albumPlan: plan())
        _ = try await d.commit(.single(try s.stage("A.JPG")))
        #expect(await library.saved.count == 1)
        #expect(await d.albumIssues.count == 1)
    }

    @Test func missingStagedFile() async throws {
        let library = FakePhotoLibrary()
        let d = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(), albumPlan: plan())
        let gone = StagedFile(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), filename: "A.JPG", captureDate: nil)
        await #expect(throws: ImportDestinationFailure.stagedFileMissing) { try await d.commit(.single(gone)) }
        #expect(await library.saved.isEmpty)
    }

    @Test("The position comes from the JPEG first, then the ARW")
    func location() async throws {
        let s = try Scratch()
        let raw = try s.stage("A.ARW"), jpg = try s.stage("A.JPG"), lone = try s.stage("B.ARW")
        let here = GPSLocation(latitude: 51.5, longitude: -0.12), there = GPSLocation(latitude: 1, longitude: 2)
        let metadata = FakeMetadata(byName: [raw.url.lastPathComponent: there, jpg.url.lastPathComponent: here,
                                             lone.url.lastPathComponent: there])
        let library = FakePhotoLibrary()
        let d = PhotosLibraryDestination(library: library, albumStore: InMemoryAlbumIdentifierStore(), metadata: metadata,
                                         albumPlan: plan())
        _ = try await d.commit(.pair(raw: raw, processed: jpg))
        _ = try await d.commit(.single(lone))
        let saved = await library.saved
        #expect(saved[0].asset.location == here)
        #expect(saved[1].asset.location == there)
    }
}

@Suite("Photos error mapping")
struct PhotosErrorMappingTests {
    @Test func mapping() {
        func map(_ domain: String, _ code: Int) -> ImportDestinationFailure {
            ImportDestinationFailure(photoLibraryFailure: PhotoLibraryFailure(domain: domain, code: code, detail: "d"))
        }
        #expect(map("PHPhotosErrorDomain", 3311) == .photosAccessDenied)
        #expect(map("PHPhotosErrorDomain", 3310) == .photosAccessDenied)
        #expect(map("PHPhotosErrorDomain", 3305) == .notEnoughSpace)
        #expect(map("PHPhotosErrorDomain", 3303) == .stagedFileMissing)
        #expect(map(NSCocoaErrorDomain, 4) == .stagedFileMissing)
        #expect(map(NSCocoaErrorDomain, 640) == .notEnoughSpace)
        #expect(map("PHPhotosErrorDomain", 3302) == .rejected(detail: "PHPhotosErrorDomain 3302: d"))
        #expect(map("OtherDomain", 3311) == .rejected(detail: "OtherDomain 3311: d"))
    }

    @Test func fromNSError() {
        let f = PhotoLibraryFailure(NSError(domain: "PHPhotosErrorDomain", code: 3311))
        #expect(f.domain == "PHPhotosErrorDomain" && f.code == 3311)
    }
}

@Suite("Resource types")
struct ResourceTypeTests {
    @Test("The camera's extensions map to declared types, HIF included; others are left to the system")
    func knownTypes() {
        func type(_ name: String) -> String? {
            AssetCreation.Resource(role: .photo, fileURL: URL(fileURLWithPath: "/s/x.part"), originalFilename: name)
                .knownTypeIdentifier
        }
        #expect(type("DSC01779.ARW") == "com.sony.arw-raw-image")
        #expect(type("DSC01779.JPG") == "public.jpeg")
        #expect(type("a.jpeg") == "public.jpeg")
        #expect(type("DSC01779.HIF") == "public.heif")
        #expect(type("a.heif") == "public.heif")
        #expect(type("a.HEIC") == "public.heic")
        #expect(type("a.MP4") == nil)
        #expect(type("noextension") == nil)
    }

    @Test("A RAW+HIF pair's resources carry the HEIF and ARW types")
    func hifPair() {
        let raw = StagedFile(url: URL(fileURLWithPath: "/s/1.part"), filename: "DSC1.ARW", captureDate: nil)
        let hif = StagedFile(url: URL(fileURLWithPath: "/s/2.part"), filename: "DSC1.HIF", captureDate: nil)
        let asset = AssetCreation(unit: .pair(raw: raw, processed: hif), options: PhotosImportOptions())
        #expect(asset.resources.map(\.knownTypeIdentifier) == ["public.heif", "com.sony.arw-raw-image"])
    }
}

@Suite("Album plan")
struct AlbumPlanTests {
    @Test func choices() {
        let d = Date(timeIntervalSince1970: 0)
        let camera = AlbumPlan(choice: .perCamera, cameraKey: "k", cameraName: "α7C II", importID: "j", importDate: d)
        #expect(camera.albums == [.init(key: "camera:k", title: "α7C II")])
        let job = AlbumPlan(choice: .perImport, cameraKey: "k", cameraName: "α7C II", importID: "j", importDate: d)
        #expect(job.albums.map(\.key) == ["import:j"])
        #expect(job.albums[0].title.hasPrefix("α7C II, "))
        let both = AlbumPlan(choice: .both, cameraKey: "k", cameraName: "α7C II", importID: "j", importDate: d, importTitle: "T")
        #expect(both.albums == [.init(key: "camera:k", title: "α7C II"), .init(key: "import:j", title: "T")])
    }
}

@Suite("GPS from EXIF")
struct GPSLocationTests {
    @Test("South and west are negative; altitude below sea level is negative; the fix time is UTC")
    func references() throws {
        let g = try #require(GPSLocation(exifGPS: [
            "Latitude": 33.8688, "LatitudeRef": "S", "Longitude": 151.2093, "LongitudeRef": "E",
            "Altitude": 12.5, "AltitudeRef": 1, "DateStamp": "2026:11:05", "TimeStamp": "09:41:07.25",
        ]))
        #expect(g.latitude == -33.8688 && g.longitude == 151.2093)
        #expect(g.altitude == -12.5)
        var c = DateComponents(year: 2026, month: 11, day: 5, hour: 9, minute: 41, second: 7)
        c.timeZone = TimeZone(identifier: "UTC")
        let expected = try #require(Calendar(identifier: .gregorian).date(from: c)).addingTimeInterval(0.25)
        #expect(abs(try #require(g.timestamp).timeIntervalSince(expected)) < 0.001)
    }

    @Test func westAndNumbers() throws {
        let g = try #require(GPSLocation(exifGPS: ["Latitude": NSNumber(value: 51.5), "LatitudeRef": "N",
                                                   "Longitude": "0.1276", "LongitudeRef": "W"]))
        #expect(g.latitude == 51.5 && g.longitude == -0.1276 && g.altitude == nil && g.timestamp == nil)
    }

    @Test("No position, a void fix or out-of-range values give nil")
    func unusable() {
        #expect(GPSLocation(exifGPS: [:]) == nil)
        #expect(GPSLocation(exifGPS: ["Latitude": 10.0]) == nil)
        #expect(GPSLocation(exifGPS: ["Latitude": 10.0, "Longitude": 20.0, "Status": "V"]) == nil)
        #expect(GPSLocation(exifGPS: ["Latitude": 91.0, "Longitude": 20.0]) == nil)
        #expect(GPSLocation(exifGPS: ["Latitude": Double.nan, "Longitude": 20.0]) == nil)
        #expect(GPSLocation(exifGPS: ["Latitude": 10.0, "Longitude": 20.0, "Status": "A"]) != nil)
    }
}
