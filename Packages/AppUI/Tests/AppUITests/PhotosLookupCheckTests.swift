#if DEBUG
import Foundation
import PhotosBridge
import Testing
@testable import AppUI

/// The Photos lookup check (W6-lookup): its plan, its report and its run over a fake library that searches as
/// `SystemPhotoLibrary.findAsset` does (by creation date within the query's window, then the originals, role for role).
/// The real library is run by CI's UI test (`PhotosLookupCheckUITests`), with the app's half compiled there only.
@Suite("Photos lookup check: the plan, the run and its report")
struct PhotosLookupCheckTests {
    private let now = Date(timeIntervalSince1970: 1_794_400_000.75)
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotosLookupCheckTests-\(UUID().uuidString)", isDirectory: true)

    private var plan: PhotosLookupCheck.Plan { PhotosLookupCheck.Plan(token: "0A1B2C3D", now: now) }

    private static func bytes(_ index: Int) -> Data { Data(repeating: UInt8(index + 1), count: 64) }

    /// The check over `library`, the album's contents read from it unless `albumHolds` answers for it.
    private func run(_ library: SearchingLibrary, albumHolds: Bool? = nil) async -> PhotosLookupCheck.Report {
        await PhotosLookupCheck.run(plan: plan, library: library, folder: folder, image: { index in Self.bytes(index) },
                                    albumHolds: { album, asset in
                                        if let albumHolds { return albumHolds }
                                        return await library.album(album, holds: asset)
                                    })
    }

    @Test func onlyTheLaunchArgumentAsksForTheCheck() {
        #expect(PhotosLookupCheck.isRequested(in: ["ShutterBridge", PhotosLookupCheck.launchArgument]))
        #expect(PhotosLookupCheck.isRequested(in: ["ShutterBridge", "-UITestFixture", "-PhotosLookupCheck"]))
        #expect(!PhotosLookupCheck.isRequested(in: ["ShutterBridge", "-UITestFixture"]))
        #expect(!PhotosLookupCheck.isRequested(in: ["ShutterBridge", "-PhotosLookupCheckX", "PhotosLookupCheck"]))
    }

    @Test func thePlanGivesUniqueNamesWholeSecondDatesAndAWindowProbeOutsideTheWindow() {
        #expect(plan.firstDate == Date(timeIntervalSince1970: 1_794_400_000 - 86_400))
        #expect(plan.name(.libraryOnly) == "LKP0A1B2C3DA.JPG")
        #expect(plan.name(.outsideWindow) == plan.name(.libraryOnly))
        #expect(Set([plan.name(.libraryOnly), plan.name(.inAlbum), plan.name(.neverSaved)]).count == 3)
        #expect(plan.date(.neverSaved) == plan.firstDate)
        // Each saved asset outside the other's window, and the window probe outside the first's.
        #expect(!plan.query(.libraryOnly).dateRange.contains(plan.date(.inAlbum)))
        #expect(!plan.query(.inAlbum).dateRange.contains(plan.date(.libraryOnly)))
        #expect(!plan.query(.outsideWindow).dateRange.contains(plan.date(.libraryOnly)))
        #expect(!plan.query(.outsideWindow).dateRange.contains(plan.date(.inAlbum)))

        let tokens = Set((0 ..< 20).map { _ in PhotosLookupCheck.Plan.makeToken() })
        #expect(tokens.count == 20)
        #expect(tokens.allSatisfy { $0.count == 8 && $0.allSatisfy(\.isHexDigit) })
    }

