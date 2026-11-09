import CameraTransport
import Catalogue
import Foundation

/// What the onboarding hands a paired camera to (`WiFiCameraSource` is the app's).
public protocol PairedCameraRegistering: Sendable {
    /// Remembers a camera paired over Bluetooth and lists it. Registering the same peripheral again returns the camera
    /// already listed.
    func registerPairedCamera(peripheral: PeripheralID) async -> CameraDescriptor
}

/// The Wi-Fi cameras the person set up, as a `CameraDiscovery` (wireless plan W15): the Cameras screen lists them beside
/// the USB cameras (`CompositeDiscovery`), and opening one connects to it, which can take tens of seconds.
///
/// **Which cameras.** The catalogue's rows with `preferredCarrier == .wifi` (a camera that has connected before, under its
/// serial key), and the cameras paired or typed in that have not connected yet (`PendingWiFiCameraStore`). They are
/// listed whether or not they are in reach: reaching one is what opening it does. A listed camera never disappears
/// by itself.
///
/// **Opening a camera** (`cameraLink(for:)`): after the Local Network explanation, if one is due (`beforeFirstConnection`),
/// the camera's `WirelessSession` prepares an open link (Bluetooth, join, session: `WirelessSession.prepareImport()`), or
/// for a typed-address camera `WiFiConnecting.openTyped`. While a link is live it is handed out again as it is, so a
/// second screen never reopens the session under a running import (`WirelessSession` closes the link it holds when
/// asked to prepare again). A link is live until its events say it is gone (`.removed`, `.sessionLost`, or the end of
/// the stream), its session is no longer `.ready`, or it is let go; a link that died is never handed out again, so
/// Continue after a pause opens a fresh one. Callers that ask while a connection is being made wait for that one
/// connection and get its link: a camera is never opened twice at once. Then:
/// - **The key.** The link's serial (`CameraIdentifying`) gives the camera's catalogue key (`CameraKeys`). A camera
///   connecting for the first time is saved to the catalogue under it and leaves the pending list; the key is then
///   `knownKey(for:)`, so the camera's last-known card shows while the next join is under way. A link with no serial
///   leaves the camera pending: nothing is written under a name-hash key.
/// - **Identity.** A camera that has a key and answers with another serial is not the camera that was set up: the link is
///   closed, the session left, and the open fails as `identityChanged`. The raw serial is never kept anywhere (not in
///   the catalogue, not in a log); only its key is compared.
/// - **The catalogue row** is written at each connection with the model name, the initiator GUID, the peripheral, the
///   network's name (for removing the configuration) and the time. The password is never stored.
///
/// **Ending.** When the last holder lets the link go (`LinkLeases`, `AppModel`), `linkClosed(_:)` tells the camera's session
/// the import has finished, which starts the stay in front or leaves in the background (`WirelessSession.importFinished`).
/// Browse holds a lease for as long as it is on screen, so in the background the camera is let go without waiting for
/// it: `scenePhaseChanged(_:activeImport:)` finishes every camera with a live link whose import isn't running, and
/// `linkReleased(_:activeImport:)` does the same when an import's lease goes while Browse still holds the link. In the
/// foreground the stay still starts only when the last holder lets go (open for Shamil: it differs from "one timer from the
/// end of the import" while Browse stays open). Scene changes reach every session. A link the Wi-Fi recovery opened
/// through the session is adopted as the camera's (`adoptRecovered(_:for:)`), and an import paused away for an expiry
/// lets the camera go (`importPausedAway(_:)`).
///
/// **Failures.** The reason a connection failed is kept for the camera (`openFailureText(for:)`, with a next step) and
/// reported (`WiFiConnectionEvent.failed`); the open itself fails with the nearest `CameraLinkFailure` kind. A person who
/// declines the explanation gets `disconnected` with no text and `openWasDeclined(for:)` true, so the caller closes
/// the screen that asked without saying the camera went away.
public actor WiFiCameraSource: CameraDiscovery, PairedCameraRegistering, WiFiConnectionSource {
    public nonisolated let discoveries: AsyncStream<CameraDiscoveryEvent>
    public nonisolated let connectionEvents: AsyncStream<WiFiConnectionEvent>
    private let discoverySink: AsyncStream<CameraDiscoveryEvent>.Continuation
    private let eventSink: AsyncStream<WiFiConnectionEvent>.Continuation

    private let catalogue: any CatalogueStore
    private let pending: any PendingWiFiCameraStore
    private let connecting: any WiFiConnecting
    private let beforeFirstConnection: (@Sendable () async -> Bool)?
    private let now: @Sendable () -> Date
    private let log: any BenchLog

    private var entries: [CameraDescriptor.ID: WiFiCameraEntry] = [:]
    private var loaded = false
    private var sessions: [CameraDescriptor.ID: any WirelessControlling] = [:]
    private var phaseTasks: [CameraDescriptor.ID: Task<Void, Never>] = [:]
    /// The task forwarding a camera's link events (`observe`): one per camera, so a reconnection replaces the last.
    private var linkTasks: [CameraDescriptor.ID: Task<Void, Never>] = [:]
    /// The task that clears a camera's live link when its events say it is gone.
    private var watchTasks: [CameraDescriptor.ID: Task<Void, Never>] = [:]
    /// The link a camera's callers can be handed again: the last one opened, until its events say it is gone.
    private var live: [CameraDescriptor.ID: any CameraLink] = [:]
    /// The last link opened for each camera, kept after it has died, until its import ends (`linkClosed`): a dead link's
    /// last holder letting go is still the end of that camera's import, and the session must be told.
    private var handedOut: [CameraDescriptor.ID: any CameraLink] = [:]
    private var inFlight: [CameraDescriptor.ID: Task<Result<any CameraLink, CameraLinkFailure>, Never>] = [:]
    private var failures: [CameraDescriptor.ID: WirelessFailure] = [:]
    private var declined: Set<CameraDescriptor.ID> = []
    private var inBackground = false
    /// How many callers waited for a connection another caller had begun (for tests).
    private(set) var joinedConnections = 0

    /// - Parameters:
    ///   - catalogue: Where connected cameras are kept (their rows are the `.wifi` ones).
    ///   - pending: Cameras paired or typed in that haven't connected yet.
    ///   - connecting: The sessions and the typed-address open (the app's composition).
    ///   - beforeFirstConnection: Runs before each new connection; false cancels it. The app: `WiFiImportModel
    ///     .beforeFirstConnection()`, which explains the Local Network prompt once.
    public init(catalogue: any CatalogueStore, pending: any PendingWiFiCameraStore = InMemoryPendingWiFiCameraStore(),
                connecting: any WiFiConnecting, beforeFirstConnection: (@Sendable () async -> Bool)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }, log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.pending = pending
        self.connecting = connecting
        self.beforeFirstConnection = beforeFirstConnection
        self.now = now
        self.log = log
        (discoveries, discoverySink) = AsyncStream.makeStream()
        (connectionEvents, eventSink) = AsyncStream.makeStream()
    }

    deinit {
        discoverySink.finish()
        eventSink.finish()
        for task in phaseTasks.values { task.cancel() }
        for task in linkTasks.values { task.cancel() }
        for task in watchTasks.values { task.cancel() }
    }

    // MARK: - CameraDiscovery

    /// Lists the cameras the person set up. Never fails: a catalogue that can't be read lists no connected cameras (the
    /// import and Browse say so when they need it), and the pending ones still list.
    public func start() async throws(CameraLinkFailure) {
        await loadIfNeeded()
    }

    public func cameraLink(for id: CameraDescriptor.ID) async throws(CameraLinkFailure) -> any CameraLink {
        await loadIfNeeded()
        guard let entry = entries[id] else { throw CameraLinkFailure(.disconnected, detail: "wifi: no such camera") }
        if let cached = live[id] {
            if await isReusable(id), let still = live[id], Self.same(still, cached) { return still }
            // Not usable any more (its session moved on, or it was replaced while this waited): connect again.
            if let now = live[id], Self.same(now, cached) { live[id] = nil }
        }
        // No suspension between this check and the task being stored, so two callers never both start a connection.
        if let running = inFlight[id] {
            joinedConnections += 1
            return try await running.value.get()
        }
        let task = Task { await self.connect(entry) }
        inFlight[id] = task
        return try await task.value.get()
    }

    /// The one connection for a camera: the explanation if one is due, the open, the identity check, the saving.
    private func connect(_ entry: WiFiCameraEntry) async -> Result<any CameraLink, CameraLinkFailure> {
        let id = entry.id
        defer { inFlight[id] = nil }
        failures[id] = nil
        declined.remove(id)
        if let gate = beforeFirstConnection, await gate() == false {
            log.note("wifi: the connection wasn't started")
            declined.insert(id)
            return .failure(CameraLinkFailure(.disconnected, detail: "wifi: not started"))
        }
        eventSink.yield(.connecting(id))
        let link: any CameraLink
        do throws(WirelessFailure) {
            link = try await open(entry)
        } catch {
            failures[id] = error
            eventSink.yield(.failed(id, error))
            log.note("wifi: couldn't connect: \(error)")
            return .failure(Self.linkFailure(for: error))
        }
        let serial = await (link as? any CameraIdentifying)?.cameraKeyMaterial()
        if let known = entry.key, let serial, CameraKeys.key(for: entry.descriptor, material: serial) != known {
            // Not the camera that was set up: nothing is imported from it.
            log.note("wifi: another camera answered than the one set up")
            await link.close()
            await sessions[id]?.leave()
            let failure = WirelessFailure.link(CameraLinkFailure(.identityChanged))
            failures[id] = failure
            eventSink.yield(.failed(id, failure))
            return .failure(CameraLinkFailure(.identityChanged, detail: "wifi: the serial differs"))
        }
        live[id] = link
        handedOut[id] = link
        watch(link, for: id)
        let model = await (link as? any CameraIdentifying)?.cameraModelName()
        await saveConnected(entry, serial: serial, model: model)
        return .success(link)
    }

    public func knownKey(for id: CameraDescriptor.ID) async -> CameraKey? {
        entries[id]?.key
    }

    public func openFailureText(for id: CameraDescriptor.ID) async -> String? {
        failures[id].flatMap(WiFiWording.failure)
    }

    /// Whether the person said no to the Local Network explanation, so the last open didn't start: the screen that asked
    /// closes without a notice (they chose not to continue; the camera didn't go away).
    public func openWasDeclined(for id: CameraDescriptor.ID) async -> Bool {
        declined.contains(id)
    }

    // MARK: - Setting cameras up

    public func registerPairedCamera(peripheral: PeripheralID) async -> CameraDescriptor {
        await loadIfNeeded()
        if let known = entries.values.first(where: { $0.peripheral == peripheral && $0.typed == nil }) {
            return known.descriptor
        }
        let camera = PendingWiFiCamera(guid: UUID(), peripheral: peripheral.uuid)
        return add(pending: camera)
    }

    /// Remembers a camera at a typed address and lists it. The same address again returns the camera already listed.
    public func addTypedCamera(_ address: TypedCameraAddress) async -> CameraDescriptor {
        await loadIfNeeded()
        if let known = entries.values.first(where: { $0.typed?.endpoint == address.endpoint }) {
            return known.descriptor
        }
        let camera = PendingWiFiCamera(guid: UUID(), typedAddress: "\(address.host):\(address.port)")
        return add(pending: camera)
    }

    /// The cameras listed now, in the order they appeared.
    public var cameras: [WiFiCameraEntry] { entries.values.sorted { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue } }

    /// Starts forwarding `link`'s events to `connectionEvents`, from now on. The app's `openLink` calls it with a new link
    /// before opening it: the Local Network wait is reported during `open()`, before the link is returned.
    public func observe(_ link: any CameraLink, for id: CameraDescriptor.ID) {
        let events = link.events
        linkTasks[id]?.cancel()
        linkTasks[id] = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.forward(event, from: id)
            }
        }
    }

    // MARK: - Ending and the scene

    /// The last holder let `link` go and it is closed: if it is a camera's live link, that camera's import has finished.
    public func linkClosed(_ link: any CameraLink) async {
        guard let id = handedOutID(of: link) else { return }
        await finish(id)
    }

    /// A holder let `link` go but another still holds it (Browse, on screen). In the foreground nothing changes: the stay
    /// starts when the last one lets go. In the background the camera is let go at once if no import is running over it
    /// (`activeImport`: the key of the import that is active, if any), since the phone must not stay on the camera's
    /// network because a screen is still open: the import's last step in the background is `importFinished()`. Returns
    /// whether the camera's session let it go (the link is then closed, though still held).
    @discardableResult
    public func linkReleased(_ link: any CameraLink, activeImport: CameraKey? = nil) async -> Bool {
        guard inBackground, let id = handedOutID(of: link), !isImporting(id, activeImport) else { return false }
        return await finish(id) != nil
    }

    /// The Wi-Fi recovery (W14) opened the camera again through its session, not through `cameraLink(for:)`: the new link
    /// is the camera's live link from now on, so the old link's last holder letting go isn't taken for the end of the
    /// import (which would close the link the job has just moved to), and the recovered job's end is.
    public func adoptRecovered(_ link: any CameraLink, for id: CameraDescriptor.ID) {
        guard entries[id] != nil else { return }
        live[id] = link
        handedOut[id] = link
        watch(link, for: id)
    }

    /// The import over the camera paused for an expiry with the app away (W13): iOS ended the continued task, so the phone
    /// doesn't stay on the camera's network until the person comes back. The camera is let go as at an import's end (in
    /// the background its session leaves); the job keeps its lease on the closed link, and Continue opens a fresh one.
    /// Returns the link let go, if one was.
    @discardableResult
    public func importPausedAway(_ id: CameraDescriptor.ID) async -> (any CameraLink)? {
        guard inBackground, handedOut[id] != nil else { return nil }
        return await finish(id)
    }

    /// The scene changed: every session is told, as `WirelessSession` expects (in the stay it leaves at once on the way
    /// to the background, and it checks the stay on the way back). On the way to the background every camera with a live
    /// link and no import running over it is let go too (`activeImport`: the key of the import that is active, if any):
    /// Browse may still be open, but nothing is being imported, so the phone leaves the camera's network. Returns the
    /// links let go (closed, though Browse may still hold them).
    @discardableResult
    public func scenePhaseChanged(_ phase: AppScenePhase, activeImport: CameraKey? = nil) async -> [any CameraLink] {
        var letGo: [any CameraLink] = []
        switch phase {
        case .background:
            inBackground = true
            for session in sessions.values { await session.appMovedToBackground() }
            for id in Array(handedOut.keys) where !isImporting(id, activeImport) {
                if let link = await finish(id) { letGo.append(link) }
            }
        case .active:
            inBackground = false
            for session in sessions.values { await session.appBecameActive() }
        case .inactive:
            break
        }
        return letGo
    }

    // MARK: - Private

    private func handedOutID(of link: any CameraLink) -> CameraDescriptor.ID? {
        handedOut.first { Self.same($0.value, link) }?.key
    }

    private static func same(_ a: any CameraLink, _ b: any CameraLink) -> Bool {
        ObjectIdentifier(a) == ObjectIdentifier(b)
    }

    private func isImporting(_ id: CameraDescriptor.ID, _ activeImport: CameraKey?) -> Bool {
        guard let activeImport else { return false }
        return entries[id]?.key == activeImport
    }

    /// The camera's import is over: forget its link and tell the session (a typed-address camera joined nothing, so
    /// there is no stay to start or leave). Returns the link it forgot when the session closed it: none for a typed-address
    /// camera, whose link stays open for whoever still holds it.
    @discardableResult
    private func finish(_ id: CameraDescriptor.ID) async -> (any CameraLink)? {
        live[id] = nil
        let link = handedOut.removeValue(forKey: id)
        guard entries[id]?.typed == nil else { return nil }
        await sessions[id]?.importFinished()
        return link
    }

    /// A cached link is handed out again only while its session is `.ready`; a typed camera has no session, and its
    /// link's events end its caching.
    private func isReusable(_ id: CameraDescriptor.ID) async -> Bool {
        guard let session = sessions[id] else { return true }
        return await session.phase == .ready
    }

    /// Forgets `link` as the camera's live link when its events say it is gone.
    private func watch(_ link: any CameraLink, for id: CameraDescriptor.ID) {
        let events = link.events
        let identity = ObjectIdentifier(link)
        watchTasks[id]?.cancel()
        watchTasks[id] = Task { [weak self] in
            for await event in events where event == .removed || event == .sessionLost { break }
            guard !Task.isCancelled, let self else { return }
            await self.linkEnded(identity, for: id)
        }
    }

    private func linkEnded(_ identity: ObjectIdentifier, for id: CameraDescriptor.ID) {
        guard let current = live[id], ObjectIdentifier(current) == identity else { return }
        live[id] = nil
    }

    /// How many cameras have a link-event forwarder (for tests: one per camera, however many links it has had).
    var observerCount: Int { linkTasks.count }

    /// Whether the camera has a link that would be handed out now (for tests).
    func hasLiveLink(for id: CameraDescriptor.ID) -> Bool { live[id] != nil }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        var found: [WiFiCameraEntry] = []
        do {
            for record in try await catalogue.cameras() where record.preferredCarrier == .wifi {
                found.append(WiFiCameraEntry(record: record))
            }
        } catch {
            log.note("wifi: the catalogue's cameras couldn't be read: \(type(of: error))")
        }
        for camera in pending.load() {
            let entry = WiFiCameraEntry(pending: camera)
            // Connected since (the row is in the catalogue under its guid): the row wins.
            if !found.contains(where: { $0.guid == entry.guid }) { found.append(entry) }
        }
        for entry in found where entries[entry.id] == nil {
            entries[entry.id] = entry
            discoverySink.yield(.appeared(entry.descriptor))
        }
    }

    private func add(pending camera: PendingWiFiCamera) -> CameraDescriptor {
        pending.save(pending.load() + [camera])
        let entry = WiFiCameraEntry(pending: camera)
        entries[entry.id] = entry
        discoverySink.yield(.appeared(entry.descriptor))
        return entry.descriptor
    }

    private func open(_ entry: WiFiCameraEntry) async throws(WirelessFailure) -> any CameraLink {
        if let typed = entry.typed {
            do throws(CameraLinkFailure) {
                return try await connecting.openTyped(typed, for: entry)
            } catch {
                throw .link(error)
            }
        }
        return try await session(for: entry).prepareImport()
    }

    private func session(for entry: WiFiCameraEntry) -> any WirelessControlling {
        if let session = sessions[entry.id] { return session }
        let session = connecting.session(for: entry)
        sessions[entry.id] = session
        let id = entry.id
        let phases = session.phases
        phaseTasks[id] = Task { [weak self] in
            for await phase in phases {
                guard let self else { return }
                await self.forward(phase, from: id)
            }
        }
        return session
    }

    private func forward(_ phase: WirelessPhase, from id: CameraDescriptor.ID) async {
        var remaining: Duration?
        if case .staying = phase { remaining = await sessions[id]?.stayRemaining }
        eventSink.yield(.phase(id, phase, stayRemaining: remaining))
    }

    private func forward(_ event: CameraLinkEvent, from id: CameraDescriptor.ID) {
        eventSink.yield(.link(id, event))
    }

    /// Writes what a connection learnt: the key (a first connection moves the camera from pending to the catalogue), the
    /// model, the GUID, the peripheral and the network's name. A failed write is logged and the connection goes on; the
    /// next connection writes again.
    private func saveConnected(_ entry: WiFiCameraEntry, serial: String?, model: String?) async {
        var entry = entry
        let id = entry.id
        if let serial { entry.key = CameraKeys.key(for: entry.descriptor, material: serial) }
        entries[id] = entry
        guard let key = entry.key else {
            log.note("wifi: the camera reports no serial, so it stays unsaved")
            return
        }
        let session = sessions[id]
        let network = await session?.network
        let peripheral = await session?.peripheral ?? entry.peripheral
        let guid = entry.guid
        let typed = entry.typed.map { "\($0.host):\($0.port)" }
        let date = now()
        do {
            // One row serves both routes of a camera set up twice (paired and typed in; both routes key alike), so each
            // connection writes only its own route's fields: the paired route owns the peripheral and the GUID, the
            // typed route its address. A row with a peripheral lists as paired (`WiFiCameraEntry(record:)`).
            try await catalogue.updateCamera(key) { record in
                record.preferredCarrier = .wifi
                if let model { record.model = model }
                if let typed {
                    record.lastIP = typed
                    if record.bluetoothPeripheralID == nil || record.ptpipGUID == nil { record.ptpipGUID = guid }
                } else {
                    record.ptpipGUID = guid
                    if let peripheral { record.bluetoothPeripheralID = peripheral.uuid }
                }
                if let network { record.wifiSSID = network }
                record.lastSeen = date
            }
        } catch {
            log.note("wifi: the camera couldn't be saved: \(type(of: error))")
            return
        }
        pending.save(pending.load().filter { $0.guid != guid })
    }

    /// The nearest failure kind for a connection that didn't open. The reason itself goes through
    /// `openFailureText(for:)`; the kind only decides what a caller without the text does.
    static func linkFailure(for failure: WirelessFailure) -> CameraLinkFailure {
        let detail = "wifi: \(failure)"
        switch failure {
        case let .link(link): return CameraLinkFailure(link.kind, detail: link.detail ?? detail)
        case .cancelled: return CameraLinkFailure(.disconnected, detail: detail)
        case let .paused(pause):
            switch pause {
            case .bluetoothNotAllowed, .joinDeclined: return CameraLinkFailure(.notAuthorised, detail: detail)
            case .needsJoin, .notPaired, .bluetoothOff: return CameraLinkFailure(.noAnswer, detail: detail)
            }
        case let .join(join):
            return CameraLinkFailure(join == .userDenied ? .notAuthorised : .noAnswer, detail: detail)
        case .cameraNotFound, .bluetooth, .handoff, .noGateway, .cameraWiFiLapsed:
            return CameraLinkFailure(.noAnswer, detail: detail)
        }
    }
}
