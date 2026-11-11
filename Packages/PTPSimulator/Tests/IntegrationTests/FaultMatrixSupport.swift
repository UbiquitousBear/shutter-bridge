import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
import PTPSimulator
import SimulatedLink
import Synchronization
import Testing

// The fault-matrix harness (Iteration 2, backlog section 3; I22): the real `ImportEngine`, `InMemoryCatalogue` and a
// destination fake that records every committed unit, over `SimulatedCameraLink` (and, in `FaultMatrixWireTests`,
// the real `IPLink`), asserting after each case recovers that nothing is duplicated and nothing is lost.
//
// Everything is bounded: the engine runs on a manual clock (`CameraClock`) that moves only when a test moves it, or
// when a file is waiting out a retry delay, so no case sleeps on the wall clock; every wait polls for at most 10 s of
// real time and then records an issue and throws, rather than waiting on a continuation that nothing may resume.

// MARK: - Cases

/// The link flavours the matrix runs, by what differs between them for the engine: USB keys the camera and item IDs
/// per plugging-in and can't resume (as MTP and as MSC), Wi-Fi resumes and keeps its handles.
enum MatrixLink: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case usbMTP, usbMSC, wifi

    var mode: CameraMode {
        switch self {
        case .usbMTP: .usb(.mtp)
        case .usbMSC: .usb(.massStorage)
        case .wifi: .wifi(.cameraNetwork)
        }
    }

    var isWiFi: Bool { self == .wifi }
    var testDescription: String { rawValue }
}

/// Where a case's job goes: *Import to Photos* (an import job, with staging ready in case Photos refuses a save) or
/// *Stage* (a stage job).
enum MatrixPurpose: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case importToPhotos, stage

    var testDescription: String { rawValue }
}

/// One cell of a cut matrix: a link, how far into the file the cut falls, how many downloads were in flight, and
/// the job's purpose.
struct MatrixCase: Sendable, CustomTestStringConvertible {
    var link: MatrixLink
    var percent: UInt64
    var inFlight: Int
    var purpose: MatrixPurpose

    var testDescription: String { "\(link.rawValue) \(percent)% x\(inFlight) \(purpose.rawValue)" }

    /// Downloads really in flight: Wi-Fi's single transaction caps the setting at 1.
    var downloads: Int { link.isWiFi ? 1 : inFlight }

    static let offsets: [UInt64] = [10, 50, 99]

    /// Every USB flavour at every offset with 1 and 2 downloads in flight, for both purposes.
    static let usb: [MatrixCase] = cross(links: [.usbMTP, .usbMSC], inFlight: [1, 2])
    /// Wi-Fi at every offset, with one download in flight (the link's single transaction caps a second) and with 2
    /// asked for, which must behave the same.
    static let wifi: [MatrixCase] = cross(links: [.wifi], inFlight: [1, 2])

    /// The cases of `usb` and `wifi` at 50 %, for the cases the offset doesn't matter to.
    static let halfway: [MatrixCase] = (usb + wifi).filter { $0.percent == 50 }

    private static func cross(links: [MatrixLink], inFlight: [Int]) -> [MatrixCase] {
        links.flatMap { link in
            offsets.flatMap { percent in
                inFlight.flatMap { n in
                    MatrixPurpose.allCases.map { MatrixCase(link: link, percent: percent, inFlight: n, purpose: $0) }
                }
            }
        }
    }
}

// MARK: - The destination fake

