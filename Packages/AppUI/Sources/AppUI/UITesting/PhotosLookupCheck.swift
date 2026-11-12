#if DEBUG
import Foundation
import PhotosBridge

/// The Photos lookup check (W6-lookup; backlog section 3.1): with `launchArgument` on its command line, a Debug build
/// shows this check instead of the app, and the UI test `PhotosLookupCheckUITests` reads its report, so CI runs
/// `SystemPhotoLibrary.findAsset(_:)` against assets saved in the Simulator's real library before the bench does.
/// Package test bundles can't easily be given Photos access (no usage description, no known host bundle), the app can:
/// CI grants it full access on the Simulator before the UI tests (`app.yml`). Debug builds only (`#if DEBUG`), so a
/// Release build, and so every TestFlight build, has none of it.
///
/// What it does, in order (`run`):
///
/// 1. reads the access without asking; anything but full access ends the check, failed, before anything is saved
///    (a save would prompt);
/// 2. saves two small JPEGs through the app's own Photos destination (`PhotosLibraryDestination` over the library, so
///    `PHAssetCreationRequest` with the original file name and the creation date set as an import sets them), each
///    with a name unique to the run and a whole-second creation date: one into the library only (no album in the
///    plan), one also into an album the destination creates, as an import's album is made;
/// 3. checks the album holds the second asset;
/// 4. looks each up with the `AssetQuery` the engine builds for a pending commit (`AssetQuery(AssetCreation(unit:
///    options:))`, as `PendingCommit.assetCreation` lays it out): both expected found, as the asset the save
///    returned; then a name never saved and the first asset's name at a creation date 30 s off, outside the ±1 s
///    window, both expected not found.
///
/// The assets and the album stay in the Simulator's library (deleting them would show a confirmation); names unique
/// to each run keep runs apart. Nothing is logged. Plain Foundation over `PhotoLibraryClient`, tested on Linux with
/// a fake library (`PhotosLookupCheckTests`); the app's half (the view, the library, the album's contents) is
/// `PhotosLookupCheck+Live.swift`.
enum PhotosLookupCheck {
    /// The launch argument that asks for the check. The UI test passes `UITestFixture.launchArgument` too, so the app
    /// composed behind the check is the seeded one and the live app's stores are never opened.
    static let launchArgument = "-PhotosLookupCheck"

    /// The report's accessibility identifier, which the UI test finds it by.
    static let accessibilityIdentifier = "photos-lookup-check"

    /// Whether `arguments` (the process's, by default) ask for the check.
    static func isRequested(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    /// What the check looks for, by the role it plays.
    enum Probe: String, CaseIterable, Sendable {
        /// The asset saved into the library only.
        case libraryOnly
        /// The asset saved into the library and an album.
        case inAlbum
        /// A name no asset was given, at the first asset's date.
        case neverSaved
        /// The first asset's name at a date outside the ±1 s window.
        case outsideWindow

        /// Whether the lookup should find the asset.
        var expectsFound: Bool {
            switch self {
            case .libraryOnly, .inAlbum: true
            case .neverSaved, .outsideWindow: false
            }
        }
    }

    /// One run's names, dates and album.
    struct Plan: Sendable, Hashable {
        /// What makes this run's names its own: eight characters, digits and "A"–"F".
        var token: String
        /// The first asset's creation date: a whole second.
        var firstDate: Date

        /// - Parameter now: the run's start; the first asset is dated a day before, to the whole second (an import
        ///   gives the camera's whole second).
        init(token: String, now: Date) {
            self.token = token
            firstDate = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 86_400).rounded(.down))
        }

        /// Eight hexadecimal characters from a fresh UUID.
        static func makeToken() -> String {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        }

        /// The name a probe looks for (and the saved assets were given).
        func name(_ probe: Probe) -> String {
            switch probe {
            case .libraryOnly, .outsideWindow: "LKP\(token)A.JPG"
            case .inAlbum: "LKP\(token)B.JPG"
            case .neverSaved: "LKP\(token)C.JPG"
            }
        }

        /// The date a probe looks at: the second asset 10 s after the first, outside each other's windows; the
        /// window probe 30 s before the first.
        func date(_ probe: Probe) -> Date {
            switch probe {
            case .libraryOnly, .neverSaved: firstDate
            case .inAlbum: firstDate.addingTimeInterval(10)
            case .outsideWindow: firstDate.addingTimeInterval(-30)
            }
        }

        /// The album the second asset goes into, made by the destination as an import's album is.
        var album: AlbumPlan.Album {
            AlbumPlan.Album(key: "import:photos-lookup-check-" + token, title: "Lookup Check " + token)
        }

