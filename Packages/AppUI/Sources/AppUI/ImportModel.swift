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
        case .imported, .staged: tone = .done
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
/// from Browse, as *Import to Photos* or *Stage* (Shamil, 11 Nov: the choice is made at each import, and the last one
/// used is remembered app-wide as the Import button's default, `importChoice`), reading where staging goes before each
/// job and asking for Photos access at the first *Import to Photos* (never for *Stage*), adds files picked while a job
/// runs, pauses, continues and cancels, follows the scene's phase (decision 1: pause when the app leaves the
/// foreground over USB, carry on when it is back), reconnects after a removed cable (decision 7), and says all of it
/// in the person's words.
///
/// How the app uses it:
/// - Browse's Import calls `importItems(_:from:link:as:newOnly:)` (as `BrowseImporting`).
/// - The scene's phase goes to `scenePhaseChanged(_:)`; `keepsScreenOn` drives `UIApplication.isIdleTimerDisabled`.
/// - `cameraFinder` is the Cameras model, and `cameraConnected()` is called when discovery reports a camera.
/// - The screen shows `statusLine`, `destinationLine`, `stagingReasonLine` (with the Settings button when
///   `offersPhotosSettingsLink`), `bytesLine`, `rateLine`, `timeLeftLine`, `rows`, and the buttons as `canPause`,
///   `canResume`, `canCancel` and `isFinished` say.
///
/// While the app is away (W13; backlog Iteration 3, section 9, and section 13):
/// - Each job runs inside a background run (`ImportBackgroundRun`, a `BGContinuedProcessingTask` on iPhone), begun at
///   *Import* and again at *Continue* when none is live, with the job's progress in bytes, and finished when the job
///   ends.
/// - When iOS ends the run early on a link that loses its session when the app is suspended (Wi-Fi), the job's
///   checkpoints are flushed (`ImportEngine.flushCheckpoints()`), it pauses with `.taskExpired`, one pause
///   notification is posted with the app away, the run is finished, and then the link's transfer is stopped
///   (`abortTransfer`). The notification is withdrawn once the job goes again or ends. *Continue* then begins a
///   new run and carries the job on through `ImportEngine.reconnect(_:to:knownItems:route:)`, which continues the file
///   in flight from its checkpoint. Over USB the pause rule is unchanged (decision 1): an early end is only logged.
/// - A USB job that pauses because the app left the foreground posts one pause notification too (Shamil, 9 Nov).
/// - The notification permission is asked once, at the first Import on either link, with the reason line as the status
///   line alongside iOS's prompt (`notificationPermission`; decided by Shamil, 8 and 9 Nov).
@MainActor
@Observable
public final class ImportModel: BrowseImporting {
    /// The job's progress and files, as last read from the engine.
    public private(set) var snapshot: ImportSnapshot = .none
    public private(set) var rows: [ImportRow] = []
    /// The camera of the job shown; nil when there is none (before the first job, or after `dismiss()`).
    public private(set) var camera: ImportCamera?
    /// The camera's folder under Staging, for a job that stages (the staging folder's path › this).
    public private(set) var stagingFolderName: String?
    /// What Browse's Import button does by default: the last choice used, *Import to Photos* or *Stage*, remembered
    /// app-wide in the settings store (Shamil, 11 Nov). An earlier build's Files setting reads as *Stage*.
    public private(set) var importChoice: DestinationKind
    /// Where staging goes, as last read (`refreshStagingPlace()`, and before each job); nil before the first read.
    public private(set) var stagingPlace: StagingPlace?
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
    /// The choice the job started with: a continue re-reads Photos access and where staging goes, not the choice,
    /// and files added to the job must be for the same choice.
    @ObservationIgnored private var jobChoice = DestinationKind.photos
    /// Where the job's staging folder was when it started: a continue moves it from iCloud Drive to this iPhone, never
    /// back.
    @ObservationIgnored private var jobStagingPlace: StagingPlace = .onThisIPhone(.containerUnavailable)
    @ObservationIgnored private var jobDestinations: ImportDestinations?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var reconnecting = false
    @ObservationIgnored private var refreshesStarted = 0
    @ObservationIgnored private var refreshesApplied = 0
    @ObservationIgnored private var importedSoFar = 0
    @ObservationIgnored private let importedFanOut = LatestValueFanOut<Int>()
    /// The files of the job shown whose import is in the bench log already.
    @ObservationIgnored private var loggedImports: Set<ObjectIdentity> = []
    /// Of `loggedImports`, those staged rather than imported.
    @ObservationIgnored private var loggedStaged: Set<ObjectIdentity> = []
    @ObservationIgnored private var loggedEnd = false
    @ObservationIgnored private let keyTags: CameraKeyTags
    /// The notification permission, asked at the first Import (W13); its reason line is the status line meanwhile.
    public let notificationPermission: NotificationPermissionModel
    @ObservationIgnored let background: ImportBackgroundCoordinator
    @ObservationIgnored private let notifier: any LocalNotifier
    @ObservationIgnored private let abortTransfer: @Sendable (any CameraLink) async -> Void
    /// The app is in the background (the last phase handed over was `.background`, not yet followed by `.active`).
    @ObservationIgnored private(set) var isAway = false
    /// A pause notification was posted since the app last left the foreground: one per stay away.
    @ObservationIgnored private var notifiedWhileAway = false
    /// A pause notification is up: withdrawn once the job goes again or ends, when it no longer holds.
    @ObservationIgnored private var pauseNotificationShown: AppNotification?
    /// The person paused the job and hasn't continued it. Kept here because the engine's state shows only the pause
    /// that comes first (`PauseReason.precedence`, where the person's is last): a removal or an expiry on top of it
    /// hides it.
    @ObservationIgnored private(set) var pausedByPerson = false
    /// Gets a Wi-Fi job back after the camera drops its card or the session (W14; ImportModel+WiFiRecovery.swift).
    @ObservationIgnored var wifiRecovery: WiFiRecoveryCoordinator?
    /// Told when a job has started (the engine took it) and when it has ended, with its camera (W16: the app gives the Wi-Fi
    /// recovery the job's session and holds the camera's reminders back while it imports). A continued or reconnected job
    /// is the same job.
    @ObservationIgnored public var onJobStarted: (@MainActor (ImportCamera) -> Void)?
    @ObservationIgnored public var onJobEnded: (@MainActor (ImportCamera) -> Void)?
    /// Told when a Wi-Fi job has paused for an expiry with the app away, before the transfer's abort (W16: the app lets the
    /// camera go, so the phone doesn't stay on its network until the person is back; Continue connects again).
    @ObservationIgnored public var onPausedAwayForExpiry: (@MainActor (ImportCamera) async -> Void)?
    /// The job last announced through `onJobStarted` and not yet through `onJobEnded`.
    @ObservationIgnored private(set) var announcedJob: ImportCamera?
    /// A finished job's link is being let go (`refresh()`): its background run is finished once that is done.
    @ObservationIgnored private var releasingFinishedLink = false
    /// Where the Wi-Fi recovery is, followed from the coordinator so the screen redraws when it changes (W16: the Import
    /// screen's Try Again, `wifiRecoveryControl`).
    public internal(set) var wifiRecoveryPhase: WiFiRecoveryPlan.Phase = .idle

