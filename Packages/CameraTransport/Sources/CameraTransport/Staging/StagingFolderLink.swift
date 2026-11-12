import Foundation
import PTPKit

/// One file in Staging, as the caller describes it: where it was on the camera's card (its original identity), and
/// where the staged copy is now. The caller builds these from the catalogue's staged records, so `CameraTransport`
/// depends on nothing above it.
public struct StagedEntry: Sendable, Hashable {
    /// The folder on the card the file came from, such as "DCIM/100MSDCF"; empty when the card's link couldn't tell.
    public var folder: String
    /// The camera's file name, such as "DSC04512.ARW". The copy keeps it.
    public var name: String
    public var captureDate: Date?
    /// The size in bytes of the original and of the staged copy, which are the same file.
    public var size: UInt64
    public var format: PTPMediaKind
    /// Where the staged copy is.
    public var url: URL

    public init(folder: String, name: String, captureDate: Date?, size: UInt64, format: PTPMediaKind, url: URL) {
        self.folder = folder
        self.name = name
        self.captureDate = captureDate
        self.size = size
        self.format = format
        self.url = url
    }

    /// An entry whose format follows from its file name, as `CameraItem` does.
    public init(folder: String, name: String, captureDate: Date?, size: UInt64, url: URL) {
        self.init(folder: folder, name: name, captureDate: captureDate, size: size,
                  format: CameraItem.format(ofFilename: name), url: url)
    }

    /// The catalogue's identity of the file (folder, name, capture date, size), which decides when two entries are
    /// the same file.
    fileprivate struct Identity: Hashable {
        var folder: String
        var name: String
        var captureDate: Date?
        var size: UInt64
    }

    fileprivate var identity: Identity { Identity(folder: folder, name: name, captureDate: captureDate, size: size) }

