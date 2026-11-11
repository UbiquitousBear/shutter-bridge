import Dispatch
import Foundation
import Synchronization

/// What a staged file looks like before it is copied, as far as a reader can tell without reading it.
public enum StagedPresence: Sendable, Hashable {
    /// The file is there with the size the entry names, or the reader can't tell yet (an iCloud file not downloaded).
    case present
    /// Nothing is at the entry's URL.
    case missing
    /// A file is there but its size isn't the entry's: it was replaced or is still being written.
    case sizeChanged
}

/// How `StagingFolderLink` reads a staged file. The reader copies and never moves: the file in Staging is still
/// there, byte for byte, when the copy ends, whatever happens to the copy. Every failure is already a
/// `CameraLinkFailure`, so the link classifies nothing itself.
///
/// `PlainStagedFileReader` is the Foundation reader, tested on Linux. On iOS `StagedFileReaders.platform` is the
/// coordinated reader, which also downloads an iCloud file that has been evicted; tests give the link a reader of
/// their own (a slow one, for cancellation).
public protocol StagedFileReading: Sendable {
    /// Whether the file at `source` is there with `expectedSize` bytes, without opening it.
    func presence(of source: URL, expectedSize: UInt64) -> StagedPresence

    /// Copies `source` to `destination`, replacing a file already there, and returns once all `expectedSize` bytes are
    /// on disk. `progress` gets the bytes written so far. A file that is gone, or whose size isn't `expectedSize`
    /// when the copy begins or ends, throws `itemNotFound`; a full phone throws `phoneStorageFull`; anything else
    /// that goes wrong throws `unreadableItem`. A cancelled call throws `busy` (the link's own convention for a
    /// cancel, which the engine ignores) and leaves no file at `destination`. Any other failure leaves none either.
    func copy(
        _ source: URL, expectedSize: UInt64, to destination: URL,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure)
}

/// The readers a caller can choose between.
public enum StagedFileReaders {
    /// The reader the app uses: coordinated and ubiquity-aware on iOS, the plain one elsewhere (Linux and the Mac,
    /// where `swift test` runs).
    public static var platform: any StagedFileReading {
        #if os(iOS)
        CoordinatedStagedFileReader()
        #else
        PlainStagedFileReader()
        #endif
    }
}

/// Reads with `FileHandle`, one chunk at a time on a dispatch queue, so a large file neither sits in memory nor blocks
/// the cooperative pool, and a cancel is seen within one chunk.
public struct PlainStagedFileReader: StagedFileReading {
    public init() {}

    public func presence(of source: URL, expectedSize: UInt64) -> StagedPresence {
        StagedFileCopy.presence(of: source, expectedSize: expectedSize)
    }