    public init(
        engine: ImportEngine,
        settings: any DestinationSettingStore,
        photos: any PhotosAuthorising,
        destinations: any ImportDestinationMaking,
        leases: LinkLeases = LinkLeases(),
        log: any BenchLog = SilentBenchLog(),
        keyTags: CameraKeyTags = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        background: any ImportBackgroundRun = NoImportBackgroundRun(),
        notifier: any LocalNotifier = SilentNotifier(),
        notificationAsks: any NotificationAskRecord = InMemoryNotificationAskRecord(),
        abortTransfer: @escaping @Sendable (any CameraLink) async -> Void = { _ in }
    ) {
        self.keyTags = keyTags
        self.notifier = notifier
        self.abortTransfer = abortTransfer
        notificationPermission = NotificationPermissionModel(notifier: notifier, record: notificationAsks)
        self.background = ImportBackgroundCoordinator(run: background, log: log)
        self.engine = engine
        self.settings = settings
        importChoice = settings.load().preferred
        self.photos = photos
        self.destinations = destinations
        self.leases = leases
        self.log = log
        self.now = now
        self.background.onExpired = { [weak self] in await self?.backgroundRunEnded() }
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
    /// Paused for something Continue can lift (not a removed or unreachable camera, a lost card or a needed join:
    /// those need the camera back, `ImportEngine.reconnect`).
    public var canResume: Bool {
        guard case let .paused(reason) = state else { return false }
        switch reason {
        case .appInBackground, .stalled, .byPerson, .taskExpired: return true
        case .cameraRemoved, .cameraUnreachable, .cardUnavailable, .needsJoin: return false
        }
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
        if let reason = notificationPermission.reasonLine { return reason }
        // In front, a Wi-Fi job the recovery waits on the person for ends with Try Again, the button the screen shows
        // then; while the recovery reaches the camera by itself a job paused for a join says so, not "open Shutter
        // Bridge" (W16). The card's and the camera's own lines are right while it reaches the camera, so they stay.
        if !isAway, let control = wifiRecoveryControl, case let .paused(reason) = state {
            switch control {
            case .tryAgain: return ImportWording.pausedTryAgain(reason)
            case .reconnecting where reason == .needsJoin: return ImportWording.reconnecting
            case .reconnecting: break
            }
        }
        return ImportWording.status(progress, mode: usbMode)
    }

    /// The counts once there are some: "38 files imported, 2 skipped, 1 failed."
    public var countsLine: String? {
        guard camera != nil, progress.filesDone > 0 || isFinished else { return nil }
        return ImportWording.counts(progress)
    }

    /// How many files were left out for having no capture date, and why (D10); nil when none was.
    public var undatedLine: String? {
        guard camera != nil else { return nil }
        return ImportWording.undatedLeftOut(progress.filesUndated)
    }

    public var destinationLine: String? {
        guard camera != nil else { return nil }
        return ImportWording.destination(progress.destination, folder: stagingFolderName, finished: isFinished,
                                         imported: ImportWording.importedCount(progress))
    }

    /// The USB mode the job's camera was discovered in: a removed camera has to come back in it.
    private var usbMode: USBMode? {
        if case let .usb(mode)? = camera?.descriptor.mode { mode } else { nil }
    }

    /// Why the files are staged, and why on this iPhone when they are, when the job stages.
    public var stagingReasonLine: String? {
        guard camera != nil, case let .staging(reason, place)? = progress.destination else { return nil }
        return ImportWording.stagingReason(reason, place: place)
    }

    /// The button to the app's page in Settings: only when Photos access is off (restricted can't be changed there,
    /// and a chosen *Stage* needs nothing).
    public var offersPhotosSettingsLink: Bool {
        camera != nil && progress.destination?.stagingReason?.offersSettingsLink == true
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

    /// Starts a job with `items` from `camera`, or adds them to the running job from the same camera and for the same
    /// choice. Before a job starts, where staging goes is read (`ImportDestinationMaking.locate()`), then the destination
    /// is resolved from the choice and Photos access (decision 9; Shamil, 11 Nov): *Stage* never reads or asks for
    /// Photos access; *Import to Photos* asks for it here, at the first Import, while it isn't determined, and is
    /// resolved again with the answer. `.askForPhotosAccess` never reaches the engine. A request the engine takes
    /// (started, added, or nothing new) makes `choice` the remembered one.
    ///
    /// What counts as done follows what the job does, not the choice (`ImportEngine.picksToDo(_:camera:for:)`): an
    /// *Import to Photos* staged because Photos access is off leaves out staged files as a *Stage* does. `.started`
    /// counts the files the job holds, and when none is left no job starts and `.nothingNew` says why.
    public func importItems(_ items: [CameraItem], from camera: ImportCamera, link: any CameraLink,
                            as choice: DestinationKind, newOnly: Bool) async -> ImportRequestOutcome {
        message = nil
        guard !items.isEmpty else { return .nothingNew(staging: choice == .staging) }
        guard !starting else { return .stillStarting }
        if await engine.state.isActive {
            guard self.camera?.key == camera.key else { return remember(.busyWithAnotherCamera) }
            // One job at a time, of one kind: an import job forced to staging by Photos access still takes more
            // *Import to Photos* picks (they are staged with it), but never *Stage* picks, and the other way round.
            guard choice == jobChoice else { return remember(.busyWithAnotherMode(jobChoice)) }
            do {
                let added = try await engine.append(items, newOnly: newOnly)
                let stages = await engine.currentPurpose == .staging
                await refresh()
                rememberChoice(choice)
                return added > 0 ? .appended(added) : .nothingNew(staging: stages)
            } catch .noJob {
                // It finished meanwhile: start a new one below.
            } catch {
                return remember(.failed(ImportWording.couldNotAdd))
            }
        }

        starting = true
        defer { starting = false }
        // The new job replaces whatever finished job was shown; its camera is shown while Photos is asked for.
        let shown = (camera: self.camera, snapshot: snapshot, rows: rows, folder: stagingFolderName)
        self.camera = camera
        snapshot = .none
        rows = []
        stagingFolderName = nil
        let availability = await destinations.locate()
        stagingPlace = availability.place
        let decision = await decide(choice, staging: availability.place)
        let made = destinations.destinations(for: camera, startedAt: now(), staging: availability)
        let route: ImportRoute
        do {
            route = try self.route(decision, in: made)
        } catch {
            return remember(.failed(ImportWording.couldNotStart))   // unreachable: `decide` never asks
        }
        // What the job will hold, by the route's purpose rather than the choice: with Photos access off, an *Import to
        // Photos* stages, and so leaves out staged files too. The notice counts these, and none starts no job. If the
        // catalogue can't say, every pick goes in and the job ends saying so.
        let selection: ImportSelection = newOnly ? .newItems(items) : .items(items)
        let stages = route.purpose == .staging
        let toDo = (try? await engine.picksToDo(selection, camera: camera.key, for: route)) ?? items
        // Files without a capture date come with *Select All New* only for the job to leave out and count (D10): on
        // their own they start no job, and they aren't counted as started or, in the bench line, as picked.
        let toCopy = toDo.filter { $0.identity(camera: camera.key, timeZone: .current) != nil }.count
        let picked = items.filter { $0.identity(camera: camera.key, timeZone: .current) != nil }.count
        guard toCopy > 0 else {
            // No job starts, so the one shown before (if any) stays shown.
            log.note("import: nothing new to \(decision)")
            self.camera = shown.camera
            snapshot = shown.snapshot
            rows = shown.rows
            stagingFolderName = shown.folder
            rememberChoice(choice)
            return .nothingNew(staging: stages)
        }
        jobChoice = choice
        jobStagingPlace = made.stagingPlace
        jobDestinations = made
        stagingFolderName = made.stagingFolderName
        importedSoFar = 0
        loggedImports = []
        loggedStaged = []
        loggedEnd = false
        pausedByPerson = false
        do {
            try await engine.start(newOnly ? .newItems(toDo) : .items(toDo), from: link, camera: camera.key,
                                   to: route)
        } catch {
            // An empty selection is the person's "nothing new", not a failure; any other refusal is one, so an error.
            log.note("import: didn't start: \(error)", level: error == .emptySelection ? .notice : .error)
            self.camera = nil
            stagingFolderName = nil
            if error == .emptySelection {
                rememberChoice(choice)
                return .nothingNew(staging: stages)
            }
            return remember(.failed(ImportWording.couldNotStart))
        }
        rememberChoice(choice)
        await hold(link)
        announceStart(camera)
        log.note("import: started \(toCopy) of \(picked) file(s) to \(decision)")
        // The run starts from the person's tap (iOS's rule), without holding the import up.
        background.begin(progress, staging: isStageJob)
        await refresh()
        // Once, at the first Import on either link: the reason line, then iOS's prompt. After the job has started, so
        // it never waits on the answer and the Photos prompt (above) never meets this one.
        if await notificationPermission.askAtImport() {
            // The job may have moved on, or ended, while the prompt was up.
            starting = false
            await refresh()
        } else if await !engine.state.isActive {
            // It ended while it was starting, when a finished state still read as the last job's: read its end.
            starting = false
            await refresh()
        }
        return .started(toCopy)
    }

    /// Browse's Import button's primary action: the remembered choice, for an explicit pick.
    public func importItems(_ items: [CameraItem], from camera: ImportCamera, link: any CameraLink) async
        -> ImportRequestOutcome {
        await importItems(items, from: camera, link: link, as: importChoice, newOnly: false)
    }

    /// Reads where staging goes again (Browse, for the Import menu's wording).
    public func refreshStagingPlace() async {
        let place = await destinations.locate().place
        if place != stagingPlace { stagingPlace = place }
    }

    /// The job shown was started as *Stage* (not an import staged because of Photos access).
    var isStageJob: Bool { camera != nil && jobChoice == .staging }

    /// Makes `choice` the Import button's default, saved app-wide.
    private func rememberChoice(_ choice: DestinationKind) {
        guard choice != importChoice else { return }
        importChoice = choice
        settings.save(DestinationSetting(preferred: choice))
    }

    /// The destination for a new job from the choice and the authorisation: *Stage* stages, without reading or
    /// asking for Photos access; *Import to Photos* asks for access once if nobody has asked yet (as
    /// `PhotosAccessGate.decision(for:staging:)` does).
    private func decide(_ choice: DestinationKind, staging: StagingPlace) async -> DestinationDecision {
        guard choice == .photos else { return .staging(.chosen, staging) }
        let first = DestinationDecision.resolve(choice: .photos, authorisation: await photos.authorisation(),
                                                staging: staging)
        guard first == .askForPhotosAccess else { return first }
        isAskingForPhotosAccess = true
        defer { isAskingForPhotosAccess = false }
        let answered = await photos.requestReadWriteAuthorisation()
        let second = DestinationDecision.resolve(choice: .photos, authorisation: answered, staging: staging)
        // Still not determined (the prompt couldn't be shown): staged for this import, rather than loop.
        return second == .askForPhotosAccess ? .staging(.photosDenied, staging) : second
    }

    /// The route for `decision` with the job's destinations: staging in the decision's place (or the job's), Photos
    /// with the staging folder ready in case Photos refuses a save.
    private func route(_ decision: DestinationDecision, in made: ImportDestinations,
                       stagingPlace: StagingPlace? = nil) throws(ImportEngineError) -> ImportRoute {
        let place = decision.stagingPlace ?? stagingPlace ?? made.stagingPlace
        let photos = self.photos
        return try ImportRoute(decision, photos: made.photos, staging: made.staging(in: place),
                               onThisIPhone: made.stagingOnThisIPhone, stagingPlace: place,
                               authorisation: { await photos.authorisation() })
    }

    /// A route for the files not yet committed, after reading Photos access and where staging goes again (backlog
    /// section 5: before a paused or interrupted import continues); nil when nothing changes.
    /// - An import job moves to staging when Photos access was turned off or restricted meanwhile, but a staged job
    ///   never moves to Photos: granting access mid-job applies from the next import (decision 9; the Photos-denied
    ///   line says "next time"), and a *Stage* job is never imported.
    /// - Staging moves from iCloud Drive to this iPhone when iCloud Drive went away meanwhile
    ///   (`StagingFallbackReason.lostDuringImport`), never back, so one job's staged files never come back from this
    ///   iPhone to iCloud Drive half-way.
    func continuingRoute() async -> ImportRoute? {
        guard let made = jobDestinations, let current = progress.destination else { return nil }
        let wasPlace = current.stagingPlace ?? jobStagingPlace
        var place = wasPlace
        if wasPlace == .iCloudDrive, await destinations.locate().place != .iCloudDrive {
            place = .onThisIPhone(.lostDuringImport)
        }
        let decision: DestinationDecision
        if current.kind == .staging {
            decision = current.staged(in: place)
        } else {
            decision = DestinationDecision.resolve(choice: .photos, authorisation: await photos.authorisation(),
                                                   staging: place)
            // Access may have been granted or limited meanwhile: still Photos. Not determined can't come back once
            // asked; if it does, the job carries on as it is.
            guard decision != .askForPhotosAccess else { return nil }
        }
        guard decision != current || place != wasPlace else { return nil }
        if place != wasPlace { jobStagingPlace = place }
        return try? route(decision, in: made, stagingPlace: place)
    }

    private func remember(_ outcome: ImportRequestOutcome) -> ImportRequestOutcome {
        message = BrowseWording.importRequested(outcome)
        return outcome
    }

    // MARK: - Pause, continue, cancel

    public func pause() async {
        do {
            try await engine.pause(.byPerson)
            pausedByPerson = true
        } catch {}
        await refresh()
    }

    /// Continue: lifts the person's pause, the app's and a stall, after reading Photos access again. A person's tap,
    /// so a new background run begins if none is live. After iOS ended the run (`.taskExpired`) the job carries on
    /// through `ImportEngine.reconnect(_:to:knownItems:route:)` (backlog Iteration 3, section 9, *Continue*): the
    /// session is opened again, the card listed, and the file in flight continued from its checkpoint, so each file is
    /// written once. The link is the camera finder's for the job's camera, or the job's own; W16 puts the Wi-Fi
    /// reopen (`WirelessSession.prepareImport()`) and its listing of known handles in front of it.
    public func resume() async {
        if camera != nil, await engine.state.isActive { background.begin(progress, staging: isStageJob) }
        let route = await continuingRoute()
        if await engine.state == .paused(.taskExpired), await continueAfterExpiry(route: route) {
            await refresh()
            return
        }
        do {
            try await engine.resume(nil, to: route)
            pausedByPerson = false
        } catch {}
        await refresh()
        await cameraConnected()
    }

    /// The reconnect after an expiry; false when there is no link to carry on through or the engine refused.
    private func continueAfterExpiry(route: ImportRoute?) async -> Bool {
        guard let camera, let job = await engine.currentJobID else { return false }
        var target = link
        if let finder = cameraFinder, let found = await finder.link(forCameraWith: camera.key) { target = found }
        guard let target else { return false }
        // Over Wi-Fi the card is listed asking the camera only about handles it hasn't seen (W8, `ReusingListing`), given
        // the job's files; empty, or a listing that fails, lets the engine list the card itself.
        var known: [CameraItem] = []
        if camera.descriptor.carrier == .wifi,
           let listed = try? await WiFiRecoveryCoordinator.listNewHandles(target, known: recoveryKnownItems) {
            known = listed
        }
        do {
            try await engine.reconnect(job, to: target, knownItems: known, route: route)
        } catch {
            log.note("import: didn't carry on after the continued task ended: \(error)")
            return false
        }
        // Continue lifts the person's pause, the app's and a stall too, which a reconnect leaves.
        try? await engine.resume(nil)
        pausedByPerson = false
        log.note("import: carrying on after the continued task ended")
        await hold(target)
        return true
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
        stagingFolderName = nil
        message = nil
    }

    // MARK: - Scene phase and the camera coming back

    /// Leaving the foreground pauses a USB job (decision 1: without a continued task the transfer stopped within
    /// about 2 s of leaving, and Iteration 1 runs none over USB); *did suspend* may not reach the engine without one,
    /// so the app pauses it here. The link isn't closed: the same session carries on when the app is back. Coming
    /// back reads Photos access again and lifts that pause only (never the person's), then reconnects if the camera
    /// went away meanwhile.
    ///
    /// A USB job paused this way posts one pause notification (Shamil, 9 Nov), unless the person had paused it.
    public func scenePhaseChanged(_ phase: AppScenePhase) async {
        switch phase {
        case .background:
            isAway = true
            guard await engine.state.isActive, pausesWhenTheAppLeaves else { return }
            try? await engine.pause(.appInBackground)
            await refresh()
            if !pausedByPerson { await notifyPausedWhileAway() }
        case .active:
            isAway = false
            notifiedWhileAway = false
            wifiRecovery?.appBecameActive()
            guard await engine.state.isActive else { return }
            let route = await continuingRoute()
            try? await engine.resume(.appInBackground, to: route)
            await refresh()
            await cameraConnected()
        case .inactive:
            break
        }
    }

    /// Whether the job's link keeps its session through the app's suspension, so the job pauses when the app leaves
    /// and an early end of the background run doesn't pause it: USB (ImageCaptureCore's session survived a 652 s lock;
    /// *did suspend* stops it 30 s after leaving, even inside a continued task). Wi-Fi loses its session within about
    /// 5 s without a continued task and keeps going with one. By carrier, as the scene-phase rule always was; no
    /// capability says it.
    private var pausesWhenTheAppLeaves: Bool { camera?.descriptor.carrier == .usb }

    /// iOS ended the background run early (an expiry, or Stop in the system's UI; backlog Iteration 3, section 9,
    /// *Expiry is normal*). On Wi-Fi: flush the checkpoints, pause with `.taskExpired`, and post one pause
    /// notification while the app is away (not when the person had paused the job); then, once the coordinator has
    /// finished the run, let the camera go if the app is away (`onPausedAwayForExpiry`) and stop the link's transfer (the
    /// returned step). Both may wait on a camera whose Wi-Fi has faded, as it usually has at an expiry, so they never hold
    /// the run past its end or the notification back. Over USB nothing changes: the job pauses at the app's leaving, as
    /// before (decision 1).
    private func backgroundRunEnded() async -> (@MainActor () async -> Void)? {
        guard await engine.state.isActive else { return nil }
        guard !pausesWhenTheAppLeaves else {
            log.note("import: the continued task ended; a USB job keeps to the leaving rule")
            return nil
        }
        await engine.flushCheckpoints()
        try? await engine.pause(.taskExpired)
        log.note("import: paused, the continued task ended")
        await refresh()
        if !pausedByPerson { await notifyPausedWhileAway() }
        guard let link else { return nil }
        let abort = abortTransfer
        // Away, the camera is let go first (W16): its session closes the link, which stops the transfer as the abort would,
        // and leaves the camera's network, so the phone isn't left on it until the person is back.
        let letGo = onPausedAwayForExpiry
        let away = isAway ? camera : nil
        return {
            if let away { await letGo?(away) }
            await abort(link)
        }
    }

    /// The pause notification for the job shown: "Staging paused." for a *Stage* job, "Import paused." otherwise.
    /// Both have the same identifier, so either replaces the other.
    private var pauseNotification: AppNotification { isStageJob ? .stagingPaused : .importPaused }

    /// Posts the pause notification, once per stay away, and only when iOS allows it (a notification posted while
    /// permission is undetermined fails: UNErrorDomain 2003). W14's `.needsJoin` pause posts through it too.
    func notifyPausedWhileAway() async {
        guard isAway, !notifiedWhileAway else { return }
        notifiedWhileAway = true
        guard await notificationPermission.allowsPosting() else {
            log.note("import: paused while away; notifications aren't allowed")
            return
        }
        let notification = pauseNotification
        await notifier.post(notification)
        pauseNotificationShown = notification
        log.note("import: posted the pause notification")
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
        // A job that has ended lets its link go before its background run is finished: a Wi-Fi camera's session leaves
        // the network as the run's last step (`WirelessSession.importFinished()`), and iOS may suspend the app as soon as
        // the run is finished.
        if case .finished = s.progress.state, let link {
            self.link = nil
            releasingFinishedLink = true
            await leases.release(link)
            releasingFinishedLink = false
        }
        // As `apply`: while a job starts, a finished snapshot is the last job's, not this one's.
        if !starting || s.progress.state.isActive {
            if case let .finished(outcome) = s.progress.state {
                // A read that comes in while the link is let go leaves the finishing to the read letting it go.
                if !releasingFinishedLink { background.finish(success: outcome == .completed) }
            } else if s.progress.state.isActive {
                background.update(s.progress)
            }
        }
        if let shown = pauseNotificationShown, s.progress.state == .running || !s.progress.state.isActive {
            // The import is going again (the app is back, Continue, a reconnect) or has ended: "Import paused" no
            // longer holds.
            pauseNotificationShown = nil
            await notifier.withdraw(shown)
            log.note("import: withdrew the pause notification")
        }
        if s.progress.state == .paused(.cameraRemoved) {
            await cameraConnected()   // the camera may already be back
        }
        announceJob(s.progress.state)
        wifiRecovery?.jobChanged(s.progress.state)
    }

    /// A job has started (`onJobStarted`): a job announced before whose end was never read ends first.
    private func announceStart(_ camera: ImportCamera) {
        if let announced = announcedJob {
            announcedJob = nil
            onJobEnded?(announced)
        }
        announcedJob = camera
        onJobStarted?(camera)
    }

    /// The announced job has ended (`onJobEnded`). While a job starts, a finished state is the last job's, so it ends
    /// nothing; `importItems` reads the engine again once it has started, for a job that ended meanwhile.
    private func announceJob(_ state: ImportJobState) {
        guard case .finished = state, !starting, let announced = announcedJob else { return }
        announcedJob = nil
        onJobEnded?(announced)
    }

    private func apply(_ s: ImportSnapshot) {
        // A dismissed, finished job stays off the screen, and so does the last one while a new one starts.
        guard camera != nil || s.progress.state.isActive else { return }
        guard !starting || s.progress.state.isActive else { return }
        snapshot = s
        let kind = s.progress.destination?.kind
        rows = s.files.map { ImportRow($0, going: kind) }
        // Staged files count too, so Browse reads the catalogue again when a stage job commits one.
        let imported = s.files.reduce(0) { n, f in
            switch f.phase {
            case .imported, .staged: n + 1
            default: n
            }
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
            guard case let .file(identity) = file.id else { continue }
            let verb: String
            let destination: String
            switch file.phase {
            case let .imported(location):
                verb = "imported"
                switch location {
                case .file?: destination = "Files"
                case .photosAsset?: destination = "Photos"
                case nil: destination = s.progress.destination?.kind == .photos ? "Photos" : "Staging"
                }
            case .staged:
                // Staged, not imported (Shamil, 11 Nov).
                verb = "staged"
                destination = "Staging"
            default:
                continue
            }
            guard loggedImports.insert(identity).inserted else { continue }
            if verb == "staged" { loggedStaged.insert(identity) }
            log.note("import: \(verb) \(identity.filename) \(identity.captureDate) \(identity.size) B folder "
                + "\"\(identity.folder)\" key \(keyTags.tag(for: identity.camera)) → \(destination)")
        }
        guard case let .finished(outcome) = s.progress.state, !loggedEnd, let camera else { return }
        loggedEnd = true
        let staged = loggedStaged.isEmpty ? "" : ", \(loggedStaged.count) staged"
        log.note("import: job ended \(Self.describe(outcome)): \(loggedImports.count - loggedStaged.count) imported"
            + "\(staged), key " + keyTags.tag(for: camera.key))
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
    func hold(_ newLink: any CameraLink) async {
        if let old = link, ObjectIdentifier(old) == ObjectIdentifier(newLink) { return }
        leases.acquire(newLink)
        let old = link
        link = newLink
        if let old { await leases.release(old) }
    }
}
