import CameraTransport
import Foundation
import Observation

/// One *Copy as JPEG* or *Share as JPEG…* in progress.
public struct JPEGWork: Sendable, Hashable {
    public var id: Int
    public var purpose: JPEGPurpose
    /// The file pressed.
    public var name: String
    public var stage: JPEGStage
    public var cancelling = false

    /// The fetch's fraction done, when the link reports bytes; nil while converting or with no size.
    public var fraction: Double? {
        guard case let .fetching(written, total) = stage, total > 0 else { return nil }
        return min(1, Double(written) / Double(total))
    }

    public var statusLine: String {
        cancelling ? JPEGWording.cancelling : JPEGWording.working(name: name, stage: stage)
    }
}

/// The action strip's state.
public enum JPEGActionState: Sendable, Hashable {
    case idle
    case working(JPEGWork)
    /// A confirmation, or the fallback note.
    case finished(String)
    case failed(String)

    public var isWorking: Bool {
        if case .working = self { true } else { false }
    }
}

/// A JPEG waiting for the share sheet. Its folder is removed when the sheet closes (`BrowseModel.shareFinished()`).
public struct JPEGShare: Sendable, Hashable, Identifiable {
    public var id: Int
    public var url: URL
    public var folder: JPEGScratch.ActionFolder
}

/// The thin Browse screen's model (backlog section 6, *Order*: the first slice): opens the link, waits for the card
/// with the measured expectations, shows the card newest first by day, fetches thumbnails through the link, and runs
/// *Copy as JPEG* and *Share as JPEG…*. No selection, import, filters or last-known card yet.
///
/// The screen's `.task` calls `run()`, which keeps the link open until the task is cancelled (the screen went away)
/// and then closes it.
@MainActor
@Observable
public final class BrowseModel {
    public enum Phase: Sendable, Hashable {
        /// Opening the link and waiting for ImageCaptureCore's catalogue, since `since`.
        case reading(since: Date)
        case listed
        /// The catalogue completed at once with no files: Remote Shoot (PC Remote), or an empty card in MTP.
        case listsNoFiles
        case failed(String)
        /// The camera went away; the Cameras screen takes over.
        case gone
    }

    public let camera: CameraDescriptor
    public private(set) var phase: Phase
    public private(set) var sections: [CardSection] = []
    public private(set) var action: JPEGActionState = .idle
    /// Set when a JPEG is ready to share; the screen presents the share sheet and calls `shareFinished()`.
    public private(set) var share: JPEGShare?

    @ObservationIgnored private let openLink: @Sendable () async throws(CameraLinkFailure) -> any CameraLink
    @ObservationIgnored private let services: BrowseServices
    @ObservationIgnored private let onGone: @MainActor (CameraDescriptor.ID) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var link: (any CameraLink)?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rule = JPEGSourceRule(listing: [])
    @ObservationIgnored private var thumbnails: [CameraItem.ID: Data] = [:]
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var actionCount = 0
    /// Said instead of nothing when the action in progress ends as cancelled, because the app cancelled it.
    @ObservationIgnored private var cancelMessage: String?

    public init(
        camera: CameraDescriptor,
        openLink: @escaping @Sendable () async throws(CameraLinkFailure) -> any CameraLink,
        services: BrowseServices,
        onGone: @escaping @MainActor (CameraDescriptor.ID) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.camera = camera
        self.openLink = openLink
        self.services = services
        self.onGone = onGone
        self.now = now
        self.calendar = calendar
        phase = .reading(since: now())
    }

    // MARK: - Lifecycle

