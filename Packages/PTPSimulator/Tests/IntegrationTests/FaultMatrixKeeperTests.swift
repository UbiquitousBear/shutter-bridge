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

/// The fault matrix's keeper cases (backlog section 3, after I12; I15): *Import keepers* runs the real engine over
/// Staging read as a camera (`StagingFolderLink`) into the bench's Photos fake, on a keepers route (no fallback), after a
/// stage job from the simulated camera put the files in the bench's staging folder. A staged file is missing, changed
/// or evicted (iCloud Drive) before the job, or Photos is denied during it. Each case checks the stage job with
/// `MatrixBench.verify`, then the keepers job with `verifyKeepers`, the same five points read for a job whose files
/// are in Staging already: nothing imported twice, nothing lost, and Staging untouched (a keepers job copies, never
/// moves, and stages nothing).
@Suite("Fault matrix: keepers", .timeLimit(.minutes(2)))
struct FaultMatrixKeeperTests {
    private static func keys(_ objects: [ScriptedCard.Object]) -> Set<String> { MatrixBench.keys(objects) }

    /// Stages `card` through a stage job over USB (MTP), and checks it.
    private static func stage(_ bench: MatrixBench, _ card: ScriptedCard) async throws {
        let link = bench.link(card, .usbMTP)
        try await bench.start(link, .stage)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verify([card], committed: keys(card.objects), purpose: .stage)
    }

    /// The staged files as *Import keepers* gives them to Staging's link: each staged row's original identity (its
    /// capture time in the engine's zone) and its staged copy's URL in the bench's staging folder.
    private static func entries(_ bench: MatrixBench) async throws -> [StagedEntry] {
        let rows = await bench.catalogue.stagedRecords(camera: MatrixBench.camera)
        let folder = bench.root.appendingPathComponent("staging", isDirectory: true)
        return try rows.map { row in
            let staged = try #require(row.staged)
            let name = String(staged.relativePath.dropFirst("Staging/".count))
            return StagedEntry(folder: row.identity.folder, name: row.identity.filename,
                               captureDate: row.identity.captureDate.date(in: MatrixBench.zone),
                               size: row.identity.size, url: folder.appendingPathComponent(name))
        }.sorted { $0.name < $1.name }
    }

    /// Starts a keepers job over `entries`, as `ImportModel.importKeepers` does: the files Staging's link lists, less
    /// what is imported already (a requeued selection, which leaves out rejects too).
    @discardableResult
    private static func importKeepers(_ bench: MatrixBench, _ entries: [StagedEntry],
                                      reader: any StagedFileReading = PlainStagedFileReader(),
                                      access: PhotosAuthorisation = .denied) async throws -> ImportJobID {
        let link = Self.link(entries, reader: reader)
        let listed = try await link.list()
        let route = ImportRoute.keepers(bench.photos, authorisation: { access })
        let picks = try await bench.engine.picksToDo(.requeued(listed), camera: MatrixBench.camera, for: route)
        return try await bench.engine.start(.requeued(picks), from: link, camera: MatrixBench.camera, to: route)
    }

    /// Staging read as a camera, over `entries`.
    private static func link(_ entries: [StagedEntry], reader: any StagedFileReading = PlainStagedFileReader())
        -> StagingFolderLink {
        StagingFolderLink(descriptor: StagingFolderLink.descriptor(named: "ILCE-7CM2"), entries: entries, reader: reader)
    }

    /// What each staged file holds now, by URL: Staging as the keepers job found it.
    private static func contents(_ entries: [StagedEntry]) -> [URL: Data] {
        var out: [URL: Data] = [:]
        for entry in entries { out[entry.url] = try? Data(contentsOf: entry.url) }
        return out
    }

    // MARK: The cases

