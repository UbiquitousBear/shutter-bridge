import CameraTransport
import Catalogue
import PhotosBridge

/// Runs one import job at a time: discover, open, enumerate and diff, download, commit (proposal, "Import engine
/// design"). The single writer of job state. Transport-neutral: pausing, continuing, stalls and retries are its
/// rules, not a link's, because the Wi-Fi link in Iteration 3 needs the same ones (backlog section 0).
///
/// This is the public surface only. The stages arrive with backlog section 3; until then `start` throws
/// `ImportEngineError.notBuilt` rather than pretending to import.
public actor ImportEngine {
    /// Progress of the current job. One consumer, the Import screen's view model.
    public nonisolated let progress: AsyncStream<ImportProgress>
    private let progressContinuation: AsyncStream<ImportProgress>.Continuation

    public private(set) var state: ImportJobState = .idle
    public let settings: ImportSettings

    private let catalogue: any CatalogueStore

    public init(catalogue: any CatalogueStore, settings: ImportSettings = ImportSettings()) {
        self.catalogue = catalogue
        self.settings = settings
        (progress, progressContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit { progressContinuation.finish() }

    /// Starts a job: the selection from `link`'s card, into `destination` (Photos, or the Files folder when Photos
    /// access is denied; the caller reads the access level first, backlog section 5).
    public func start(
        _ selection: ImportSelection,
        from link: any CameraLink,
        to destination: any ImportDestination
    ) throws(ImportEngineError) {
        guard !state.isActive else { throw .jobInProgress }
        guard !selection.isEmpty else { throw .emptySelection }
        throw .notBuilt
    }

    /// Adds files picked in Browse while a job runs; they go at the end (backlog section 3).
    public func append(_ items: [CameraItem]) throws(ImportEngineError) {
        guard state.isActive else { throw .noJob }
        throw .notBuilt
    }

    /// Pauses the job at the person's request.
    public func pause() throws(ImportEngineError) {
        guard state.isActive else { throw .noJob }
        throw .notBuilt
    }

    /// Continues a paused job in the same session, without reopening it when the session is still there.
    public func resume() throws(ImportEngineError) {
        guard state.isActive else { throw .noJob }
        throw .notBuilt
    }

    /// Cancels the job, if there is one. Files already committed stay where they went.
    public func cancel() {
        guard state.isActive else { return }
        state = .finished(.cancelled)
    }
}
