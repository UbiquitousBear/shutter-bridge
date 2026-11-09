import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import Observation
import PhotosBridge

/// One row of the Import screen: a file of the job with its state and progress in words.
public struct ImportRow: Sendable, Hashable, Identifiable {
    public var id: ImportFileStatus.ID
    public var name: String
    public var phase: ImportFileStatus.Phase
    /// 0 to 1, by bytes.
    public var fraction: Double
    /// "Copying from the camera", "Imported to Photos", "Skipped: no longer on the card"…
    public var stateText: String
    /// "12.3 MB of 45.6 MB" while copying, the size otherwise.
    public var sizeText: String
    /// How a row's symbol is coloured (HIG Colour: the reason text stays primary, never orange).
    public enum Tone: Sendable, Hashable {
        /// Waiting, copying, saving or not imported: secondary.
        case neutral
        /// Imported: green.
        case done
        /// Skipped: orange.
        case skipped
        /// Failed: red.
        case failed
    }

    /// Skipped or failed: drawn as a problem, with the reason in the primary text colour.
    public var isProblem: Bool
    /// The symbol's colour.
    public var tone: Tone
    /// Downloading or committing: drawn with a bar.
    public var isInFlight: Bool
    public var accessibilityLabel: String

    public init(_ status: ImportFileStatus, going kind: DestinationKind?) {
        id = status.id
        name = status.item.name
        phase = status.phase
        fraction = status.fractionCompleted
        stateText = ImportWording.row(status.phase, item: status.item, going: kind)
        sizeText = ImportWording.rowSize(status)
        switch status.phase {
        case .skipped: tone = .skipped
        case .failed: tone = .failed
        case .imported: tone = .done
        default: tone = .neutral
        }
        isProblem = tone == .skipped || tone == .failed
        switch status.phase {
        case .downloading, .committing: isInFlight = true
        default: isInFlight = false
        }
        accessibilityLabel = ImportWording.rowAccessibility(name: name, state: stateText, size: sizeText,
                                                            fraction: isInFlight ? fraction : nil)
    }
}

/// The Import screen's model (backlog section 6, *Import*), one per app over the one `ImportEngine`. It starts jobs
/// from Browse (resolving the destination and asking for Photos access at the first Import), adds files picked while
/// a job runs, pauses, continues and cancels, follows the scene's phase (decision 1: pause when the app leaves the
/// foreground over USB, carry on when it is back), reconnects after a removed cable (decision 7), and says all of it
/// in the person's words.
///
/// How the app uses it:
/// - Browse's Import calls `importItems(_:from:link:)` (as `BrowseImporting`).
/// - The scene's phase goes to `scenePhaseChanged(_:)`; `keepsScreenOn` drives `UIApplication.isIdleTimerDisabled`.
/// - `cameraFinder` is the Cameras model, and `cameraConnected()` is called when discovery reports a camera.
/// - The screen shows `statusLine`, `destinationLine`, `filesReasonLine` (with the Settings button when
///   `offersPhotosSettingsLink`), `bytesLine`, `rateLine`, `timeLeftLine`, `rows`, and the buttons as `canPause`,
///   `canResume`, `canCancel` and `isFinished` say.
@MainActor
@Observable
public final class ImportModel: BrowseImporting {
    /// The job's progress and files, as last read from the engine.
    public private(set) var snapshot: ImportSnapshot = .none
    public private(set) var rows: [ImportRow] = []
    /// The camera of the job shown; nil when there is none (before the first job, or after `dismiss()`).
    public private(set) var camera: ImportCamera?
    /// The job's folder in Files (On My iPhone › Shutter Bridge › this).
    public private(set) var filesFolderName: String?
    /// True while the Photos prompt is up, at the first Import.
    public private(set) var isAskingForPhotosAccess = false
    /// Goes up each time more files are imported. Browse follows it through `importedUpdates()`.
    public private(set) var importedRevision = 0
    /// A refusal or failure to start, for the screen that asked; cleared by the next request.
    public private(set) var message: String?

    @ObservationIgnored public weak var cameraFinder: (any CameraFinding)?