    /// Whether `name` is one file name and not a path: the link writes into the engine's folder under it, so
    /// anything else could write outside the folder.
    fileprivate var hasPlainName: Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

extension CameraLinkCapabilities {
    /// `StagingFolderLink`'s capabilities: a local copy, two at a time; no resume (a copy that breaks off starts
    /// again, and nothing is slow enough to be worth resuming); nothing read from a device; **no deletion**, so no
    /// path from the engine can remove a staged file (removal after *Import keepers* is Staging's own, I12); IDs that
    /// last one link, since the entries are the caller's to give again.
    public static let staging = CameraLinkCapabilities(
        maxDownloadsInFlight: 2, resumesPartialFiles: false, reportsBatteryAndFreeSpace: false, deletes: false,
        itemIDsSurviveReopen: false)
}

/// Staging read as a camera, so *Import keepers* reuses the import engine unchanged (backlog Iteration 2, section 7.2).
///
/// - **`list()`** returns the entries as `CameraItem`s with their original identity (folder, name, capture date, size,
///   format), so the engine's diff, its rows and Browse's badges treat a keeper exactly as the card's file. Two
///   entries with one identity are one file, and the first is kept. The item's ID is the entry's place in the list
///   given to `init`.
/// - **`bytes(of:into:…)` copies, never moves.** The staged file is still there, unchanged, when the copy ends or
///   fails; the reader (`StagedFileReading`) checks its size against the entry's. A file that is gone, or whose size
///   changed, is `itemNotFound` (the engine skips it); the keeper stays in Staging.
/// - **No resume, no checkpoints, no thumbnails, no events**; `close()` releases nothing. Thumbnails come from the cull
///   screen's own reader.
/// - The descriptor is the caller's, in `CameraMode.staging` (`StagingFolderLink.descriptor(named:)`). It never makes a
///   camera key: each keepers job is started with the staged files' own key (backlog section 7.5).
public actor StagingFolderLink: CameraLink {
    public nonisolated let descriptor: CameraDescriptor
    public nonisolated var capabilities: CameraLinkCapabilities { .staging }

    /// Live, as `CameraLink` requires; this link has nothing to say, so every stream only finishes, on `close()`.
    public nonisolated var events: AsyncStream<CameraLinkEvent> { eventFanOut.subscribe() }

    private let eventFanOut = EventFanOut<CameraLinkEvent>()
    private let reader: any StagedFileReading
    private var entries: [CameraItem.ID: StagedEntry] = [:]
    private var items: [CameraItem] = []
    private var itemsByID: [CameraItem.ID: CameraItem] = [:]
    private var isClosed = false

    public init(
        descriptor: CameraDescriptor, entries staged: [StagedEntry],
        reader: any StagedFileReading = StagedFileReaders.platform
    ) {
        self.descriptor = descriptor
        self.reader = reader
        var seen = Set<StagedEntry.Identity>()
        for (index, entry) in staged.enumerated() where seen.insert(entry.identity).inserted {
            let id = CameraItem.ID(rawValue: "staged-\(index)")
            entries[id] = entry
            let item = CameraItem(
                id: id, folder: entry.folder, name: entry.name, size: entry.size, captureDate: entry.captureDate,
                format: entry.format)
            items.append(item)
            itemsByID[id] = item
        }
    }

    /// A descriptor for Staging read as a camera: `CameraMode.staging`, named for the staged camera (its folder under
    /// Staging, D11), which names the job's album and its wording. Its ID names nothing private.
    public static func descriptor(named name: String) -> CameraDescriptor {
        CameraDescriptor(id: .init(rawValue: "staging"), name: name, mode: .staging)
    }

    // MARK: - CameraLink

    public func open() async throws(CameraLinkFailure) {
        if isClosed { throw CameraLinkFailure(.disconnected, detail: "open: the link is closed") }
    }

    public func list() async throws(CameraLinkFailure) -> [CameraItem] {
        try ensureUsable("list")
        return items.newestFirst()
    }

    /// The entry's own facts, if its staged file is still there with that size.
    public func info(of item: CameraItem.ID) async throws(CameraLinkFailure) -> CameraItem {
        try ensureUsable("info")
        let (entry, known) = try lookup(item, during: "info")
        switch reader.presence(of: entry.url, expectedSize: entry.size) {
        case .present: return known
        case .missing: throw CameraLinkFailure(.itemNotFound, detail: "info: the staged file is gone")
        case .sizeChanged: throw CameraLinkFailure(.itemNotFound, detail: "info: the staged file's size changed")
        }
    }

    /// No thumbnails: the cull screen reads its own. A placeholder is what the engine shows for `unreadableItem`.
    public func thumbnail(of item: CameraItem.ID) async throws(CameraLinkFailure) -> Data {
        try ensureUsable("thumbnail")
        _ = try lookup(item, during: "thumbnail")
        throw CameraLinkFailure(.unreadableItem, detail: "thumbnail: Staging has none")
    }

    /// Copies the staged file into `directory` under its name. `resuming` is ignored and `checkpoint` never called.
    public func bytes(
        of item: CameraItem.ID,
        into directory: URL,
        resuming: PartialDownload?,
        checkpoint: @escaping @Sendable (PartialDownload) -> Void,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL {
        try ensureUsable("download")
        let (entry, _) = try lookup(item, during: "download")
        guard entry.hasPlainName else {
            throw CameraLinkFailure(.unreadableItem, detail: "download: the staged file's name isn't a file name")
        }
        let destination = directory.appendingPathComponent(entry.name)
        try await reader.copy(entry.url, expectedSize: entry.size, to: destination, progress: progress)
        return destination
    }

    /// Releases nothing and finishes `events`. Closing a closed link does nothing.
    public func close() async {
        isClosed = true
        eventFanOut.finish()
    }

    // MARK: - Private

    private func ensureUsable(_ operation: String) throws(CameraLinkFailure) {
        if isClosed { throw CameraLinkFailure(.disconnected, detail: "\(operation): the link is closed") }
    }

    private func lookup(_ id: CameraItem.ID, during operation: String)
        throws(CameraLinkFailure) -> (StagedEntry, CameraItem) {
        guard let entry = entries[id], let item = itemsByID[id] else {
            throw CameraLinkFailure(.itemNotFound, detail: "\(operation): the link doesn't know the item")
        }
        return (entry, item)
    }
}
