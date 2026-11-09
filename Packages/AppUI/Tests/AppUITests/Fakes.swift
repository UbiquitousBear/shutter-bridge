import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import PTPKit
@testable import AppUI

/// A card for tests: name, folder, seconds after a fixed instant (nil: no date), size.
func item(_ name: String, folder: String = "DCIM/100MSDCF", at seconds: TimeInterval? = 0, size: UInt64 = 1_000,
          id: String? = nil) -> CameraItem {
    CameraItem(id: .init(rawValue: id ?? "\(folder)/\(name)"), folder: folder, name: name, size: size,
               captureDate: seconds.map { Date(timeIntervalSince1970: 1_793_000_000 + $0) })
}

/// A camera link over a scripted card. `bytes` writes a small file named after the item (its contents are the
/// item's name, so a test can tell which file was fetched); it can be made to hang until cancelled or closed, or to
/// fail. Like `USBLink`, a closed link fails its calls as `disconnected`, and a cancelled fetch fails as `busy`.
actor FakeLink: CameraLink {
    nonisolated let descriptor: CameraDescriptor
    nonisolated let capabilities: CameraLinkCapabilities
    nonisolated let events: AsyncStream<CameraLinkEvent>
    private let eventSink: AsyncStream<CameraLinkEvent>.Continuation

    var items: [CameraItem]
    var listFailure: CameraLinkFailure?
    var bytesFailure: CameraLinkFailure?
    var bytesHangs = false
    /// Write the listed size (for the engine, which checks it) rather than the item's name.
    var writesListedSize = false
    private(set) var fetched: [CameraItem.ID] = []
    private(set) var bytesStarted = 0
    private(set) var isOpen = false
    private(set) var closed = false
    private var hang: CheckedContinuation<Void, Never>?

    init(items: [CameraItem], mode: CameraMode = .usb(.massStorage), id: String = "fake-camera",
         name: String = "Untitled") {
        descriptor = CameraDescriptor(id: .init(rawValue: id), name: name, mode: mode)
        capabilities = .defaults(for: mode.carrier)
        self.items = items
        (events, eventSink) = AsyncStream.makeStream()
    }

    func set(listFailure: CameraLinkFailure?) { self.listFailure = listFailure }
    func set(bytesFailure: CameraLinkFailure?) { self.bytesFailure = bytesFailure }
    func set(bytesHangs: Bool) { self.bytesHangs = bytesHangs }
    func set(writesListedSize: Bool) { self.writesListedSize = writesListedSize }

    func remove() { eventSink.yield(.removed) }
    func send(_ event: CameraLinkEvent) { eventSink.yield(event) }

    func open() throws(CameraLinkFailure) { isOpen = true }

    func list() throws(CameraLinkFailure) -> [CameraItem] {
        if let listFailure { throw listFailure }
        return items.newestFirst()
    }

    func info(of item: CameraItem.ID) throws(CameraLinkFailure) -> CameraItem {
        guard let found = items.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        return found
    }

    func thumbnail(of item: CameraItem.ID) throws(CameraLinkFailure) -> Data { Data("thumb \(item)".utf8) }

    func bytes(of item: CameraItem.ID, into directory: URL, resuming: PartialDownload?,
               checkpoint: @escaping @Sendable (PartialDownload) -> Void,
               progress: @escaping @Sendable (UInt64) -> Void) async throws(CameraLinkFailure) -> URL {
        bytesStarted += 1
        if closed { throw CameraLinkFailure(.disconnected, detail: "bytes: the link is closed") }
        if bytesHangs {
            // Parked until the calling task is cancelled or the link closes, whichever comes first: no timeout, so
            // a missed cancel shows up at once as a `disconnected` failure rather than as a slow pass.
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || closed { continuation.resume() } else { hang = continuation }
                }
            } onCancel: {
                Task { await self.releaseHang() }
            }
            if Task.isCancelled { throw CameraLinkFailure(.busy, detail: "bytes: cancelled") }
            if closed { throw CameraLinkFailure(.disconnected, detail: "bytes: the link is closed") }
        }
        if let bytesFailure { throw bytesFailure }
        guard let found = items.first(where: { $0.id == item }) else { throw CameraLinkFailure(.itemNotFound) }
        let url = directory.appendingPathComponent(found.name)
        let data = writesListedSize ? Data(count: Int(found.size)) : Data(found.name.utf8)
        do { try data.write(to: url) } catch { throw CameraLinkFailure(.phoneStorageFull) }
        fetched.append(item)
        progress(UInt64(data.count))
        return url
    }

    private func releaseHang() {
        hang?.resume()
        hang = nil
    }

    func close() {
        guard !closed else { return }
        closed = true
        releaseHang()
        eventSink.finish()
    }
}

