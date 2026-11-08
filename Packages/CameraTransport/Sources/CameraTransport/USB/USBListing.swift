import Foundation

/// One file as ImageCaptureCore's catalogue shows it, read off an `ICCameraFile` by `USBLink` so the rest of the
/// listing logic is pure and unit-tested on Linux.
struct USBCatalogueEntry: Sendable, Hashable {
    /// The link's handle for the file in this session.
    var id: CameraItem.ID
    /// The names of the folders above the file, nearest first (`parentFolder`, then its parent, and so on).
    var ancestorsNearestFirst: [String]
    var name: String?
    /// `ICCameraFile.fileSize` (an `off_t`).
    var fileSize: Int64
    /// `ICCameraItem.creationDate`, which matched `GetObjectInfo`'s capture date for an ARW and a JPG in MTP.
    var creationDate: Date?
}

/// From ImageCaptureCore's items to `CameraItem`s, newest first (backlog section 2, *List and info*).
enum USBListing {
    /// The deepest folder walk followed, against a loop in a faulty tree.
    static let maximumFolderDepth = 16

    /// "DCIM/100MSDCF" from ["100MSDCF", "DCIM"]. Empty names are dropped; empty when there is no folder, as for MTP
    /// items if they carry no parent (MTP's `contents` tree was empty on the bench). Whether the MSC tree's top
    /// folder is the card's volume ("Untitled/DCIM/…") isn't recorded: `unverified`, a week-1 check (section 4
    /// decides the identity either way, and the path is stable on one card whichever it is).
    static func folderPath(ancestorsNearestFirst: [String]) -> String {
        ancestorsNearestFirst.prefix(maximumFolderDepth).reversed().filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// One item, or nil for a file with no name (nothing can be imported or matched without one).
    static func item(from entry: USBCatalogueEntry) -> CameraItem? {
        guard let name = entry.name, !name.isEmpty else { return nil }
        return CameraItem(id: entry.id, folder: folderPath(ancestorsNearestFirst: entry.ancestorsNearestFirst),
                          name: name, size: UInt64(max(0, entry.fileSize)), captureDate: entry.creationDate)
    }

    /// The whole listing, newest first, and each item's rank in it (0 is the newest) for the thumbnail queue.
    static func listing(from entries: [USBCatalogueEntry]) -> (items: [CameraItem], ranks: [CameraItem.ID: Int]) {
        let items = entries.compactMap(item(from:)).newestFirst()
        var ranks: [CameraItem.ID: Int] = [:]
        for (rank, item) in items.enumerated() { ranks[item.id] = rank }
        return (items, ranks)
    }

    /// Where a finished download is, from the completion's string: documented only as a `String?`, and on the bench
    /// a file name inside the requested folder; an absolute path is taken as it is, and nil means the file's own
    /// name.
    static func downloadedURL(completionName: String?, fileName: String, directory: URL) -> URL {
        guard let saved = completionName, !saved.isEmpty else { return directory.appendingPathComponent(fileName) }
        return saved.hasPrefix("/") ? URL(fileURLWithPath: saved) : directory.appendingPathComponent(saved)
    }

    /// The bytes written so far from a `Progress` fraction (whether ImageCaptureCore moves it during a download is
    /// `unverified`; the spike's build-14 copy logged it). Clamped to 0…size.
    static func bytesWritten(fraction: Double, size: UInt64) -> UInt64 {
        guard fraction.isFinite, fraction > 0 else { return 0 }
        guard fraction < 1 else { return size }
        return UInt64((Double(size) * fraction).rounded(.down))
    }
}

/// How a USB link's catalogue went, for the week-1 bench checks (backlog section 2): the listing time, whether
/// ImageCaptureCore announced files before its catalogue completed (does MSC deliver them as they arrive?), and
/// whether the completion came from its callback or from the percentage reading 100 (the callback can be missing on
/// a reopen, as the spike saw).
public struct USBCatalogueTiming: Sendable, Hashable {
    /// From the open request to the catalogue completing; nil until it has.
    public var secondsToComplete: Double?
    /// Items announced through `cameraDevice(_:didAdd:)` before the catalogue completed.
    public var itemsAnnouncedBeforeComplete: Int
    /// Files in the catalogue when it completed; nil until it has.
    public var filesAtCompletion: Int?
    /// True if the completion was inferred from the percentage, not from ImageCaptureCore's callback.
    public var completedWithoutCallback: Bool

    public init(secondsToComplete: Double? = nil, itemsAnnouncedBeforeComplete: Int = 0, filesAtCompletion: Int? = nil,
                completedWithoutCallback: Bool = false) {
        self.secondsToComplete = secondsToComplete
        self.itemsAnnouncedBeforeComplete = itemsAnnouncedBeforeComplete
        self.filesAtCompletion = filesAtCompletion
        self.completedWithoutCallback = completedWithoutCallback
    }
}

/// When ImageCaptureCore's catalogue counts as complete without its callback: once `contentCatalogPercentCompleted`
/// has read 100 for `hold`, counted from the first reading of 100, which is also the instant reported as the
/// completion (as the spike did). `USBLink` reads it at open and while `list` waits, so the instant, and with it the
/// MTP-or-Remote-Shoot answer, doesn't depend on when `list` is called. Pure, so it is unit-tested on Linux.
struct USBCatalogueWatch: Sendable {
    /// How long 100 % must hold without the callback (the spike's 10 s).
    static let hold: Duration = .seconds(10)

    /// The first reading of 100, if there has been one.
    private(set) var fullSince: ContinuousClock.Instant?

    /// One reading of the percentage at `now`: the instant the catalogue counts as complete once the hold has
    /// passed, otherwise nil.
    mutating func read(percent: Int, at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard percent >= 100 else { return nil }
        guard let since = fullSince else {
            fullSince = now
            return nil
        }
        return now - since > Self.hold ? since : nil
    }
}

/// The bytes a download reports while it runs, from its `Progress` fraction: only increases, never the full size
/// (reported once the file is on disk), and nothing once the download has ended. `USBLink` keeps one per download on
/// its actor and reports from there, so no poll can land after `bytes` has reported the size on disk. Pure, so it
/// is unit-tested on Linux.
struct USBProgressReports: Sendable {
    let size: UInt64
    private(set) var last: UInt64?
    private(set) var ended = false

    init(size: UInt64) { self.size = size }

    /// A poll of the fraction: the bytes to report now, or nil (no progress, the full size, or the download ended).
    mutating func poll(fraction: Double) -> UInt64? {
        guard !ended else { return nil }
        let bytes = USBListing.bytesWritten(fraction: fraction, size: size)
        guard bytes < size, last.map({ bytes > $0 }) ?? true else { return nil }
        last = bytes
        return bytes
    }

    /// The download finished, failed or was cancelled: later polls report nothing.
    mutating func end() { ended = true }
}
