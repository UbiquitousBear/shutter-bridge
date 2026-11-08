import Foundation

/// A connection to one camera over one carrier. Links are dumb pipes that answer list, info, thumb, bytes and events
/// and nothing else; jobs, ordering, pausing and resume belong to the engine (proposal, "System architecture").
/// Each link is an actor that owns its connection, so its calls are serialised the way a PTP session needs.
///
/// Every call throws only `CameraLinkFailure`, so each failure arrives already classified into one of the engine's
/// four outcomes.
public protocol CameraLink: Actor {
    /// The camera this link talks to.
    nonisolated var descriptor: CameraDescriptor { get }

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

    /// Copies one file into `directory` without holding it in memory and returns where it was written. `progress`
    /// is called with the bytes written so far, if the link can tell. An interrupted file is copied again from its
    /// start (decision 7).
    func bytes(
        of item: CameraItem.ID,
        into directory: URL,
        progress: @escaping @Sendable (_ bytesWritten: UInt64) -> Void
    ) async throws(CameraLinkFailure) -> URL

    /// Closes the session and finishes `events`. Closing a closed link does nothing.
    func close() async
}

extension CameraLink {
    /// `bytes(of:into:progress:)` without a progress callback.
    public func bytes(of item: CameraItem.ID, into directory: URL) async throws(CameraLinkFailure) -> URL {
        try await bytes(of: item, into: directory, progress: { _ in })
    }
}