    /// Opens the link, lists the card and follows the link's events until the calling task is cancelled, then
    /// closes the link. A second call while one runs does nothing.
    public func run() async {
        guard !isRunning, phase != .gone else { return }
        isRunning = true
        defer { isRunning = false }
        phase = .reading(since: now())
        let link: any CameraLink
        do throws(CameraLinkFailure) {
            link = try await openLink()
        } catch {
            if !Task.isCancelled { listingFailed(error) }
            return
        }
        self.link = link
        let events = link.events
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.follow(events) }
            group.addTask { await self.load(link) }
            await group.waitForAll()
        }
        // The screen went away (or the link's events ended): nothing more is asked of this link.
        loadTask?.cancel()
        loadTask = nil
        actionTask?.cancel()
        self.link = nil
        await link.close()
    }

    /// Lists again after a failure.
    public func retry() {
        guard case .failed = phase, let link, loadTask == nil else { return }
        phase = .reading(since: now())
        loadTask = Task { [weak self] in
            await self?.load(link)
            self?.loadTask = nil
        }
    }

    public var canRetry: Bool { link != nil }

    private func load(_ link: any CameraLink) async {
        let start = ContinuousClock.now
        do throws(CameraLinkFailure) {
            try await link.open()
            let items = try await link.list()
            guard !Task.isCancelled, phase != .gone else { return }
            rule = JPEGSourceRule(listing: items)
            sections = CardLayout.sections(items, calendar: calendar)
            phase = .listed
            services.log.note("browse: listed \(items.count) files in \(Self.seconds(since: start)) s "
                + "(\(CamerasWording.modeLine(camera.mode)) at discovery)")
        } catch {
            guard !Task.isCancelled else { return }
            services.log.note("browse: listing ended after \(Self.seconds(since: start)) s: \(error)")
            listingFailed(error)
        }
    }

    private func follow(_ events: AsyncStream<CameraLinkEvent>) async {
        for await event in events {
            switch event {
            case .removed:
                cameraGone()
            case .willSuspend:
                // The app left the foreground. Core Image renders on the GPU, which iOS refuses to a backgrounded
                // app (a failed or black render), and the fetch stops within about 2 s anyway (section 2), so the
                // action is cancelled and says why when the person comes back.
                services.log.note("browse: link event \(event)")
                cancelForSuspension()
            case .didSuspend, .cancelledSuspending, .resumedOperations:
                // Nothing else to pause in this slice; the log helps read the bench's background runs.
                services.log.note("browse: link event \(event)")
            }
        }
    }

    private func listingFailed(_ failure: CameraLinkFailure) {
        switch failure.kind {
        case .disconnected: cameraGone()
        case .modeListsNoFiles: phase = .listsNoFiles
        default: phase = .failed(BrowseWording.listingFailed(failure.kind))
        }
    }

    private func cameraGone() {
        guard phase != .gone else { return }
        phase = .gone
        actionTask?.cancel()
        onGone(camera.id)
    }

    // MARK: - Thumbnails

    /// The camera's thumbnail for a file, through the link (which keeps two in flight, newest first). Cancelled with
    /// the calling task, so a cell scrolled away gives up its place. Nil when it can't be had.
    public func thumbnail(for id: CameraItem.ID) async -> Data? {
        if let data = thumbnails[id] { return data }
        guard let link, phase == .listed else { return nil }
        guard let data = try? await link.thumbnail(of: id) else { return nil }
        thumbnails[id] = data
        return data
    }

    // MARK: - Copy as JPEG and Share as JPEG…

    /// Whether a file offers the two actions: a still, while the card is listed and no other action runs.
    public func offersJPEGActions(_ item: CameraItem) -> Bool {
        CardLayout.kind(of: item).offersJPEGActions
    }

    public var isBusy: Bool { action.isWorking || share != nil }

    public func copyAsJPEG(_ item: CameraItem) { start(.copy, item) }
    public func shareAsJPEG(_ item: CameraItem) { start(.share, item) }

    /// Cancels the action in progress; its temporary folder is removed when it stops.
    public func cancelAction() {
        guard case var .working(work) = action, !work.cancelling else { return }
        work.cancelling = true
        action = .working(work)
        actionTask?.cancel()
    }

    /// The app left the foreground during an action: cancel it, and say so once it has stopped.
    private func cancelForSuspension() {
        guard case let .working(work) = action, !work.cancelling else { return }
        services.log.note("copy-as-jpeg \(work.purpose.rawValue) cancelled: the app left the foreground")
        cancelMessage = JPEGWording.keepOpen
        cancelAction()
    }

    /// The share sheet closed, whatever was chosen: the JPEG's folder goes.
    public func shareFinished() {
        guard let share else { return }
        services.scratch.remove(share.folder)
        self.share = nil
    }

    /// The share sheet couldn't be shown.
    public func shareFailed() {
        shareFinished()
        action = .failed(JPEGWording.failed(.shareUnavailable) ?? "")
    }

    /// Clears a confirmation or an error.
    public func dismissMessage() {
        switch action {
        case .finished, .failed: action = .idle
        case .idle, .working: break
        }
    }

    private func start(_ purpose: JPEGPurpose, _ item: CameraItem) {
        guard !isBusy, phase == .listed, let link, let source = rule.source(for: item) else { return }
        let folder: JPEGScratch.ActionFolder
        do {
            folder = try services.scratch.makeActionFolder()
        } catch {
            action = .failed(JPEGWording.failed(.storage(detail: "\(type(of: error))")) ?? "")
            return
        }
        actionCount += 1
        let id = actionCount
        cancelMessage = nil
        action = .working(JPEGWork(id: id, purpose: purpose, name: item.name,
                                   stage: .fetching(written: 0, total: source.fetched.size)))
        let pipeline = JPEGPipeline(link: link, maker: services.maker)
        actionTask = Task {
            let outcome = await pipeline.run(source, purpose: purpose, in: folder) { stage in
                Task { @MainActor in self.progressed(id, stage) }
            }
            // A cancel that came after the pipeline's last check (Cancel, leaving Browse, the app leaving the
            // foreground) still wins: nothing reaches the clipboard or the share sheet, and the folder goes.
            let result: Result<JPEGOutput, JPEGActionFailure> = Task.isCancelled ? .failure(.cancelled) : outcome
            self.finish(id, purpose, source, folder, result)
        }
    }

    private func progressed(_ id: Int, _ stage: JPEGStage) {
        guard case var .working(work) = action, work.id == id else { return }
        // Bytes only move forward; a late report never takes the line back from converting to fetching.
        switch (work.stage, stage) {
        case (.converting, .fetching): return
        case let (.fetching(old, _), .fetching(new, _)) where new < old: return
        default: break
        }
        work.stage = stage
        action = .working(work)
    }

    private func finish(_ id: Int, _ purpose: JPEGPurpose, _ source: JPEGSource,
                        _ folder: JPEGScratch.ActionFolder, _ outcome: Result<JPEGOutput, JPEGActionFailure>) {
        actionTask = nil
        let cancelMessage = self.cancelMessage
        self.cancelMessage = nil
        switch outcome {
        case let .success(output):
            services.log.note(output.record.logLine)
            switch purpose {
            case .copy:
                do {
                    try services.clipboard.copyJPEG(at: output.url)
                    action = .finished(JPEGWording.copied(pressedName: source.pressed.name,
                                                          embeddedPreview: output.isEmbeddedPreview))
                } catch {
                    services.log.note("copy-as-jpeg clipboard refused the JPEG: \(type(of: error))")
                    action = .failed(JPEGWording.failed(.clipboard(detail: "\(type(of: error))")) ?? "")
                }
                services.scratch.remove(folder)
            case .share:
                guard phase != .gone else {
                    services.scratch.remove(folder)
                    action = .idle
                    return
                }
                share = JPEGShare(id: id, url: output.url, folder: folder)
                action = output.isEmbeddedPreview ? .finished(JPEGWording.sharingPreview) : .idle
            }
        case let .failure(failure):
            services.scratch.remove(folder)
            if case let .link(linkFailure) = failure, linkFailure.kind == .disconnected { cameraGone() }
            if failure != .cancelled {
                services.log.note("copy-as-jpeg \(purpose.rawValue) \(source.kind.rawValue) failed: \(failure)")
            }
            if failure == .cancelled, let cancelMessage {
                action = .failed(cancelMessage)
            } else {
                action = JPEGWording.failed(failure).map(JPEGActionState.failed) ?? .idle
            }
        }
    }

    // MARK: - For tests

    /// Waits for the action in progress, if any, to finish.
    func waitForAction() async {
        await actionTask?.value
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        JPEGBenchRecord.format(JPEGPipeline.seconds(ContinuousClock.now - start))
    }
}