/// A destination that records every committed unit's files by name and bytes, as read at the moment of the commit.
/// As Photos it leaves the staged file for the engine to delete (one asset per unit); as a staging folder it moves
/// each file into its folder, never overwriting, as the real one does. It can refuse the save from a given commit on
/// (Photos access revoked) or fail a given commit.
actor RecordingDestination: ImportDestination {
    struct File: Sendable, Hashable {
        var name: String
        var data: Data
    }

    nonisolated let kind: DestinationKind
    private let folder: URL
    private let place: StagingPlace

    /// Each successful commit's files, in order: a unit is one entry, so a RAW+JPEG pair is one.
    private(set) var units: [[File]] = []
    /// Every commit call, failed or not.
    private(set) var attempts = 0
    private var deniesFrom: Int?
    private var failures: [Int: ImportDestinationFailure] = [:]

    init(kind: DestinationKind, folder: URL, place: StagingPlace) {
        self.kind = kind
        self.folder = folder
        self.place = place
    }

    /// From this attempt number on (1-based), every commit is refused with `.photosAccessDenied` (3311).
    func deny(from attempt: Int) { deniesFrom = attempt }
    func fail(attempt: Int, with failure: ImportDestinationFailure) { failures[attempt] = failure }

    var files: [File] { units.flatMap { $0 } }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        attempts += 1
        if let d = deniesFrom, attempts >= d { throw .photosAccessDenied }
        if let failure = failures[attempts] { throw failure }
        var recorded: [File] = []
        for file in unit.files {
            guard let data = try? Data(contentsOf: file.url) else { throw .stagedFileMissing }
            recorded.append(File(name: file.filename, data: data))
        }
        units.append(recorded)
        switch kind {
        case .photos:
            return .photosAsset(localIdentifier: "asset-\(units.count)")
        case .staging:
            let fm = FileManager.default
            var locations: [FileLocation] = []
            for file in unit.files {
                var name = file.filename
                var n = 1
                while fm.fileExists(atPath: folder.appendingPathComponent(name).path(percentEncoded: false)) {
                    n += 1
                    let url = URL(fileURLWithPath: file.filename)
                    name = "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)"
                }
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try fm.moveItem(at: file.url, to: folder.appendingPathComponent(name))
                } catch {
                    throw .rejected(detail: "\(error)")
                }
                locations.append(FileLocation(relativePath: "Staging/" + name))
            }
            return .staged(place: place, locations)
        }
    }
}

// MARK: - The bench

struct MatrixTimeout: Error, CustomStringConvertible {
    var what: String
    var description: String { "timed out waiting for \(what)" }
}

/// One engine on a manual clock over a recording Photos fake and a recording staging fake, in a temporary folder of
/// its own. `relaunch()` makes the next engine over the same catalogue, work folder and destinations, as the app
/// does after it was killed.
final class MatrixBench {
    static let zone = TimeZone(identifier: "UTC")!
    /// Where the bench stages, as every build does until the App ID has iCloud.
    static let place = StagingPlace.onThisIPhone(.containerUnavailable)
    /// Real time any wait may take before it is a failure.
    static let patience: Duration = .seconds(10)

    let root: URL
    /// The engine's work folder (partial files live under its `Partials` folder).
    let work: URL
    let clock = CameraClock()
    let catalogue = InMemoryCatalogue()
    let photos: RecordingDestination
    let staging: RecordingDestination
    let inFlight: Int
    private(set) var engine: ImportEngine
    /// Every progress reading the waits took, for "progress never went backwards".
    private(set) var samples: [ImportProgress] = []
    /// The folder rows are keyed under when a link can't tell the folder (`IPLink` lists none): "" for the real Wi-Fi
    /// link, nil to use each file's folder on the card.
    var rowFolder: String?
    private var retired: [ImportEngine] = []
    private var links: [SimulatedCameraLink] = []