    /// The plain run: every keeper is imported once, Staging keeps its copies, and a second run imports nothing.
    @Test("Import keepers", arguments: [1, 2])
    func importKeepers(_ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        try await Self.stage(bench, card)
        let entries = try await Self.entries(bench)
        let before = Self.contents(entries)
        let mark = await bench.keepersMark()
        try await Self.importKeepers(bench, entries)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verifyKeepers(card, from: mark, imported: Self.keys(card.objects), staging: before)

        // Again: everything is imported, so a second run would hold nothing.
        let listed = try await Self.link(entries).list()
        let picks = try await bench.engine.picksToDo(.requeued(listed), camera: MatrixBench.camera,
                                                     for: .keepers(bench.photos, authorisation: { .denied }))
        #expect(listed.count == card.objects.count && picks.isEmpty)
        await bench.finish()
    }

    /// A staged file removed (in the Files app, say) before *Import keepers*: it is skipped as gone, the rest are
    /// imported, and its row keeps its staged copy and isn't imported.
    @Test("A staged file missing before Import keepers", arguments: [1, 2])
    func stagedFileMissing(_ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        try await Self.stage(bench, card)
        let entries = try await Self.entries(bench)
        let gone = try #require(entries.first { $0.name == "DSC00002.JPG" })
        try FileManager.default.removeItem(at: gone.url)
        let before = Self.contents(entries)
        let mark = await bench.keepersMark()
        try await Self.importKeepers(bench, entries)
        #expect(try await bench.waitFinished() == .completed)
        let missing = Self.keys(card.objects.filter { $0.filename == gone.name })
        await bench.verifyKeepers(card, from: mark, imported: Self.keys(card.objects).subtracting(missing),
                                  skipped: missing, staging: before)
        let row = await bench.record(of: try #require(card.objects.first { $0.filename == gone.name }))
        #expect(await bench.engine.outcomes(named: gone.name) == [.skipped(.link(.itemNotFound))])
        #expect(row?.state != .imported && row?.staged != nil)
        await bench.finish()
    }

    /// A staged file changed (another size) before *Import keepers*: it isn't the file the row names, so it is skipped
    /// and left as it is; nothing of it reaches Photos.
    @Test("A staged file changed before Import keepers", arguments: [1, 2])
    func stagedFileChanged(_ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        try await Self.stage(bench, card)
        let entries = try await Self.entries(bench)
        let changed = try #require(entries.first { $0.name == "DSC00003.ARW" })
        try Data(repeating: 0x5A, count: Int(changed.size) + 100).write(to: changed.url)
        let before = Self.contents(entries)
        let mark = await bench.keepersMark()
        try await Self.importKeepers(bench, entries)
        #expect(try await bench.waitFinished() == .completed)
        let skipped = Self.keys(card.objects.filter { $0.filename == changed.name })
        await bench.verifyKeepers(card, from: mark, imported: Self.keys(card.objects).subtracting(skipped),
                                  skipped: skipped, staging: before)
        #expect(await bench.engine.outcomes(named: changed.name) == [.skipped(.link(.itemNotFound))])
        await bench.finish()
    }

    /// A staged file evicted from the phone by iCloud Drive: the reader downloads it before copying (the coordinated
    /// reader's behaviour, played here by `EvictingReader`), so it is imported once like the rest.
    @Test("A staged file evicted before Import keepers", arguments: [1, 2])
    func stagedFileEvicted(_ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        try await Self.stage(bench, card)
        let entries = try await Self.entries(bench)
        let before = Self.contents(entries)
        let evicted = try #require(entries.first { $0.name == "DSC00004.ARW" })
        let reader = try EvictingReader(evicting: [evicted.url], cloud: bench.root.appendingPathComponent("cloud"))
        let mark = await bench.keepersMark()
        try await Self.importKeepers(bench, entries, reader: reader)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verifyKeepers(card, from: mark, imported: Self.keys(card.objects), staging: before)
        #expect(reader.downloads == [evicted.url.lastPathComponent])
        await bench.finish()
    }

    /// An evicted file whose download never finishes (no network): the reader times out (`noAnswer`), the engine tries
    /// it again after its back-off and fails it once the retries are used up; the rest are imported, and the keeper
    /// stays in Staging, evicted, with its staged row.
    @Test("A staged file evicted and not downloadable", arguments: [1, 2])
    func stagedFileEvictedAndUnreachable(_ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        try await Self.stage(bench, card)
        let entries = try await Self.entries(bench)
        let evicted = try #require(entries.first { $0.name == "DSC00004.JPG" })
        let reader = try EvictingReader(evicting: [evicted.url], cloud: bench.root.appendingPathComponent("cloud"),
                                        downloadFails: true)
        var before = Self.contents(entries)
        before[evicted.url] = nil // not on the phone, and not expected back
        let mark = await bench.keepersMark()
        try await Self.importKeepers(bench, entries, reader: reader)
        #expect(try await bench.waitFinished() == .completed)
        let failed = Self.keys(card.objects.filter { $0.filename == evicted.name })
        await bench.verifyKeepers(card, from: mark, imported: Self.keys(card.objects).subtracting(failed),
                                  skipped: failed, staging: before)
        #expect(await bench.engine.outcomes(named: evicted.name) == [.failed(.link(.noAnswer))])
        #expect(reader.downloads.count == 4, "the first try and three retries: \(reader.downloads)")
        #expect(reader.isStillEvicted(evicted.url))
        await bench.finish()
    }

    /// Photos access is turned off during *Import keepers*: Photos refuses the second save (3311) and the job stops for
    /// Photos access, staging nothing (a keepers route has no fallback); the refused files wait in Staging, unsaved and
    /// not failed. With access back, the next run imports only what is left, each file once.
    @Test("Photos denied during Import keepers", arguments: [1, 2])
    func photosDeniedDuringKeepers(_ inFlight: Int) async throws {
        let bench = MatrixBench(inFlight: inFlight)
        let card = try MatrixBench.card()
        try await Self.stage(bench, card)
        let entries = try await Self.entries(bench)
        let before = Self.contents(entries)
        await bench.photos.deny(from: 2)
        let mark = await bench.keepersMark()
        try await Self.importKeepers(bench, entries, access: .denied)
        #expect(try await bench.waitFinished() == .photosAccessNeeded(.denied))
        let got = await bench.importedKeys(card)
        #expect(!got.isEmpty && got.count < card.objects.count)
        await bench.verifyKeepers(card, from: mark, imported: got,
                                  waiting: Self.keys(card.objects).subtracting(got), staging: before)

        // Access back: the rest, once.
        await bench.photos.deny(from: .max)
        let again = await bench.keepersMark()
        try await Self.importKeepers(bench, entries, access: .authorised)
        #expect(try await bench.waitFinished() == .completed)
        await bench.verifyKeepers(card, from: again, imported: Self.keys(card.objects), staging: before)
        await bench.finish()
    }
}

// MARK: - Checking a keepers job

extension MatrixBench {
    /// Where a keepers job's checks start: the progress samples and the staging fake's commits before it.
    struct KeepersMark {
        var samples: Int
        var stagingAttempts: Int
    }