    @Test func theQueriesAreTheEnginesForALoneJPEG() throws {
        let query = plan.query(.inAlbum)
        #expect(query.creationDate == plan.date(.inAlbum))
        #expect(query.resources.map(\.role) == [.photo])
        #expect(query.resources.map(\.originalFilename) == [plan.name(.inAlbum)])
        let engines = try #require(AssetQuery(AssetCreation(
            unit: .single(StagedFile(url: URL(fileURLWithPath: "/elsewhere"), filename: plan.name(.inAlbum),
                                     captureDate: plan.date(.inAlbum))),
            options: PhotosImportOptions())))
        #expect(query.matches([AssetQuery.Original(role: .photo, originalFilename: plan.name(.inAlbum))]))
        #expect(engines.creationDate == query.creationDate)
        #expect(engines.resources.map(\.originalFilename) == query.resources.map(\.originalFilename))
    }

    @Test func aRunOverALibraryThatSearchesAsPhotosDoesPasses() async throws {
        let library = SearchingLibrary(access: .authorised)
        let report = await run(library)
        #expect(report.finished)
        #expect(report.passed, "\(report.summary)")
        #expect(report.summary == "Photos lookup check finished: access=authorised; save.libraryOnly=saved; "
            + "save.inAlbum=saved; album=created; album.holdsAsset=yes; lookup.libraryOnly=found; "
            + "lookup.inAlbum=found; "
            + "lookup.neverSaved=not found; lookup.outsideWindow=not found; verdict=pass")

        // What the saves gave the library: one asset each, with the plan's name and date; the second in the album.
        let assets = await library.assets
        #expect(assets.map(\.name) == [plan.name(.libraryOnly), plan.name(.inAlbum)])
        #expect(assets.map(\.date) == [plan.date(.libraryOnly), plan.date(.inAlbum)])
        #expect(await library.albumTitles == [plan.album.title])
        #expect(await library.albumContents.values.flatMap { $0 } == [assets[1].id])
        // The JPEGs' folder is gone (the destination deleted each file it saved; the run removes the folder).
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func withoutFullAccessNothingIsSavedAndTheCheckFails() async {
        for access in [PhotosAuthorisation.limited, .notDetermined, .denied, .restricted] {
            let library = SearchingLibrary(access: access)
            let report = await run(library, albumHolds: true)
            #expect(report.finished)
            #expect(!report.passed)
            #expect(report.summary == "Photos lookup check finished: access=\(access.rawValue); verdict=fail")
            #expect(await library.assets.isEmpty)
        }
    }

    @Test func aLookupThatFindsNothingOrTheWrongAssetFailsTheCheck() async {
        for search in [SearchingLibrary.Search.nothing, .firstAssetAlways, .cannot] {
            let report = await run(SearchingLibrary(access: .authorised, search: search))
            #expect(report.finished)
            #expect(!report.passed, "\(search)")
            #expect(report.values["verdict"] == "fail")
            switch search {
            case .nothing:
                #expect(report.values["lookup.libraryOnly"] == "not found")
            case .firstAssetAlways:
                #expect(report.values["lookup.libraryOnly"] == "found")
                #expect(report.values["lookup.inAlbum"] == "found another asset")
                #expect(report.values["lookup.neverSaved"] == "found")
            case .cannot:
                #expect(report.values["lookup.inAlbum"] == "cannot search")
            case .asPhotos:
                break
            }
        }
    }

    @Test func aSaveThatFailsOrAnAlbumNotHoldingTheAssetFailsTheCheck() async {
        let refused = await run(SearchingLibrary(access: .authorised, refuseSaves: true), albumHolds: true)
        #expect(!refused.passed)
        #expect(refused.values["save.libraryOnly"]?.hasPrefix("failed: ") == true)
        #expect(refused.values["album.holdsAsset"] == nil)
        #expect(refused.values["lookup.libraryOnly"] == "not found")
        // A detail's ";" and "=" don't break the entries apart.
        #expect(refused.entries.allSatisfy { !$0.value.contains(";") && !$0.value.contains("=") })

        let notHeld = await run(SearchingLibrary(access: .authorised), albumHolds: false)
        #expect(!notHeld.passed)
        #expect(notHeld.values["album.holdsAsset"] == "no")
        #expect(notHeld.values["lookup.inAlbum"] == "found")
    }

    @Test func theReportReadsRunningUntilItHasFinished() {
        #expect(PhotosLookupCheck.Report.running.summary == "Photos lookup check running")
        #expect(!PhotosLookupCheck.Report.running.passed)
        let entry = PhotosLookupCheck.Report.Entry("detail", "a=b; c")
        #expect(entry.value == "a,b, c")
    }
}

/// A library that keeps what it is given and searches as `SystemPhotoLibrary.findAsset` does: assets whose creation
/// date is within the query's window, oldest first, the first whose originals match. Or, for the failing cases, finds
/// nothing, always the first asset, or can't search.
private actor SearchingLibrary: PhotoLibraryClient {
    enum Search: Sendable, CustomStringConvertible {
        case asPhotos, nothing, firstAssetAlways, cannot
        var description: String {
            switch self {
            case .asPhotos: "as Photos"
            case .nothing: "nothing"
            case .firstAssetAlways: "the first asset always"
            case .cannot: "cannot search"
            }
        }
    }

    struct Asset: Sendable {
        var id: String
        var name: String
        var role: AssetCreation.Role
        var date: Date?
    }

    private let access: PhotosAuthorisation
    private let search: Search
    private let refuseSaves: Bool
    private(set) var assets: [Asset] = []
    private(set) var albumTitles: [String] = []
    private(set) var albumContents: [String: [String]] = [:]

    init(access: PhotosAuthorisation, search: Search = .asPhotos, refuseSaves: Bool = false) {
        self.access = access
        self.search = search
        self.refuseSaves = refuseSaves
    }

    func authorisation() async -> PhotosAuthorisation { access }
    func requestReadWriteAuthorisation() async -> PhotosAuthorisation { access }

    func album(withIdentifier identifier: String) async -> AlbumLookup {
        albumContents[identifier] == nil ? .missing : .found(canAddContent: true)
    }

    func createAlbum(titled title: String) async throws(PhotoLibraryFailure) -> String {
        albumTitles.append(title)
        let id = "album-\(albumTitles.count)"
        albumContents[id] = []
        return id
    }

    func save(_ asset: AssetCreation, toAlbums albumIdentifiers: [String]) async throws(PhotoLibraryFailure) -> String {
        if refuseSaves {
            throw PhotoLibraryFailure(domain: "Fake", code: 1, detail: "refused; code=1")
        }
        let id = "asset-\(assets.count + 1)"
        for resource in asset.resources {
            assets.append(Asset(id: id, name: resource.originalFilename, role: resource.role, date: asset.creationDate))
        }
        for album in albumIdentifiers { albumContents[album, default: []].append(id) }
        return id
    }

    func findAsset(_ query: AssetQuery) async -> AssetSearch {
        switch search {
        case .cannot:
            return .cannotSearch
        case .nothing:
            return .notFound(underLimitedAccess: false)
        case .firstAssetAlways:
            return assets.first.map { .found(localIdentifier: $0.id) } ?? .notFound(underLimitedAccess: false)
        case .asPhotos:
            let candidates = assets
                .filter { asset in asset.date.map { query.dateRange.contains($0) } ?? false }
                .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            for asset in candidates
            where query.matches([AssetQuery.Original(role: asset.role, originalFilename: asset.name)]) {
                return .found(localIdentifier: asset.id)
            }
            return .notFound(underLimitedAccess: false)
        }
    }

    func album(_ album: String, holds asset: String) -> Bool {
        albumContents[album]?.contains(asset) ?? false
    }
}
#endif