    init(inFlight: Int = 1) {
        self.inFlight = inFlight
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaultMatrix-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        photos = RecordingDestination(kind: .photos, folder: root.appendingPathComponent("photos", isDirectory: true),
                                      place: Self.place)
        staging = RecordingDestination(kind: .staging, folder: root.appendingPathComponent("staging", isDirectory: true),
                                       place: Self.place)
        engine = Self.makeEngine(catalogue: catalogue, work: work, clock: clock, inFlight: inFlight)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private static func makeEngine(catalogue: InMemoryCatalogue, work: URL, clock: CameraClock,
                                   inFlight: Int) -> ImportEngine {
        ImportEngine(catalogue: catalogue, settings: ImportSettings(downloadsInFlight: inFlight),
                     stagingDirectory: work, clock: clock, timeZone: zone)
    }

    /// The app was killed and started again: a new engine over what the first left on disk and in the catalogue.
    /// The first engine is only parked, never told anything, so nothing it would do is part of the case.
    func relaunch() {
        retired.append(engine)
        engine = Self.makeEngine(catalogue: catalogue, work: work, clock: clock, inFlight: inFlight)
        samples = []
    }

    /// Closes every link the bench made, so no held download is left waiting. Call before a test ends.
    func finish() async {
        for link in links { await link.close() }
    }

    // MARK: Cards and links

    /// RAW+JPEG frames DSC00001…, about 42 and 22 KB (the real sizes scaled down by 1,000), two seconds apart.
    static func card(frames: Int = 4, start: String = "20261101T090000") throws -> ScriptedCard {
        try #require(ScriptedCard.shoot(Array(repeating: .rawPlusJPEG, count: frames), start: start)).scaled(down: 1000)
    }

    /// A link over `card`, made as the flavour's carrier makes one, and closed by `finish()`.
    func link(_ card: ScriptedCard, _ flavour: MatrixLink, name: String = "ILCE-7CM2", descriptorID: String = "sim",
              generation: Int = 1, locationProvider: (@Sendable () -> PTPIPEndpoint)? = nil) -> SimulatedCameraLink {
        let link = SimulatedCameraLink(card: card, mode: flavour.mode, name: name, descriptorID: descriptorID,
                                       timeZone: Self.zone, generation: generation, honoursCancellation: flavour.isWiFi,
                                       chunkSize: 4096, locationProvider: locationProvider)
        links.append(link)
        return link
    }

    /// `link.replugged()`, closed by `finish()`.
    func replugged(_ link: SimulatedCameraLink) async -> SimulatedCameraLink {
        let again = await link.replugged()
        links.append(again)
        return again
    }

    // MARK: Routes and jobs

    func route(_ purpose: MatrixPurpose) -> ImportRoute {
        switch purpose {
        case .importToPhotos:
            .photos(photos, staging: staging, onThisIPhone: staging, stagingPlace: Self.place,
                    authorisation: { .denied })
        case .stage:
            .staging(staging, reason: .chosen, place: Self.place, onThisIPhone: staging)
        }
    }

    /// Opens `link` and starts a job on it.
    @discardableResult
    func start(_ link: SimulatedCameraLink, _ purpose: MatrixPurpose, camera: CameraKey = MatrixBench.camera,
               _ selection: ImportSelection = .allNew) async throws -> ImportJobID {
        try await link.open()
        samples = []
        return try await engine.start(selection, from: link, camera: camera, to: route(purpose))
    }

    static let camera = CameraKey(rawValue: "simulated-a7c2")

    // MARK: Waiting

    /// Polls (every 2 ms, for at most `patience` of real time) until `condition` holds of the engine's state; a file
    /// waiting out a retry delay gets the clock moved past it (the longest delay is 5 s), so retries cost no real
    /// time and nothing else moves. Records an issue and throws on a timeout.
    @discardableResult
    func waitFor(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                 _ condition: @Sendable (ImportJobState) -> Bool) async throws -> ImportJobState {
        let deadline = ContinuousClock.now.advanced(by: Self.patience)
        while true {
            let state = await engine.state
            samples.append(await engine.currentProgress)
            if condition(state) { return state }
            guard ContinuousClock.now < deadline else {
                let files = await engine.currentFiles.filter { !$0.phase.isResolved }
                    .map { "\($0.item.name) \($0.phase) x\($0.attempts) \($0.bytesDone)/\($0.item.size)" }
                Issue.record("timed out waiting for \(what); state is \(state); unresolved: \(files)",
                             sourceLocation: sourceLocation)
                throw MatrixTimeout(what: what)
            }
            if await engine.currentFiles.contains(where: { $0.phase == .waitingToRetry }) {
                clock.advance(by: .seconds(6))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitPaused(_ reason: PauseReason, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitFor("the pause for \(reason)", sourceLocation: sourceLocation) { $0 == .paused(reason) }
    }

    @discardableResult
    func waitFinished(sourceLocation: SourceLocation = #_sourceLocation) async throws -> JobOutcome? {
        let state = try await waitFor("the job to finish", sourceLocation: sourceLocation) {
            if case .finished = $0 { true } else { false }
        }
        // A job that ended (stopped, say) can still have a commit finishing on its second download: it resolves its
        // file on the ended job, so wait for the commits before anyone looks at the destinations.
        await settle()
        if case let .finished(outcome) = state { return outcome }
        return nil
    }

    /// Waits (bounded) until no file of the current job is committing.
    func settle() async {
        let deadline = ContinuousClock.now.advanced(by: Self.patience)
        while await engine.currentFiles.contains(where: { $0.phase == .committing }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Polls until `check` holds of the files' statuses.
    func waitForFiles(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                      _ check: ([ImportFileStatus]) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.patience)
        while true {
            let files = await engine.currentFiles
            samples.append(await engine.currentProgress)
            if check(files) { return }
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
                throw MatrixTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Returns once every file of `held` has been written to `cut(file)` bytes, which is where a file scripted with
    /// `.holdAfter` waits: the link reports the bytes and parks in the same step, so a download the engine shows at
    /// its cut is held.
    func waitHeld(_ held: [ScriptedCard.Object], atLeast count: Int, cut: @Sendable (ScriptedCard.Object) -> UInt64,
                  sourceLocation: SourceLocation = #_sourceLocation) async throws -> [ScriptedCard.Object] {
        let cuts = Dictionary(uniqueKeysWithValues: held.map { ($0.filename, cut($0)) })
        var reached: [ScriptedCard.Object] = []
        try await waitForFiles("\(count) download(s) at their cut", sourceLocation: sourceLocation) { files in
            let names = files.filter { $0.phase == .downloading && $0.bytesDone >= (cuts[$0.item.name] ?? .max) }
                .map(\.item.name)
            reached = held.filter { names.contains($0.filename) }
            return reached.count >= count
        }
        return reached
    }

    /// Moves the engine's clock (and a throttled link's budget) by `duration`.
    func advance(_ duration: Duration, link: SimulatedCameraLink? = nil) async {
        if let link { await link.advance(by: duration) }
        clock.advance(by: duration)
    }

    // MARK: Looking

    /// The row for `object` as the catalogue has it, whichever camera key the job used.
    func record(of object: ScriptedCard.Object, camera: CameraKey = MatrixBench.camera) async -> CatalogueRecord? {
        guard let identity = Self.identity(of: object, camera: camera, folder: rowFolder) else { return nil }
        return await catalogue.record(for: identity)
    }

    /// Polls (bounded) until `object`'s row satisfies `condition`.
    func waitForRow(of object: ScriptedCard.Object, _ what: String, camera: CameraKey = MatrixBench.camera,
                    sourceLocation: SourceLocation = #_sourceLocation,
                    _ condition: @Sendable (CatalogueRecord?) -> Bool) async throws -> CatalogueRecord? {
        let deadline = ContinuousClock.now.advanced(by: Self.patience)
        while true {
            let row = await record(of: object, camera: camera)
            if condition(row) { return row }
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
                throw MatrixTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func identity(of object: ScriptedCard.Object, camera: CameraKey, folder: String? = nil) -> ObjectIdentity? {
        guard let date = CaptureDate(ptpDateTime: object.captureDateRaw) else { return nil }
        return ObjectIdentity(camera: camera, folder: folder ?? object.folder, filename: object.filename, captureDate: date,
                              size: object.size)
    }

    /// The keys of every file committed so far, across both destinations (for a case whose committed set depends on
    /// timing, such as a job stopped with a second download in flight; the five points still apply to it).
    func committedKeys(_ cards: [ScriptedCard]) async -> Set<String> {
        var keys: Set<String> = []
        for file in await photos.files + staging.files {
            for object in cards.flatMap(\.objects)
            where object.filename == file.name && UInt64(file.data.count) == object.size
                && file.data == ScriptedCard.content(of: object.handle, in: 0 ..< object.size) {
                keys.insert(Self.key(object))
            }
        }
        return keys
    }

    /// The regular files under the work folder: partial files (under `Partials`) and anything else.
    func workFiles() -> (partials: [URL], others: [URL]) {
        var partials: [URL] = []
        var others: [URL] = []
        // Symlinks resolved on both sides: on a Mac the temporary folder is under /var, a link to /private/var, and the
        // enumerator may hand back either spelling.
        let partialsFolder = work.appendingPathComponent("Partials", isDirectory: true).resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey])
        else { return ([], []) }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            if url.resolvingSymlinksInPath().path.hasPrefix(partialsFolder + "/") { partials.append(url) } else { others.append(url) }
        }
        return (partials, others)
    }

    // MARK: Keys

    /// A file by what the catalogue recognises it by: name, capture second and size.
    static func key(_ object: ScriptedCard.Object) -> String {
        let seconds = PTPDateTime.parse(object.captureDateRaw, defaultTimeZone: zone).map { Int($0.timeIntervalSince1970) }
        return "\(object.filename)|\(seconds ?? -1)|\(object.size)"
    }

    static func key(_ item: CameraItem) -> String {
        "\(item.name)|\(item.captureDate.map { Int($0.timeIntervalSince1970) } ?? -1)|\(item.size)"
    }

    static func keys(_ objects: [ScriptedCard.Object]) -> Set<String> { Set(objects.map(key)) }

    /// The objects of `card` named in `names` (the files a case is about).
    static func objects(_ card: ScriptedCard, named names: [String]) -> [ScriptedCard.Object] {
        card.objects.filter { names.contains($0.filename) }
    }

    /// The two files of the frame `frame` places from the newest (0 is the last frame shot, which the engine copies
    /// first), RAW then JPEG.
    static func frame(_ card: ScriptedCard, fromNewest frame: Int) -> [ScriptedCard.Object] {
        let stems = Array(Set(card.objects.map { $0.filename.prefix(8) })).sorted(by: >)
        let stem = stems[frame]
        return card.objects.filter { $0.filename.hasPrefix(stem) }.sorted { $0.filename < $1.filename }
    }

    // MARK: The five points

    /// Checks a documented engine bug is known to break, and only those: every other check of `verify` stays live. Each
    /// is wrapped in `withKnownIssue`, so when the bug is fixed the check passes, the wrapper fails, and the gap is
    /// deleted from the case.
    struct KnownGaps: Sendable {
        /// Why the checks are expected to fail (the engine behaviour, with where it is).
        var reason: String
        /// Keys of files whose row is known to linger as `.partial` though no job will continue the file.
        var staleRows: Set<String> = []
        /// Whether the partial files kept are known not to be the ones the case leaves resumable.
        var keptPartials = false
    }

    /// After a case recovers (backlog section 3, *The harness*): nothing duplicated, nothing lost.
    ///
    /// 1. every file the job held is committed exactly once or is reported skipped or failed, none silently missing;
    /// 2. the bytes committed are the scripted card's bytes for that file;
    /// 3. the catalogue holds the row the destination implies for each committed file (imported for Photos, a staged
    ///    copy for staging), none for a file not committed, and `.partial` only for the files the case leaves
    ///    resumable;
    /// 4. the work folder holds nothing but the kept partials;
    /// 5. progress never went backwards.
    ///
    /// - Parameters:
    ///   - cards: Every card whose files the case copied from (a card swap names two).
    ///   - committed: The keys of the files the destinations should hold, each once, across both destinations.
    ///   - skipped: The keys of the files the last job reports skipped or failed (not committed).
    ///   - partials: The keys of the files left resumable: a `.partial` row and a file under `Partials`.
    ///   - purpose: The route the job started on: an import job sends nothing to staging and a stage job nothing to
    ///     Photos, unless `switched` says Photos refused a save.
    ///   - orphans: Partial files with no row, which a job killed mid-download leaves for the 7-day prune.
    ///   - camera: The key rows are looked up under first.
    ///   - otherCameras: Other keys a row may be under (`record(for:)` is exact: only "already imported" ignores the
    ///     camera), for a case with two cameras.
    ///   - job: Whether to check the last job's file statuses (point 1's reporting half).
    ///   - knownGaps: The documented bugs that break a row check or the kept-partials check, if any.
    func verify(_ cards: [ScriptedCard], committed: Set<String>, skipped: Set<String> = [], partials: Set<String> = [],
                orphans: Int = 0, purpose: MatrixPurpose? = nil, switched: Bool = false, job: Bool = true, camera: CameraKey = MatrixBench.camera,
                otherCameras: [CameraKey] = [], knownGaps: KnownGaps? = nil,
                sourceLocation: SourceLocation = #_sourceLocation) async {
        await settle()

        let objects = cards.flatMap(\.objects)
        func match(_ file: RecordingDestination.File) -> ScriptedCard.Object? {
            objects.first {
                $0.filename == file.name && UInt64(file.data.count) == $0.size
                    && file.data == ScriptedCard.content(of: $0.handle, in: 0 ..< $0.size)
            }
        }

        // 2, and the committed side of 1: each committed file is a scripted file, byte for byte, once.
        var seen: [String: Int] = [:]
        var kindOf: [String: DestinationKind] = [:]
        for (destination, kind) in [(photos, DestinationKind.photos), (staging, .staging)] {
            for file in await destination.files {
                guard let object = match(file) else {
                    Issue.record("\(file.name) was committed with bytes that are not the camera's",
                                 sourceLocation: sourceLocation)
                    continue
                }
                let key = Self.key(object)
                seen[key, default: 0] += 1
                kindOf[key] = kind
            }
        }
        for (key, n) in seen where n > 1 {
            Issue.record("committed \(n) times: \(key)", sourceLocation: sourceLocation)
        }
        let got = Set(seen.keys)
        #expect(got == committed,
                "committed; missing: \(committed.subtracting(got).sorted()), unexpected: \(got.subtracting(committed).sorted())",
                sourceLocation: sourceLocation)

        // 1, the reporting side: every file of the job is done or reported, with its reason.
        if job {
            let files = await engine.currentFiles
            var done: Set<String> = []
            var left: Set<String> = []
            for file in files {
                let key = Self.key(file.item)
                switch file.phase {
                case .imported, .staged: done.insert(key)
                case .skipped, .failed, .notImported: left.insert(key)
                case .queued, .downloading, .waitingToRetry, .committing:
                    Issue.record("\(key) was silently left: \(file.phase)", sourceLocation: sourceLocation)
                }
            }
            #expect(done.isSubset(of: got), "reported done but not committed: \(done.subtracting(got).sorted())",
                    sourceLocation: sourceLocation)
            #expect(left == skipped, "reported skipped or failed: \(left.sorted()), expected \(skipped.sorted())",
                    sourceLocation: sourceLocation)
            #expect(left.isDisjoint(with: got), "reported skipped but committed: \(left.intersection(got).sorted())",
                    sourceLocation: sourceLocation)
        }

        // The route: where each purpose sends files (and where it doesn't).
        if let purpose {
            switch purpose {
            case .importToPhotos where !switched: #expect(await staging.attempts == 0, "nothing staged by an import",
                                                           sourceLocation: sourceLocation)
            case .stage: #expect(await photos.attempts == 0, "nothing sent to Photos by a stage job",
                                 sourceLocation: sourceLocation)
            default: break
            }
        }

        // 3: the rows.
        var seenKeys: Set<String> = []
        var staleRows: [(key: String, row: CatalogueRecord?)] = []
        for object in objects where seenKeys.insert(Self.key(object)).inserted {
            let key = Self.key(object)
            var row = await record(of: object, camera: camera)
            for other in otherCameras where row == nil { row = await record(of: object, camera: other) }
            if let kind = kindOf[key] {
                switch kind {
                case .photos:
                    #expect(row?.state == .imported, "\(key): imported row, got \(String(describing: row?.state))",
                            sourceLocation: sourceLocation)
                case .staging:
                    #expect(row?.staged != nil && row?.state != .imported && row?.state != .partial,
                            "\(key): staged copy and not imported, got \(String(describing: row?.state))",
                            sourceLocation: sourceLocation)
                }
                #expect(row?.tempURL == nil && (row?.resumeOffset ?? 0) == 0, "\(key): no resume left",
                        sourceLocation: sourceLocation)
            } else if partials.contains(key) {
                #expect(row?.state == .partial && (row?.resumeOffset ?? 0) > 0, "\(key): a partial row",
                        sourceLocation: sourceLocation)
            } else if knownGaps?.staleRows.contains(key) == true {
                staleRows.append((key, row))
            } else {
                #expect(row?.state != .imported && row?.state != .partial && row?.staged == nil,
                        "\(key): no row for a file not committed, got \(String(describing: row?.state))",
                        sourceLocation: sourceLocation)
            }
        }
        if let knownGaps, !knownGaps.staleRows.isEmpty {
            withKnownIssue(Comment(rawValue: knownGaps.reason), sourceLocation: sourceLocation) {
                for (key, row) in staleRows {
                    #expect(row?.state != .imported && row?.state != .partial && row?.staged == nil,
                            "\(key): no row for a file not committed, got \(String(describing: row?.state))",
                            sourceLocation: sourceLocation)
                }
            }
        }

        // 4: the work folder.
        let (kept, others) = workFiles()
        #expect(others.isEmpty, "work folder holds \(others.map(\.lastPathComponent))", sourceLocation: sourceLocation)
        if knownGaps?.keptPartials == true {
            withKnownIssue(Comment(rawValue: knownGaps?.reason ?? ""), sourceLocation: sourceLocation) {
                #expect(kept.count == partials.count + orphans, "partials kept: \(kept.map(\.lastPathComponent))",
                        sourceLocation: sourceLocation)
            }
        } else {
            #expect(kept.count == partials.count + orphans, "partials kept: \(kept.map(\.lastPathComponent))",
                    sourceLocation: sourceLocation)
        }

        // 5: progress.
        samples.append(await engine.currentProgress)
        var last = ImportProgress.none
        for s in samples {
            #expect(s.bytesDone >= last.bytesDone && s.filesDone >= last.filesDone,
                    "progress went backwards: \(last.bytesDone) B / \(last.filesDone) files to \(s.bytesDone) B / \(s.filesDone)",
                    sourceLocation: sourceLocation)
            last = s
        }
    }
}