    func keepersMark() async -> KeepersMark {
        KeepersMark(samples: samples.count, stagingAttempts: await staging.attempts)
    }

    /// The keys of the files Photos holds (`committedKeys(_:)` reads Staging too, which holds every staged file).
    func importedKeys(_ card: ScriptedCard) async -> Set<String> {
        var keys: Set<String> = []
        for file in await photos.files {
            for object in card.objects where object.filename == file.name && UInt64(file.data.count) == object.size
                && file.data == ScriptedCard.content(of: object.handle, in: 0 ..< object.size) {
                keys.insert(Self.key(object))
            }
        }
        return keys
    }

    /// The five points (`verify`) for a keepers job, whose files were staged by an earlier stage job and are read
    /// from Staging:
    ///
    /// 1. every keeper is imported into Photos once or reported skipped or failed (or, with `waiting`, left queued by
    ///    a job that stopped for Photos access), none silently missing;
    /// 2. the bytes imported are the camera's bytes for that file;
    /// 3. each imported file's row is imported and keeps its staged copy; every other staged file's row is staged and
    ///    not imported; no row is `.partial`;
    /// 4. the work folder holds nothing (Staging's link doesn't resume);
    /// 5. progress never went backwards since `mark`;
    ///
    /// and Staging is untouched: nothing was staged (the keepers route has no fallback) and every staged file in
    /// `staging` still holds its bytes.
    func verifyKeepers(_ card: ScriptedCard, from mark: KeepersMark, imported: Set<String>, skipped: Set<String> = [],
                       waiting: Set<String> = [], staging expected: [URL: Data],
                       sourceLocation: SourceLocation = #_sourceLocation) async {
        await settle()

        // 1 and 2: Photos holds each imported file once, byte for byte.
        var seen: [String: Int] = [:]
        for file in await photos.files {
            guard let object = card.objects.first(where: {
                $0.filename == file.name && UInt64(file.data.count) == $0.size
                    && file.data == ScriptedCard.content(of: $0.handle, in: 0 ..< $0.size)
            }) else {
                Issue.record("\(file.name) was imported with bytes that are not the camera's", sourceLocation: sourceLocation)
                continue
            }
            seen[Self.key(object), default: 0] += 1
        }
        for (key, n) in seen where n > 1 { Issue.record("imported \(n) times: \(key)", sourceLocation: sourceLocation) }
        let got = Set(seen.keys)
        #expect(got == imported,
                "imported; missing: \(imported.subtracting(got).sorted()), unexpected: \(got.subtracting(imported).sorted())",
                sourceLocation: sourceLocation)