        /// The query the engine builds for a pending Photos commit of this file: a lone file as `.photo`, its name
        /// and date (`PendingCommit.assetCreation`, then `AssetQuery(_:)`).
        func query(_ probe: Probe) -> AssetQuery {
            let file = StagedFile(url: URL(fileURLWithPath: "/dev/null"), filename: name(probe),
                                  captureDate: date(probe))
            let asset = AssetCreation(unit: .single(file), options: PhotosImportOptions())
            return AssetQuery(asset) ?? AssetQuery(creationDate: date(probe), resources: asset.resources)
        }
    }

    /// What a lookup answered, as the report says it.
    enum Outcome: Sendable, Hashable {
        /// Found; `sameAsset` when it is the asset the save returned.
        case found(sameAsset: Bool)
        case notFound(underLimitedAccess: Bool)
        case cannotSearch

        init(_ search: AssetSearch, saved: String?) {
            switch search {
            case let .found(identifier): self = .found(sameAsset: saved != nil && identifier == saved)
            case let .notFound(limited): self = .notFound(underLimitedAccess: limited)
            case .cannotSearch: self = .cannotSearch
            }
        }

        var word: String {
            switch self {
            case .found(sameAsset: true): "found"
            case .found(sameAsset: false): "found another asset"
            case .notFound(underLimitedAccess: false): "not found"
            case .notFound(underLimitedAccess: true): "not found under Limited Access"
            case .cannotSearch: "cannot search"
            }
        }
    }

    /// The check's report: entries in order, each "key=value", and the verdict.
    struct Report: Sendable, Hashable {
        struct Entry: Sendable, Hashable {
            var key: String
            var value: String

            /// ";" and "=" in a value (an error's detail) become ",", so the report stays readable as entries.
            init(_ key: String, _ value: String) {
                self.key = key
                self.value = value.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "=", with: ",")
            }
        }

        var finished: Bool
        var entries: [Entry]

        /// The report before the check has finished.
        static let running = Report(finished: false, entries: [])

        /// The entries by key.
        var values: [String: String] {
            Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        /// Whether everything came out as expected; false until the check has finished.
        var passed: Bool {
            finished && values["verdict"] == "pass"
        }

        /// One line for the screen and the UI test: "Photos lookup check finished: key=value; key=value", or
        /// "Photos lookup check running" before it has.
        var summary: String {
            guard finished else { return "Photos lookup check running" }
            return "Photos lookup check finished: " + entries.map { $0.key + "=" + $0.value }.joined(separator: "; ")
        }
    }

    /// Runs the check (see the type's comment).
    ///
    /// - Parameters:
    ///   - folder: where the JPEGs are written before they are saved (emptied first, removed after; the destination
    ///     deletes each file it saved).
    ///   - image: the bytes of the JPEG at an index (0 for the first asset, 1 for the second).
    ///   - albumHolds: whether the album with the first identifier holds the asset with the second.
    static func run(plan: Plan, library: any PhotoLibraryClient, folder: URL, image: @Sendable (Int) -> Data,
                    albumHolds: @Sendable (_ album: String, _ asset: String) async -> Bool) async -> Report {
        var entries: [Report.Entry] = []
        var good = true
        func finish() -> Report {
            entries.append(Report.Entry("verdict", good ? "pass" : "fail"))
            return Report(finished: true, entries: entries)
        }

        let access = await library.authorisation()
        entries.append(Report.Entry("access", access.rawValue))
        guard access == .authorised else {
            good = false
            return finish()
        }

        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        defer { try? fm.removeItem(at: folder) }

        // 2. The two saves, through the app's destination.
        var saved: [Probe: String] = [:]
        let albumStore = InMemoryAlbumIdentifierStore()
        for (index, probe) in [Probe.libraryOnly, .inAlbum].enumerated() {
            let albums = probe == .inAlbum ? AlbumPlan(albums: [plan.album]) : AlbumPlan(albums: [])
            let destination = PhotosLibraryDestination(library: library, albumStore: albumStore, albumPlan: albums)
            let url = folder.appendingPathComponent(plan.name(probe), isDirectory: false)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try image(index).write(to: url, options: .atomic)
            } catch {
                entries.append(Report.Entry("save." + probe.rawValue, "could not write the JPEG"))
                good = false
                continue
            }
            let file = StagedFile(url: url, filename: plan.name(probe), captureDate: plan.date(probe))
            do {
                let result = try await destination.commit(.single(file))
                guard case let .photosAsset(identifier) = result else {
                    entries.append(Report.Entry("save." + probe.rawValue, "not a Photos asset"))
                    good = false
                    continue
                }
                saved[probe] = identifier
                entries.append(Report.Entry("save." + probe.rawValue, "saved"))
            } catch {
                entries.append(Report.Entry("save." + probe.rawValue, "failed: \(error)"))
                good = false
            }
            if probe == .inAlbum {
                let issues = await destination.albumIssues
                if !issues.isEmpty {
                    entries.append(Report.Entry("album.issue", "\(issues)"))
                    good = false
                }
            }
        }

        // 3. The album holds the second asset.
        let albumIdentifier = await albumStore.albumIdentifier(forKey: plan.album.key)
        entries.append(Report.Entry("album", albumIdentifier == nil ? "not created" : "created"))
        if let albumIdentifier, let asset = saved[.inAlbum] {
            let holds = await albumHolds(albumIdentifier, asset)
            entries.append(Report.Entry("album.holdsAsset", holds ? "yes" : "no"))
            good = good && holds
        } else {
            good = false
        }

        // 4. The lookups, with the engine's queries.
        for probe in Probe.allCases {
            let search = await library.findAsset(plan.query(probe))
            let expected: String? = probe.expectsFound ? saved[probe] : saved[.libraryOnly]
            let outcome = Outcome(search, saved: expected)
            entries.append(Report.Entry("lookup." + probe.rawValue, outcome.word))
            let wanted: Outcome = probe.expectsFound ? .found(sameAsset: true) : .notFound(underLimitedAccess: false)
            good = good && outcome == wanted
        }
        return finish()
    }
}
#endif