    public func copy(
        _ source: URL, expectedSize: UInt64, to destination: URL,
        progress: @escaping @Sendable (UInt64) -> Void
    ) async throws(CameraLinkFailure) {
        let outcome = await StagedFileCopy.offThePool { isCancelled in
            do throws(CameraLinkFailure) {
                try StagedFileCopy.copy(
                    from: source, to: destination, expectedSize: expectedSize, isCancelled: isCancelled,
                    progress: progress)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        if case let .failure(failure) = outcome { throw failure }
    }
}

/// The synchronous copy both readers share, kept apart from any queue so it is tested directly.
enum StagedFileCopy {
    /// 1 MiB: a cancel is seen within one chunk, and a 50 MB ARW reports about fifty times.
    static let chunkSize = 1 << 20

    static func cancelled() -> CameraLinkFailure {
        CameraLinkFailure(.busy, detail: "staging copy: cancelled")
    }

    /// The size on disk of the regular file at `url`, or nil when there is none (a folder is none).
    static func size(of url: URL) -> UInt64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    static func presence(of url: URL, expectedSize: UInt64) -> StagedPresence {
        guard let size = size(of: url) else { return .missing }
        return size == expectedSize ? .present : .sizeChanged
    }

    /// The bytes to report while an evicted iCloud file downloads, `percent` (0 to 100) of the way. The engine's meter
    /// only counts a number that grows, and the local copy that follows reports from zero again, so the download
    /// takes the first half of the file's size: the copy then passes it within moments (it reads from the phone's
    /// own storage) and the stall clock never waits on the handover. NaN, negative and over-100 values are clamped.
    static func downloadProgress(percent: Double, expectedSize: UInt64) -> UInt64 {
        guard percent.isFinite, percent > 0 else { return 0 }
        let fraction = min(percent, 100) / 100
        return UInt64(fraction * Double(expectedSize / 2))
    }

    private static func gone(_ presence: StagedPresence, detail: String) -> CameraLinkFailure? {
        switch presence {
        case .present: nil
        case .missing: CameraLinkFailure(.itemNotFound, detail: "\(detail): the staged file is gone")
        case .sizeChanged: CameraLinkFailure(.itemNotFound, detail: "\(detail): the staged file's size changed")
        }
    }

    /// A failure on the phone's side of the copy: a full phone stops the job, anything else skips the file.
    private static func writeFailure(_ error: any Error) -> CameraLinkFailure {
        if USBFailureMapping.isOutOfSpace(error) {
            return CameraLinkFailure(.phoneStorageFull, detail: "staging copy: the phone is full")
        }
        let ns = error as NSError
        return CameraLinkFailure(.unreadableItem, detail: "staging copy: couldn't write (\(ns.domain) \(ns.code))")
    }

    private static func readFailure(_ error: any Error) -> CameraLinkFailure {
        let ns = error as NSError
        return CameraLinkFailure(.unreadableItem, detail: "staging copy: couldn't read (\(ns.domain) \(ns.code))")
    }

    /// Copies `source` into `destination` in chunks. Never touches `source` but to read it.
    static func copy(
        from source: URL, to destination: URL, expectedSize: UInt64, chunkSize: Int = StagedFileCopy.chunkSize,
        isCancelled: () -> Bool, progress: (UInt64) -> Void
    ) throws(CameraLinkFailure) {
        if isCancelled() { throw cancelled() }
        if let failure = gone(presence(of: source, expectedSize: expectedSize), detail: "staging copy") { throw failure }

        let reader: FileHandle
        do { reader = try FileHandle(forReadingFrom: source) } catch { throw readFailure(error) }
        defer { try? reader.close() }

        let writer: FileHandle
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            writer = try FileHandle(forWritingTo: destination)
        } catch {
            throw writeFailure(error)
        }

        do throws(CameraLinkFailure) {
            defer { try? writer.close() }
            var written: UInt64 = 0
            while true {
                if isCancelled() { throw cancelled() }
                let chunk: Data?
                do { chunk = try reader.read(upToCount: chunkSize) } catch { throw readFailure(error) }
                guard let chunk, !chunk.isEmpty else { break }
                written += UInt64(chunk.count)
                if written > expectedSize {
                    throw CameraLinkFailure(.itemNotFound, detail: "staging copy: the staged file's size changed")
                }
                do { try writer.write(contentsOf: chunk) } catch { throw writeFailure(error) }
                progress(written)
            }
            // A file that ended short, or whose size moved while it was read, isn't the file the entry named.
            if written != expectedSize || size(of: source) != expectedSize {
                throw CameraLinkFailure(.itemNotFound, detail: "staging copy: the staged file's size changed")
            }
            if expectedSize == 0 { progress(0) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Runs blocking work on a dispatch queue and waits without holding a cooperative thread. The work is handed a
    /// check for the caller's cancellation, which it makes between chunks.
    static func offThePool(
        _ work: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) -> Result<Void, CameraLinkFailure>
    ) async -> Result<Void, CameraLinkFailure> {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: work { flag.isSet })
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}

/// Set once by a task's cancellation handler and read by the copy on its queue.
final class CancelFlag: Sendable {
    private let state = Mutex(false)

    func set() { state.withLock { $0 = true } }

    var isSet: Bool { state.withLock { $0 } }
}

#if os(iOS)
/// The reader for Staging on the phone. Compiled only by CI's Xcode 27 job and checked on the bench with an evicted
/// file (I5): nothing here runs on Linux.
///
/// - An iCloud file that isn't on the phone (`ubiquitousItemDownloadingStatus` is `.notDownloaded`, or only the legacy
///   `.name.icloud` placeholder is beside it) is asked for with `startDownloadingUbiquitousItem(at:)` and waited for,
///   polling its status every 250 ms; the wait ends when the file is on the phone, the call is cancelled, or
///   `downloadTimeout` passes (`noAnswer`, which the engine retries a few times and then fails the file; the
///   keeper stays in Staging either way). A file that is on the phone but not the newest version
///   (`.downloaded`) is read as it is.
/// - The wait reports progress, because the engine counts 30 s without it as a stall (`ImportPolicy.stallTimeout`)
///   and a download can take longer: an `NSMetadataQuery` on the file's folder gives
///   `NSMetadataUbiquitousItemPercentDownloadedKey`, which `StagedFileCopy.downloadProgress` maps to the first half
///   of the file's size. `unverified` on the bench (I5): whether the query finds a file in the app's Staging folder,
///   and whether the percent moves during a real download. If it never reports, a download over 30 s stalls the job.
/// - The copy itself runs inside `NSFileCoordinator`'s read coordination, so it never reads a file another process
///   (the Files app, the iCloud daemon) is writing.
public struct CoordinatedStagedFileReader: StagedFileReading {
    public var downloadTimeout: Duration

    public init(downloadTimeout: Duration = .seconds(15 * 60)) {
        self.downloadTimeout = downloadTimeout
    }

    public func presence(of source: URL, expectedSize: UInt64) -> StagedPresence {
        // An evicted file can't be sized without downloading it, so it counts as there until the copy checks.
        if Self.isEvicted(source) { return .present }
        return StagedFileCopy.presence(of: source, expectedSize: expectedSize)
    }

    public func copy(
        _ source: URL, expectedSize: UInt64, to destination: URL,
        progress: @escaping @Sendable (UInt64) -> Void
    ) async throws(CameraLinkFailure) {
        try await downloadIfEvicted(source, expectedSize: expectedSize, progress: progress)
        let outcome = await StagedFileCopy.offThePool { isCancelled in
            var coordinationError: NSError?
            var result: Result<Void, CameraLinkFailure> = .failure(
                CameraLinkFailure(.unreadableItem, detail: "staging copy: the coordinated read didn't run"))
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: source, options: [], error: &coordinationError
            ) { coordinatedURL in
                do throws(CameraLinkFailure) {
                    try StagedFileCopy.copy(
                        from: coordinatedURL, to: destination, expectedSize: expectedSize, isCancelled: isCancelled,
                        progress: progress)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError {
                let isMissing = coordinationError.domain == NSCocoaErrorDomain
                    && coordinationError.code == NSFileReadNoSuchFileError
                return .failure(CameraLinkFailure(
                    isMissing ? .itemNotFound : .unreadableItem,
                    detail: "staging copy: coordination failed (\(coordinationError.domain) \(coordinationError.code))"))
            }
            return result
        }
        if case let .failure(failure) = outcome { throw failure }
    }

    private func downloadIfEvicted(
        _ source: URL, expectedSize: UInt64, progress: @escaping @Sendable (UInt64) -> Void
    ) async throws(CameraLinkFailure) {
        guard Self.isEvicted(source) else { return }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: source)
        } catch {
            let ns = error as NSError
            throw CameraLinkFailure(.unreadableItem, detail: "staging copy: iCloud download didn't start (\(ns.domain) \(ns.code))")
        }
        let watcher = await DownloadWatcher(watching: source)
        defer { Task { await watcher.stop() } }
        let deadline = ContinuousClock.now.advanced(by: downloadTimeout)
        while Self.isEvicted(source) {
            if Task.isCancelled { throw StagedFileCopy.cancelled() }
            if ContinuousClock.now >= deadline {
                throw CameraLinkFailure(.noAnswer, detail: "staging copy: the iCloud download didn't finish in time")
            }
            if let percent = await watcher.percentDownloaded() {
                progress(StagedFileCopy.downloadProgress(percent: percent, expectedSize: expectedSize))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// True for an iCloud file whose content isn't on the phone: a dataless file, or only the legacy placeholder.
    static func isEvicted(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if !FileManager.default.fileExists(atPath: url.path) {
            return FileManager.default.fileExists(atPath: placeholder.path)
        }
        // A URL caches the resource values it has read, and this is polled from threads with no run loop to clear the
        // cache, so each read is on a URL of its own.
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
            values.isUbiquitousItem == true,
            let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status == .notDownloaded
    }
}

/// An `NSMetadataQuery` for one file, whose results the reader reads while an iCloud download runs. The query needs
/// the main run loop, so this lives on the main actor (which also makes it `Sendable`).
@MainActor
private final class DownloadWatcher {
    private let query = NSMetadataQuery()

    init(watching url: URL) {
        query.searchScopes = [url.deletingLastPathComponent()]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, url.path)
        query.start()
    }

    /// 0 to 100, or nil while the query has gathered nothing or the file isn't in it.
    func percentDownloaded() -> Double? {
        query.disableUpdates()
        defer { query.enableUpdates() }
        guard let item = query.results.first as? NSMetadataItem else { return nil }
        return item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double
    }

    func stop() { query.stop() }
}
#endif
