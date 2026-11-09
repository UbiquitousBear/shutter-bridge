import Foundation

/// A connection to one camera over one carrier. Links are dumb pipes that answer list, info, thumb, bytes and events
/// and nothing else; jobs, ordering, pausing and resume belong to the engine (proposal, "System architecture").
/// Each link is an actor that owns its connection, so its calls are serialised the way a PTP session needs.
///
/// Every call throws only `CameraLinkFailure`, so each failure arrives already classified into one of the engine's
/// four outcomes.
///
/// What differs between carriers is declared in `capabilities` and read by the engine; no code outside a link
/// branches on the carrier. A link that can't resume (USB) ignores the `resuming` argument of `bytes` and copies the
/// file from its start.
public protocol CameraLink: Actor {
    /// The camera this link talks to.
    nonisolated var descriptor: CameraDescriptor { get }

    /// What this link can do, fixed for its life (`CameraLinkCapabilities.defaults(for:)` is the carrier's baseline).
    nonisolated var capabilities: CameraLinkCapabilities { get }

    /// Removal and the session's lifecycle, live: each read returns a new stream that gets only the events that
    /// happen after it was read, never one from before (a link must not buffer events for a consumer that isn't
    /// there yet, or a suspension during Browse would pause an import started later). The engine reads it once per
    /// link and keeps reading; every stream finishes when the link closes, or straight after `.removed` for a link
    /// that can't be used again (`USBLink`). `EventFanOut` gives a link these semantics.
    nonisolated var events: AsyncStream<CameraLinkEvent> { get }

    /// Opens the session. Over USB in MTP no PTP command is sent until ImageCaptureCore's catalogue has finished,
    /// and in MSC none at all (backlog section 2, *Open*). Opening an open link does nothing.
    func open() async throws(CameraLinkFailure)

    /// Every file on the card. Over USB this waits for ImageCaptureCore's catalogue: 7–12 s in MSC and 65–123 s in
    /// MTP on the bench (backlog section 2); the last-known card is the catalogue's to show meanwhile.
    func list() async throws(CameraLinkFailure) -> [CameraItem]

    /// The current facts about one file, for checking it before and after a download.
    func info(of item: CameraItem.ID) async throws(CameraLinkFailure) -> CameraItem

    /// The camera's thumbnail for one file, most likely its 160 × 120 JPEG.
    func thumbnail(of item: CameraItem.ID) async throws(CameraLinkFailure) -> Data

    /// Copies one file without holding it in memory and returns where it was written. A fresh copy is written into
    /// `directory` under the camera's file name, overwriting what an interrupted copy left there.
    ///
    /// **Resume.** With `resuming` and `capabilities.resumesPartialFiles`, the link continues the file at
    /// `resuming.file` from `resuming.bytesWritten` (the file's own length is trusted no further: the link cuts
    /// the file back to that offset first), and returns that URL; `directory` is not used. The caller has already
    /// checked the item's name and size against what the partial was started from (the ID is a hint, not an
    /// identity). A link that can't resume ignores `resuming` and copies the file from its start into `directory`;
    /// the engine offers a partial file only when `capabilities.resumesPartialFiles` is true (`ImportEngine`, W7).
    /// Resuming a file the
    /// camera no longer has throws `itemNotFound` like any other call. A partial the link can't continue from (the
    /// file is missing or shorter than the offset) is copied again from 0 into the same file.
    ///
    /// **Checkpoint.** A link that can resume calls `checkpoint` each time the first `bytesWritten` bytes of the
    /// camera's file are on disk and a resume could start there (Wi-Fi, if the link reads in chunks: say after each
    /// 4 MiB 0x9211 chunk but the last; whether new files use chunked 0x9211 or GetObject is still open, backlog
    /// Iteration 3), with the file and that offset. The engine decides which of these to keep (every 16 MiB,
    /// `PTPPartialRead.crossesCheckpoint`).
    /// A link that can't resume never calls it. It is called from the link's own context, in order, and never
    /// after `bytes` has returned or thrown.
    ///
    /// **Progress.** `progress` is called with the bytes written so far *in the file* (a resumed copy starts at its
    /// offset, not at 0), if the link can tell.
    func bytes(
        of item: CameraItem.ID,
        into directory: URL,
        resuming: PartialDownload?,
        checkpoint: @escaping @Sendable (PartialDownload) -> Void,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL

    /// Closes the session and finishes `events`. Closing a closed link does nothing.
    func close() async
}

extension CameraLink {
    /// A fresh copy: `bytes(of:into:resuming:checkpoint:progress:)` with nothing to resume and no checkpoints kept.
    public func bytes(
        of item: CameraItem.ID,
        into directory: URL,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL {
        try await bytes(of: item, into: directory, resuming: nil, checkpoint: { _ in }, progress: progress)
    }

    /// `bytes(of:into:progress:)` without a progress callback.
    public func bytes(of item: CameraItem.ID, into directory: URL) async throws(CameraLinkFailure) -> URL {
        try await bytes(of: item, into: directory, progress: { _ in })
    }
}

/// A file the link began to copy and the bytes of it that are on disk: what a resume continues from. Written by
/// the link's `checkpoint` callback, kept by the engine in the catalogue (`.partial` rows, Iteration 3), and given
/// back through `resuming`.
public struct PartialDownload: Sendable, Hashable {
    /// The partly written file.
    public var file: URL
    /// How many of its bytes are good, counted from the start of the camera's file. The resume offset.
    public var bytesWritten: UInt64

    public init(file: URL, bytesWritten: UInt64) {
        self.file = file
        self.bytesWritten = bytesWritten
    }
}