    @ObservationIgnored private let engine: ImportEngine
    @ObservationIgnored private let settings: any DestinationSettingStore
    @ObservationIgnored private let photos: any PhotosAuthorising
    @ObservationIgnored private let destinations: any ImportDestinationMaking
    @ObservationIgnored private let leases: LinkLeases
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// The link the job uses, held in `leases` until the job ends.
    @ObservationIgnored private var link: (any CameraLink)?
    /// The setting the job started with: a continue re-reads Photos access, not the setting (the next import
    /// follows the setting).
    @ObservationIgnored private var jobSetting = DestinationSetting.default
    @ObservationIgnored private var jobDestinations: ImportDestinations?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var reconnecting = false
    @ObservationIgnored private var refreshesStarted = 0
    @ObservationIgnored private var refreshesApplied = 0
    @ObservationIgnored private var importedSoFar = 0
    @ObservationIgnored private let importedFanOut = LatestValueFanOut<Int>()
    /// The files of the job shown whose import is in the bench log already.
    @ObservationIgnored private var loggedImports: Set<ObjectIdentity> = []
    @ObservationIgnored private var loggedEnd = false
    @ObservationIgnored private let keyTags: CameraKeyTags

    public init(
        engine: ImportEngine,
        settings: any DestinationSettingStore,
        photos: any PhotosAuthorising,
        destinations: any ImportDestinationMaking,
        leases: LinkLeases = LinkLeases(),
        log: any BenchLog = SilentBenchLog(),
        keyTags: CameraKeyTags = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keyTags = keyTags
        self.engine = engine
        self.settings = settings
        self.photos = photos
        self.destinations = destinations
        self.leases = leases
        self.log = log
        self.now = now
        // The engine's progress has one consumer, read for the model's lifetime; each update is a cue to read the
        // engine's snapshot (progress and files together).
        let stream = engine.progress
        watchTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    deinit {
        importedFanOut.finish()
    }

    /// The new `importedRevision` each time more files have been imported, for as long as the caller reads: one
    /// stream per caller, which gets only what happens after it subscribed and, if it falls behind, only the latest
    /// revision. Browse refreshes its badges on each (`BrowseModel.run()`).
    public func importedUpdates() -> AsyncStream<Int> { importedFanOut.subscribe() }

    // MARK: - What the screen shows

    public var progress: ImportProgress { snapshot.progress }
    public var state: ImportJobState { snapshot.progress.state }
    /// The state as the screen's VoiceOver announcements see it (`ImportWording.stateAnnouncement`).
    public var announcedState: ImportWording.AnnouncedState { ImportWording.AnnouncedState(progress) }
    /// A job is shown (running, paused or finished and not yet dismissed).
    public var hasJob: Bool { camera != nil }
    public var isActive: Bool { state.isActive }
    public var isFinished: Bool {
        if case .finished = state { camera != nil } else { false }
    }

    /// Keep the screen on (decision 1): while a USB import runs, or is paused for a removal or a stall it gets over
    /// by itself; not while the person or the app's leaving paused it.
    public var keepsScreenOn: Bool { state.isActive && progress.isUSBImportRunning }

    public var isWaitingForCamera: Bool { state == .paused(.cameraRemoved) }

    public var canPause: Bool { state == .running }
    /// Paused for something Continue can lift (not a removed camera: that needs the camera back).
    public var canResume: Bool {
        if case let .paused(reason) = state { reason != .cameraRemoved } else { false }
    }
    public var canCancel: Bool { state.isActive }

    /// The one button that pauses and continues. One button whose title and symbol change, rather than two that swap,
    /// so VoiceOver's focus stays on it when it is pressed (HIG Accessibility > VoiceOver).
    public enum PauseControl: Sendable, Hashable {
        case pause
        case resume

        public var title: String {
            switch self {
            case .pause: ImportWording.pause
            case .resume: ImportWording.resume
            }
        }

        public var systemImage: String {
            switch self {
            case .pause: "pause.fill"
            case .resume: "play.fill"
            }
        }
    }

    /// What the pause button does now; nil hides it (no job, finished, or waiting for a removed camera).
    public var pauseControl: PauseControl? {
        if canPause { .pause } else if canResume { .resume } else { nil }
    }

    /// The pause button: pauses a running job, or continues a paused one.
    public func togglePause() async {
        switch pauseControl {
        case .pause?: await pause()
        case .resume?: await resume()
        case nil: break
        }
    }

    public var statusLine: String? {
        guard camera != nil else { return nil }
        if isAskingForPhotosAccess { return ImportWording.askingForPhotos }
        return ImportWording.status(progress, mode: usbMode)
    }

    /// The counts once there are some: "38 files imported, 2 skipped, 1 failed."
    public var countsLine: String? {
        guard camera != nil, progress.filesDone > 0 || isFinished else { return nil }
        return ImportWording.counts(progress)
    }

    public var destinationLine: String? {
        guard camera != nil else { return nil }
        return ImportWording.destination(progress.destination, folder: filesFolderName, finished: isFinished,
                                         imported: ImportWording.importedCount(progress))
    }

    /// The USB mode the job's camera was discovered in: a removed camera has to come back in it.
    private var usbMode: USBMode? {
        if case let .usb(mode)? = camera?.descriptor.mode { mode } else { nil }
    }

    /// Why Files, when it is Files.
    public var filesReasonLine: String? {
        guard camera != nil, let reason = progress.destination?.filesReason else { return nil }
        return ImportWording.filesReason(reason)
    }

    /// The button to the app's page in Settings: only when Photos access is off (restricted can't be changed there,
    /// and a chosen Files needs nothing).
    public var offersPhotosSettingsLink: Bool {
        camera != nil && progress.destination?.filesReason?.offersSettingsLink == true
    }

    public var bytesLine: String? {
        guard camera != nil, progress.bytesTotal > 0 else { return nil }
        return ByteWording.progress(progress.bytesDone, of: progress.bytesTotal)
    }

    /// The measured rate, while running.
    public var rateLine: String? {
        guard state == .running, let rate = progress.megabytesPerSecond else { return nil }
        return ByteWording.rate(megabytesPerSecond: rate)
    }

    /// `rateLine` as VoiceOver says it ("41.8 MB per second").
    public var rateSpokenLine: String? {
        guard state == .running, let rate = progress.megabytesPerSecond else { return nil }
        return ByteWording.rateSpoken(megabytesPerSecond: rate)
    }

    /// The ETA at the measured rate, while running.
    public var timeLeftLine: String? {
        guard state == .running, let eta = progress.estimatedTimeRemaining else { return nil }
        return ByteWording.timeLeft(eta)
    }

    /// `timeLeftLine` as VoiceOver says it, in whole words ("About 3 minutes left").
    public var timeLeftSpokenLine: String? {
        guard state == .running, let eta = progress.estimatedTimeRemaining else { return nil }
        return ByteWording.timeLeftSpoken(eta)
    }

    /// What the app's haptic for the job looks at (`OutcomeFeedback.forImport(from:to:)`): its state and how many
    /// files failed, wherever the person is in the app.
    public var feedbackState: ImportFeedbackState {
        ImportFeedbackState(state: announcedState, failedFiles: camera == nil ? 0 : progress.filesFailed)
    }

    // MARK: - Starting and adding

    /// Starts a job with `items` from `camera`, or adds them to the running job from the same camera. Before a
    /// job starts, Photos access is read and the destination resolved from the setting (decision 9); while access
    /// isn't determined and the setting says Photos, it is asked for here, at the first Import, and the destination
    /// resolved again with the answer. `.askForPhotosAccess` never reaches the engine.
    public func importItems(_ items: [CameraItem], from camera: ImportCamera, link: any CameraLink) async
        -> ImportRequestOutcome {
        message = nil
        guard !items.isEmpty else { return .nothingNew }
        guard !starting else { return .stillStarting }
        if await engine.state.isActive {
            guard self.camera?.key == camera.key else { return remember(.busyWithAnotherCamera) }
            do {
                let added = try await engine.append(items)
                await refresh()
                return added > 0 ? .appended(added) : .nothingNew
            } catch .noJob {
                // It finished meanwhile: start a new one below.
            } catch {
                return remember(.failed(ImportWording.couldNotAdd))
            }
        }

        starting = true
        defer { starting = false }
        let setting = settings.load()
        // The new job replaces whatever finished job was shown; its camera is shown while Photos is asked for.
        self.camera = camera
        snapshot = .none
        rows = []
        filesFolderName = nil
        let decision = await decide(setting)
        let made = destinations.destinations(for: camera, startedAt: now())
        let photos = self.photos
        let route: ImportRoute
        do {
            route = try ImportRoute(decision, photos: made.photos, filesFolder: made.filesFolder,
                                    authorisation: { await photos.authorisation() })
        } catch {
            return remember(.failed(ImportWording.couldNotStart))   // unreachable: `decide` never asks
        }
        jobSetting = setting
        jobDestinations = made
        filesFolderName = made.filesFolderName
        importedSoFar = 0
        loggedImports = []
        loggedEnd = false
        do {
            try await engine.start(.items(items), from: link, camera: camera.key, to: route)
        } catch {
            log.note("import: didn't start: \(error)")
            self.camera = nil
            filesFolderName = nil
            return error == .emptySelection ? .nothingNew : remember(.failed(ImportWording.couldNotStart))
        }
        await hold(link)
        log.note("import: started \(items.count) file(s) to \(decision)")
        await refresh()
        return .started(items.count)
    }

    /// The destination for a new job: the setting and the authorisation, asking for access once if the setting
    /// says Photos and nobody has asked yet (as `PhotosAccessGate.decision(for:)` does).
    private func decide(_ setting: DestinationSetting) async -> DestinationDecision {
        let first = DestinationDecision.resolve(setting: setting, authorisation: await photos.authorisation())
        guard first == .askForPhotosAccess else { return first }
        isAskingForPhotosAccess = true
        defer { isAskingForPhotosAccess = false }
        let answered = await photos.requestReadWriteAuthorisation()
        let second = DestinationDecision.resolve(setting: setting, authorisation: answered)
        // Still not determined (the prompt couldn't be shown): Files for this import, rather than loop.
        return second == .askForPhotosAccess ? .files(.photosDenied) : second
    }

    /// A route for the files not yet committed, after reading Photos access again (backlog section 5: before a paused
    /// or interrupted import continues); nil when nothing changes. A continue can move a Photos job to Files when
    /// access was turned off or restricted meanwhile, but never moves a Files job to Photos: granting access mid-job
    /// applies from the next import, which follows the setting (decision 9; the Photos-denied line says "next time").
    private func continuingRoute() async -> ImportRoute? {
        guard let made = jobDestinations, progress.destination?.kind != .filesFolder else { return nil }
        let decision = DestinationDecision.resolve(setting: jobSetting, authorisation: await photos.authorisation())
        guard decision.kind == .filesFolder, decision != progress.destination else { return nil }
        let photos = self.photos
        return try? ImportRoute(decision, photos: made.photos, filesFolder: made.filesFolder,
                                authorisation: { await photos.authorisation() })
    }

    private func remember(_ outcome: ImportRequestOutcome) -> ImportRequestOutcome {
        message = BrowseWording.importRequested(outcome)
        return outcome
    }

    // MARK: - Pause, continue, cancel

    public func pause() async {
        try? await engine.pause(.byPerson)
        await refresh()
    }

    /// Continue: lifts the person's pause, the app's and a stall, after reading Photos access again.
    public func resume() async {
        let route = await continuingRoute()
        try? await engine.resume(nil, to: route)
        await refresh()
        await cameraConnected()
    }

    /// Cancels the job: files already imported stay where they went.
    public func cancel() async {
        await engine.cancel()
        await refresh()
    }

    /// Clears a finished job from the screen.
    public func dismiss() {
        guard !state.isActive else { return }
        camera = nil
        rows = []
        snapshot = .none
        filesFolderName = nil
        message = nil
    }

    // MARK: - Scene phase and the camera coming back

    /// Leaving the foreground pauses a USB job (decision 1: without a continued task the transfer stopped within
    /// about 2 s of leaving, and Iteration 1 runs none over USB); *did suspend* may not reach the engine without one,
    /// so the app pauses it here. The link isn't closed: the same session carries on when the app is back. Coming
    /// back reads Photos access again and lifts that pause only (never the person's), then reconnects if the camera
    /// went away meanwhile.
    public func scenePhaseChanged(_ phase: AppScenePhase) async {
        switch phase {
        case .background:
            guard await engine.state.isActive, camera?.descriptor.carrier == .usb else { return }
            try? await engine.pause(.appInBackground)
            await refresh()
        case .active:
            guard await engine.state.isActive else { return }
            let route = await continuingRoute()
            try? await engine.resume(.appInBackground, to: route)
            await refresh()
            await cameraConnected()
        case .inactive:
            break
        }
    }

    /// A camera was connected (or the app is back): if the job is waiting for its camera after a removal and that
    /// camera is connected again, the job carries on through the new link (`ImportEngine.reconnect`), after reading
    /// Photos access again.
    public func cameraConnected() async {
        guard !reconnecting, await engine.state == .paused(.cameraRemoved), let camera, let finder = cameraFinder
        else { return }
        reconnecting = true
        defer { reconnecting = false }
        guard let newLink = await finder.link(forCameraWith: camera.key) else { return }
        let route = await continuingRoute()
        do {
            try await engine.reconnect(newLink, to: route)
        } catch {
            return
        }
        log.note("import: the camera is back; reconnected")
        await hold(newLink)
        await refresh()
    }

    // MARK: - Reading the engine

    /// Reads the engine's progress and files together. Called on each progress update and after every action; a
    /// read that finishes after a newer one is dropped.
    public func refresh() async {
        refreshesStarted += 1
        let mine = refreshesStarted
        let s = await engine.currentSnapshot
        guard mine > refreshesApplied else { return }
        refreshesApplied = mine
        apply(s)
        if case .finished = s.progress.state, let link {
            self.link = nil
            await leases.release(link)
        }
        if s.progress.state == .paused(.cameraRemoved) {
            await cameraConnected()   // the camera may already be back
        }
    }

    private func apply(_ s: ImportSnapshot) {
        // A dismissed, finished job stays off the screen, and so does the last one while a new one starts.
        guard camera != nil || s.progress.state.isActive else { return }
        guard !starting || s.progress.state.isActive else { return }
        snapshot = s
        let kind = s.progress.destination?.kind
        rows = s.files.map { ImportRow($0, going: kind) }
        let imported = s.files.reduce(0) { n, f in
            if case .imported = f.phase { n + 1 } else { n }
        }
        logImports(s)
        if imported != importedSoFar {
            importedSoFar = imported
            importedRevision += 1
            importedFanOut.send(importedRevision)
        }
    }

    /// The bench log: each file once it is imported, with the identity its row was written under (the key by its
    /// tag only), and the job's end once. What the 17.1 bench run lacked to tell why a badge didn't show.
    private func logImports(_ s: ImportSnapshot) {
        for file in s.files {
            guard case let .imported(location) = file.phase, case let .file(identity) = file.id,
                  loggedImports.insert(identity).inserted else { continue }
            let destination: String
            switch location {
            case .file?: destination = "Files"
            case .photosAsset?: destination = "Photos"
            case nil: destination = s.progress.destination?.kind == .photos ? "Photos" : "Files"
            }
            log.note("import: imported \(identity.filename) \(identity.captureDate) \(identity.size) B folder "
                + "\"\(identity.folder)\" key \(keyTags.tag(for: identity.camera)) → \(destination)")
        }
        guard case let .finished(outcome) = s.progress.state, !loggedEnd, let camera else { return }
        loggedEnd = true
        log.note("import: job ended \(Self.describe(outcome)): \(loggedImports.count) imported, key "
            + keyTags.tag(for: camera.key))
    }

    private static func describe(_ outcome: JobOutcome) -> String {
        switch outcome {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case let .stopped(kind): "stopped (\(kind))"
        case .catalogueUnavailable: "catalogue unavailable"
        }
    }

    /// Holds `newLink` for the job, letting go of the one it used before.
    private func hold(_ newLink: any CameraLink) async {
        if let old = link, ObjectIdentifier(old) == ObjectIdentifier(newLink) { return }
        leases.acquire(newLink)
        let old = link
        link = newLink
        if let old { await leases.release(old) }
    }
}