        var done: Set<String> = []
        var left: Set<String> = []
        var queued: Set<String> = []
        for file in await engine.currentFiles {
            let key = Self.key(file.item)
            switch file.phase {
            case .imported: done.insert(key)
            case .skipped, .failed: left.insert(key)
            // Not copied by a job that stopped (for Photos access): it waits in Staging for the next run.
            case .queued, .notImported: queued.insert(key)
            case .staged, .downloading, .waitingToRetry, .committing:
                Issue.record("\(key) was left \(file.phase)", sourceLocation: sourceLocation)
            }
        }
        #expect(done.isSubset(of: got), "reported done but not imported: \(done.subtracting(got).sorted())",
                sourceLocation: sourceLocation)
        #expect(left == skipped, "reported skipped or failed: \(left.sorted()), expected \(skipped.sorted())",
                sourceLocation: sourceLocation)
        #expect(queued == waiting, "left waiting: \(queued.sorted()), expected \(waiting.sorted())",
                sourceLocation: sourceLocation)

        // 3: the rows.
        for object in card.objects {
            let key = Self.key(object)
            let row = await record(of: object)
            #expect(row?.staged != nil, "\(key): the staged copy is still recorded", sourceLocation: sourceLocation)
            #expect(row?.state != .partial && row?.tempURL == nil, "\(key): no partial row", sourceLocation: sourceLocation)
            if got.contains(key) {
                #expect(row?.state == .imported, "\(key): imported row, got \(String(describing: row?.state))",
                        sourceLocation: sourceLocation)
            } else {
                #expect(row?.state != .imported, "\(key): not imported", sourceLocation: sourceLocation)
            }
        }

        // 4: the work folder, when the job read as finished and now. A refused save traces no result, so a file whose
        // commit was still under way when the job ended (a second unit in flight, refused as well) is only judged now:
        // the commit removes its download once Photos has answered.
        let underWay = Set(card.objects.filter { waiting.contains(Self.key($0)) }.map(\.filename))
        let leaks = finished.leaks(excluding: []).filter { !underWay.contains($0) }
        let (partials, others) = workFiles()
        #expect(leaks.isEmpty && others.isEmpty && partials.isEmpty,
                "work folder holds \(leaks) when the job ended, \((others + partials).map(\.lastPathComponent)) now",
                sourceLocation: sourceLocation)

        // 5: progress, since the keepers job started.
        var last = ImportProgress.none
        for s in samples.dropFirst(mark.samples) + [await engine.currentProgress] {
            #expect(s.bytesDone >= last.bytesDone && s.filesDone >= last.filesDone,
                    "progress went backwards: \(last.bytesDone) B / \(last.filesDone) files to \(s.bytesDone) B / \(s.filesDone)",
                    sourceLocation: sourceLocation)
            last = s
        }

        // Staging untouched.
        #expect(await staging.attempts == mark.stagingAttempts, "nothing staged by a keepers job",
                sourceLocation: sourceLocation)
        for (url, data) in expected {
            #expect((try? Data(contentsOf: url)) == data, "\(url.lastPathComponent) is as it was in Staging",
                    sourceLocation: sourceLocation)
        }
    }
}