/// Writes "JPEG from <input name>" as the JPEG, or fails, or reports the embedded-preview fallback.
struct FakeMaker: JPEGMaking {
    var fallback = false
    var fails = false
    /// Cancels the calling task while reading a JPG's pixel size: a cancel that lands after the pipeline's last
    /// cancellation check.
    var cancelsWhileMeasuring = false

    func makeJPEG(from input: URL, conversion: JPEGConversion, to output: URL) async throws(JPEGMakingFailure)
        -> JPEGMakingReport
    {
        if fails { throw JPEGMakingFailure("fake: can't decode") }
        do {
            try Data("JPEG from \(input.lastPathComponent) by \(conversion.rawValue)".utf8).write(to: output)
        } catch {
            throw JPEGMakingFailure("fake: write")
        }
        return JPEGMakingReport(
            usedEmbeddedPreview: fallback,
            outputPixelSize: fallback ? PixelSize(width: 1616, height: 1080) : PixelSize(width: 7008, height: 4672),
            seconds: 1.5, largestPreviewPixelSize: fallback ? PixelSize(width: 1616, height: 1080) : nil,
            notes: fallback ? ["CIRAWFilter(imageURL:) returned nil"] : [])
    }

    func pixelSize(ofImageAt url: URL) -> PixelSize? {
        if cancelsWhileMeasuring { withUnsafeCurrentTask { $0?.cancel() } }
        return PixelSize(width: 7008, height: 4672)
    }
}

@MainActor
final class FakeClipboard: JPEGClipboard {
    var copied: [Data] = []
    var refuses = false

    struct Refused: Error {}

    func copyJPEG(at url: URL) throws {
        if refuses { throw Refused() }
        copied.append(try Data(contentsOf: url))
    }
}

final class RecordingLog: BenchLog, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] { lock.withLock { stored } }

    func note(_ line: String) { lock.withLock { stored.append(line) } }
}

/// A scratch area in a fresh temporary folder.
func temporaryScratch() -> JPEGScratch {
    JPEGScratch(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("AppUITests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(JPEGScratch.folderName, isDirectory: true))
}

/// The folders currently under a scratch root.
func actionFolders(in scratch: JPEGScratch) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: scratch.root, includingPropertiesForKeys: nil)) ?? []
}

/// A clock whose time never moves: an engine on it never declares a stall, never ends a retry wait and never ticks.
/// For tests that hang a download on purpose and then look at it in flight: on the real clock the engine's 30 s stall
/// limit can fire first when a loaded CI runner (the iOS Simulator with every suite in parallel) is slow to reach the
/// checks, and the in-flight file turns into a retry. `sleep` returns only by throwing when its task is cancelled.
struct FrozenClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// Polls `condition` on the main actor until it holds or about two seconds pass.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Fakes for the full Browse, Import and Settings

/// An importer that records what Browse hands it and answers as scripted.
@MainActor
final class FakeImporter: BrowseImporting {
    var outcome: ImportRequestOutcome = .started(0)
    private(set) var calls: [(items: [CameraItem], camera: ImportCamera)] = []

    private let updates = LatestValueFanOut<Int>()
    private var revision = 0

    func importItems(_ items: [CameraItem], from camera: ImportCamera, link: any CameraLink) async
        -> ImportRequestOutcome {
        calls.append((items, camera))
        if case .started = outcome { return .started(items.count) }
        return outcome
    }

    func importedUpdates() -> AsyncStream<Int> { updates.subscribe() }

    /// Says more files were imported, as `ImportModel` does when a file's row has been written.
    func announceImported() {
        revision += 1
        updates.send(revision)
    }

    /// Readers of `importedUpdates()` still reading.
    var updateReaders: Int { updates.subscriberCount }
}

/// Photos access as scripted: what reading gives, and what asking answers (and turns the status into).
final class FakePhotosAccess: PhotosAuthorising, @unchecked Sendable {
    private let lock = NSLock()
    private var status: PhotosAuthorisation
    private var answer: PhotosAuthorisation
    private var asked = 0

    init(_ status: PhotosAuthorisation = .authorised, answer: PhotosAuthorisation = .authorised) {
        self.status = status
        self.answer = answer
    }

    private var afterNextRead: PhotosAuthorisation?

    var askCount: Int { lock.withLock { asked } }
    func set(_ status: PhotosAuthorisation) { lock.withLock { self.status = status } }
    /// The status changes to `status` once the current one has been read (access turned off during an import).
    func change(afterNextReadTo status: PhotosAuthorisation) { lock.withLock { afterNextRead = status } }

    func authorisation() async -> PhotosAuthorisation {
        lock.withLock {
            let read = status
            if let next = afterNextRead {
                status = next
                afterNextRead = nil
            }
            return read
        }
    }

    func requestReadWriteAuthorisation() async -> PhotosAuthorisation {
        lock.withLock {
            asked += 1
            if status == .notDetermined { status = answer }
            return status
        }
    }
}

/// A destination that records the files it was given, by name; Photos can be made to refuse saves (3311).
actor RecordingDestination: ImportDestination {
    nonisolated let kind: DestinationKind
    private(set) var names: [String] = []
    private var denies = false

    init(kind: DestinationKind) { self.kind = kind }

    func setDenies(_ on: Bool) { denies = on }

    func commit(_ unit: CommitUnit) throws(ImportDestinationFailure) -> ImportResult {
        if denies { throw .photosAccessDenied }
        let files = unit.files
        names += files.map(\.filename)
        for file in files { try? FileManager.default.removeItem(at: file.url) }
        switch kind {
        case .photos: return .photosAsset(localIdentifier: "asset-\(names.count)")
        case .filesFolder: return .files(files.map { FileLocation(relativePath: "Untitled/\($0.filename)") })
        }
    }
}

/// One Photos and one Files destination for every job, so a test can look at what each got.
final class FakeDestinations: ImportDestinationMaking, @unchecked Sendable {
    let photos = RecordingDestination(kind: .photos)
    let files = RecordingDestination(kind: .filesFolder)
    private let lock = NSLock()
    private var made: [ImportCamera] = []

    var cameras: [ImportCamera] { lock.withLock { made } }

    func destinations(for camera: ImportCamera, startedAt: Date) -> ImportDestinations {
        lock.withLock { made.append(camera) }
        return ImportDestinations(photos: photos, filesFolder: files,
                                  filesFolderName: FilesFolderNaming.folderName(forCamera: camera.name))
    }
}

/// Finds whatever link a test puts in it.
@MainActor
final class FakeFinder: CameraFinding {
    var links: [CameraKey: any CameraLink] = [:]
    func link(forCameraWith key: CameraKey) async -> (any CameraLink)? { links[key] }
}

/// A catalogue whose reads and writes all fail.
actor BrokenCatalogue: CatalogueStore {
    struct Broken: Error {}
    func record(for identity: ObjectIdentity) throws -> CatalogueRecord? { throw Broken() }
    func states(of identities: [ObjectIdentity]) throws -> [ObjectIdentity: ObjectState] { throw Broken() }
    func upsert(_ record: CatalogueRecord) throws { throw Broken() }
    func saveListing(_ listing: CardListing) throws { throw Broken() }
    func lastListing(for camera: CameraKey) throws -> CardListing? { throw Broken() }
    func markPartial(_ identity: ObjectIdentity, format: PTPMediaKind, tempURL: URL, offset: UInt64) throws {
        throw Broken()
    }
    func camera(_ key: CameraKey) throws -> CameraRecord? { throw Broken() }
    func cameras() throws -> [CameraRecord] { throw Broken() }
    func upsertCamera(_ record: CameraRecord) throws { throw Broken() }
}

/// A fresh staging folder for an engine.
func temporaryStaging() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("AppUITests-staging-\(UUID().uuidString)",
                                                                  isDirectory: true)
}

/// A user-defaults suite of its own, removed by `drop()`.
struct TemporaryDefaults {
    let name = "AppUITests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func drop() { UserDefaults.standard.removePersistentDomain(forName: name) }
}