extension ImportEngine {
    /// The outcomes of the current or last job's files called `name`.
    func outcomes(named name: String) -> [ImportFileStatus.Phase] {
        currentFiles.filter { $0.item.name == name }.map(\.phase)
    }
}

// MARK: - An evicted iCloud Drive file

/// A reader over Staging in which some files are evicted, as iCloud Drive does with a file not opened for a while: the
/// file's bytes are moved aside (to `cloud`), its place in Staging is empty, and it still counts as present (an evicted
/// file can't be sized without downloading it). Copying it first downloads it back into Staging, as the coordinated
/// reader asks iCloud Drive to, and then copies it as the plain reader does; with `downloadFails`, the download never
/// finishes and the copy fails `noAnswer`, as the coordinated reader's timeout does.
final class EvictingReader: StagedFileReading {
    private let plain = PlainStagedFileReader()
    private let cloud: URL
    private let failing: Bool
    private let state = Mutex<(evicted: Set<URL>, downloads: [String])>(([], []))

    init(evicting urls: [URL], cloud: URL, downloadFails: Bool = false) throws {
        self.cloud = cloud
        failing = downloadFails
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        for url in urls {
            try FileManager.default.moveItem(at: url, to: cloud.appendingPathComponent(url.lastPathComponent))
        }
        state.withLock { $0.evicted = Set(urls.map(\.standardizedFileURL)) }
    }

    /// The names of the files a copy had to download, once per try.
    var downloads: [String] { state.withLock { $0.downloads } }

    func isStillEvicted(_ url: URL) -> Bool {
        state.withLock { $0.evicted.contains(url.standardizedFileURL) }
            && !FileManager.default.fileExists(atPath: url.path)
    }

    func presence(of source: URL, expectedSize: UInt64) -> StagedPresence {
        if state.withLock({ $0.evicted.contains(source.standardizedFileURL) }) { return .present }
        return plain.presence(of: source, expectedSize: expectedSize)
    }

    func copy(_ source: URL, expectedSize: UInt64, to destination: URL,
              progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) {
        let key = source.standardizedFileURL
        let evicted = state.withLock { s -> Bool in
            guard s.evicted.contains(key) else { return false }
            s.downloads.append(source.lastPathComponent)
            return true
        }
        if evicted {
            if failing { throw CameraLinkFailure(.noAnswer, detail: "staging copy: the iCloud download didn't finish") }
            do {
                try FileManager.default.copyItem(at: cloud.appendingPathComponent(source.lastPathComponent), to: source)
            } catch {
                throw CameraLinkFailure(.unreadableItem, detail: "staging copy: the iCloud download failed")
            }
            state.withLock { _ = $0.evicted.remove(key) }
        }
        try await plain.copy(source, expectedSize: expectedSize, to: destination, progress: progress)
    }
}
