import CameraTransport
import Catalogue
import Foundation
import Observation

/// What the Cameras screen needs from discovery: `USBCameraBrowser` in the app (its conformance sits behind
/// `#if canImport(ImageCaptureCore)`), `WiFiCameraSource` for the cameras set up over Wi-Fi, `CompositeDiscovery` for
/// both together, a fake in tests.
public protocol CameraDiscovery: Actor {
    /// Cameras appearing and going away. One consumer: `CamerasModel`.
    nonisolated var discoveries: AsyncStream<CameraDiscoveryEvent> { get }
    /// Asks for access and starts looking. Throws `notAuthorised` when access is denied or restricted. Starting a
    /// started discovery does nothing.
    func start() async throws(CameraLinkFailure)
    /// The link for an attached camera. Throws `disconnected` if it has gone. Over Wi-Fi it is an open link, reached
    /// by the join when one is needed (`WiFiCameraSource`), so it can take tens of seconds.
    func cameraLink(for id: CameraDescriptor.ID) async throws(CameraLinkFailure) -> any CameraLink
    /// The catalogue's key for the camera, when discovery knows it without a link: a Wi-Fi camera that has connected
    /// before (its serial's key, kept in the catalogue). Nil when the key has to be read from the link (USB, or a Wi-Fi
    /// camera not yet connected). It lets the Cameras model find a camera by key without joining every Wi-Fi camera
    /// to compare, and Browse show the last-known card before the join is over.
    func knownKey(for id: CameraDescriptor.ID) async -> CameraKey?
    /// Why the last `cameraLink(for:)` of this camera failed, in words that say what to do next, when discovery knows
    /// more than the failure's kind says (a Wi-Fi join that was declined, Bluetooth off…). Nil: the kind's own wording.
    func openFailureText(for id: CameraDescriptor.ID) async -> String?
    /// Whether the last `cameraLink(for:)` of this camera didn't start because the person chose not to continue (Not Now
    /// on the Local Network explanation). The screen that asked closes with no notice: the camera didn't go away.
    func openWasDeclined(for id: CameraDescriptor.ID) async -> Bool
    /// Whether asking for the camera's link now starts nothing that can join: it is attached (USB), or (Wi-Fi) its link is
    /// open or a connection is being made (`WiFiCameraSource`). A set-up Wi-Fi camera is listed whether or not it is in
    /// reach, so for one with neither this is false, and `cameraLink(for:)` would (or, in the stay, could) join. "Import new photos" asks it, to open such a camera's offline Browse with Connect
    /// rather than join it (Shamil, 12 Nov).
    func isConnected(_ id: CameraDescriptor.ID) async -> Bool
}

extension CameraDiscovery {
    /// USB reads the key from the link (`CameraKeys`), so it knows none beforehand.
    public func knownKey(for id: CameraDescriptor.ID) async -> CameraKey? { nil }
    public func openFailureText(for id: CameraDescriptor.ID) async -> String? { nil }
    public func openWasDeclined(for id: CameraDescriptor.ID) async -> Bool { false }
    /// A source that lists only attached cameras (USB): opening a listed camera's link joins nothing.
    /// (`CompositeDiscovery` asks the source that listed the camera.)
    public func isConnected(_ id: CameraDescriptor.ID) async -> Bool { true }
}

/// What Browse uses besides the link: the JPEG maker, the clipboard, the temporary folders and the bench log.
@MainActor
public struct BrowseServices {
    public var maker: any JPEGMaking
    public var clipboard: any JPEGClipboard
    public var scratch: JPEGScratch
    public var log: any BenchLog

    public init(maker: any JPEGMaking, clipboard: any JPEGClipboard, scratch: JPEGScratch, log: any BenchLog) {
        self.maker = maker
        self.clipboard = clipboard
        self.scratch = scratch
        self.log = log
    }
}

/// The Cameras screen's model (backlog section 6): the cameras discovery reports, whether access is allowed, the
/// navigation into Browse, and the message when a camera goes away while it is browsed. It also finds a camera by
/// its catalogue key for the import (`CameraFinding`), and tells the import when a camera is connected, so a job
/// paused by a removed cable carries on once the camera is back and listed (decision 7). It also gives the import the
/// other attached USB cameras, so a paused job can continue on the same body in the other Image Transfer mode by
/// content (D11), and names each camera by the one-name-per-body rule (`displayName(for:)`, `CameraNaming`).
@MainActor
@Observable
public final class CamerasModel: CameraFinding {
    public enum Access: Sendable, Hashable {
        /// Not started yet, or started without an answer.
        case unknown
        case allowed
        /// ImageCaptureCore's access is denied or restricted.
        case notAllowed
        /// Discovery couldn't start for another reason: no camera would ever appear, so the screen says so with Try
        /// Again (`becameActive()`) rather than look like "No Camera Connected".
        case failed
    }

    /// The connected cameras, in the order they appeared.
    public private(set) var cameras: [CameraDescriptor] = []
    public private(set) var access: Access = .unknown
    /// True once discovery has started.
    public private(set) var isLooking = false
    /// The navigation stack: the camera being browsed, if any.
    public var path: [CameraDescriptor] = [] {
        didSet { if path != oldValue { onPathChanged?(path) } }
    }
    /// A message for the top of the screen, such as a camera disconnected while it was browsed. It goes when that
    /// camera is connected again, or when the person closes it.
    public var notice: String?
    /// `notice` as the strip shows it, numbered so a second disconnect with the same text is announced again.
    public var noticeStatus: StatusNotice? { notice.map { StatusNotice.cameras($0, id: noticeCount) } }
    /// The catalogue key of each listed camera whose key discovery knows without a link (a Wi-Fi camera that has
    /// connected before), for the *nearby* badge (W16). Read when a camera appears and when the app becomes active, since
    /// a Wi-Fi camera's key becomes known at its first session.
    public private(set) var knownKeys: [CameraDescriptor.ID: CameraKey] = [:]
    /// The free space last read on each listed camera's card, in bytes (I17: USB in Image Transfer (MTP), once Browse
    /// has listed the card; `readCardFreeSpace(of:)`). A camera with no entry shows no free-space line.
    public private(set) var cardFreeBytes: [CameraDescriptor.ID: UInt64] = [:]
    /// The one named body the catalogue knows (`CameraNaming.onlyBodyName(among:)`), which a camera in Image Transfer
    /// (MSC) is named after; nil when there is none or several. Read when the app becomes active, when a camera appears,
    /// when Browse has listed a card and when a job starts (each can name a body).
    public private(set) var onlyBodyName: String?

    /// The import, told when a camera is connected, and handed Browse's selection. Set by the app (`AppModel`).
    @ObservationIgnored public weak var importModel: ImportModel?

    @ObservationIgnored private let discovery: any CameraDiscovery
    @ObservationIgnored private let services: BrowseServices
    @ObservationIgnored private let catalogue: (any CatalogueStore)?
    @ObservationIgnored private let cameraKey: CameraKeying
    @ObservationIgnored private let leases: LinkLeases
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// The Browse models made, held weakly, so the scene reaches the one on screen (`browseScenePhaseChanged(_:)`).
    @ObservationIgnored private var browsing: [WeakBrowse] = []
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var launched = false
    /// The camera `notice` is about, if it is about one.
    @ObservationIgnored private var noticeCamera: CameraDescriptor.ID?
    /// Counts the disconnect notices (`noticeStatus`'s id).
    private var noticeCount = 0
    /// The offline Browses' cameras (W6-absent), by the descriptor pushed for each: one per camera key, kept for the
    /// model's lifetime so the same key always gets the same descriptor.
    @ObservationIgnored private var offlineCameras: [CameraDescriptor.ID: OfflineCamera] = [:]
    /// Told when an offline Browse is replaced by the live Browse on the listed camera (W6-absent), before the path
    /// changes: `AppModel` moves a waiting "Import new photos" over to the live camera, so leaving the offline Browse
    /// for it isn't taken for leaving Browse.
    @ObservationIgnored var onOfflineReplaced: (@MainActor (_ offline: CameraDescriptor.ID,
                                                            _ live: CameraDescriptor) -> Void)?

    /// - Parameters:
    ///   - catalogue: For Browse's last-known card and badge; nil shows neither.
    ///   - cameraKey: The catalogue's key for a camera (`CameraKeys`; the app reads the USB link's key material).
    ///   - leases: Shared by Browse and the import, so leaving Browse doesn't close a link a job uses.
    public init(discovery: any CameraDiscovery, services: BrowseServices, catalogue: (any CatalogueStore)? = nil,
                cameraKey: @escaping CameraKeying = CameraKeys.fromDescriptor, leases: LinkLeases = LinkLeases()) {
        self.discovery = discovery
        self.services = services
        self.catalogue = catalogue
        self.cameraKey = cameraKey
        self.leases = leases
    }

    /// Once per launch: removes temporary JPEG folders a crash left behind (backlog section 6).
    public func launch() {
        guard !launched else { return }
        launched = true
        let removed = services.scratch.removeLeftovers()
        if removed > 0 { services.log.note("copy-as-jpeg removed \(removed) leftover temporary folder(s) at launch") }
    }

    /// The app became active, or Try Again was tapped: watch discoveries (once) and start discovery, again if access
    /// was refused or starting failed before (the person may have changed it in Settings).
    public func becameActive() async {
        watchDiscoveries()
        await refreshKnownKeys()
        await refreshOnlyBodyName()
        guard !isLooking, !starting else {
            await importModel?.cameraConnected()
            return
        }
        starting = true
        defer { starting = false }
        do throws(CameraLinkFailure) {
            try await discovery.start()
            isLooking = true
            access = .allowed
        } catch {
            access = error.kind == .notAuthorised ? .notAllowed : .failed
            services.log.note("cameras: discovery didn't start: \(error)")
        }
    }

    /// The model for browsing `camera`. Cheap: nothing is opened until its screen runs it.
    public func browseModel(for camera: CameraDescriptor) -> BrowseModel {
        if let offline = offlineCameras[camera.id] { return offlineBrowseModel(for: camera, offline) }
        let discovery = self.discovery
        let id = camera.id
        let model = BrowseModel(
            camera: camera,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in
                try await discovery.cameraLink(for: id)
            },
            services: services,
            openFailureText: { await discovery.openFailureText(for: id) },
            openWasDeclined: { await discovery.openWasDeclined(for: id) },
            onGone: { [weak self] id in self?.cameraWentAway(id) },
            onDeclined: { [weak self] id in self?.openWasDeclined(id) },
            catalogue: catalogue.map {
                BrowseCatalogue(store: $0, cameraKey: cameraKey, knownKey: { await discovery.knownKey(for: id) })
            },
            importer: importModel,
            leases: leases,
            cameraName: displayName(for: camera)
        )
        browsing.removeAll { $0.model == nil }
        browsing.append(WeakBrowse(model: model))
        model.onListed = { [weak self] listed in
            self?.onBrowseListed?(listed)
            self?.browseListed(camera)
        }
        return model
    }

    /// Reads the Imported and Staged badges again in every Browse model still alive, after the catalogue's rows changed
    /// outside a job (the launch pass resolving pending commits, I15).
    public func refreshBrowseBadges() async {
        browsing.removeAll { $0.model == nil }
        for entry in browsing {
            await entry.model?.refreshImportedStates()
        }
    }

    // MARK: - App Intents (I16)

    /// Told when a Browse model has listed its camera's live card (`BrowseModel.onListed`). Set by `AppModel`, which
    /// starts an "Import new photos" waiting for that camera.
    @ObservationIgnored var onBrowseListed: (@MainActor (BrowseModel) -> Void)?

    /// Told when the navigation stack changes (the person left Browse, or opened another camera). Set by `AppModel`,
    /// which drops an "Import new photos" waiting for a camera no longer shown.
    @ObservationIgnored var onPathChanged: (@MainActor ([CameraDescriptor]) -> Void)?

    /// The Browse models still alive for the camera `id`, the most recently made last.
    func browses(of id: CameraDescriptor.ID) -> [BrowseModel] {
        browsing.removeAll { $0.model == nil }
        return browsing.compactMap { entry in entry.model.flatMap { $0.camera.id == id ? $0 : nil } }
    }

    /// The Browse models still alive that show their camera's live card, the most recently made last. A model whose
    /// screen was never shown never runs, so it never shows a live card.
    func liveBrowses() -> [BrowseModel] {
        browsing.removeAll { $0.model == nil }
        return browsing.compactMap { entry in entry.model.flatMap { $0.showsLiveCard ? $0 : nil } }
    }

    /// The scene changed: every Browse model still alive is told, so a Wi-Fi Browse knows whether a lost session happened
    /// in front (`BrowseModel.scenePhaseChanged(_:)`).
    public func browseScenePhaseChanged(_ scene: AppScenePhase) {
        browsing.removeAll { $0.model == nil }
        for entry in browsing { entry.model?.scenePhaseChanged(scene) }
    }

    /// A link to the connected camera whose catalogue key is `key`, for the import to carry on through after a
    /// removal. A camera whose key discovery knows (a Wi-Fi camera that has connected before) is matched by it, and
    /// only the match is opened, so no other Wi-Fi camera is joined to be compared. For the rest, asks discovery for
    /// each camera's link (cheap over USB: nothing is opened) until one matches.
    public func link(forCameraWith key: CameraKey) async -> (any CameraLink)? {
        for camera in cameras {
            if let known = await discovery.knownKey(for: camera.id) {
                guard known == key else { continue }
                return try? await discovery.cameraLink(for: camera.id)
            }
            // A Wi-Fi camera with no key yet has never connected: no job can be under its key, and asking for its
            // link would start a join just to find that out.
            if camera.carrier == .wifi { continue }
            guard let link = try? await discovery.cameraLink(for: camera.id) else { continue }
            if await cameraKey(camera, link) == key { return link }
        }
        return nil
    }

    /// The attached USB cameras that list files whose key isn't `key` (`CameraFinding`), for continuing a paused job on
    /// the same body in the other Image Transfer mode by content (D11). Never a Wi-Fi camera (its link could start a
    /// join) nor one in Remote Shoot (it lists nothing). Each camera's key is the one discovery knows for it, else the
    /// one read from its link, as `link(forCameraWith:)` reads it; nothing is opened (cheap over USB).
    public func otherUSBCameras(than key: CameraKey) async -> [AttachedCamera] {
        var found: [AttachedCamera] = []
        for camera in cameras where camera.carrier == .usb && camera.mode != .usb(.remoteShoot) {
            let known = await discovery.knownKey(for: camera.id)
            if known == key { continue }
            guard let link = try? await discovery.cameraLink(for: camera.id) else { continue }
            let cameraKey: CameraKey
            if let known { cameraKey = known } else { cameraKey = await self.cameraKey(camera, link) }
            guard cameraKey != key else { continue }
            found.append(AttachedCamera(descriptor: camera, key: cameraKey, link: link))
        }
        return found
    }

    // MARK: - One name per body (D11)

    /// The name the camera's row and Browse's title show: in Image Transfer (MSC) the one named body's
    /// (`onlyBodyName`), else "Camera"; otherwise the camera's own name (`CameraNaming.displayName(for:onlyBodyName:)`).
    /// An offline Browse's camera keeps the name it was given from the catalogue.
    public func displayName(for camera: CameraDescriptor) -> String {
        if let offline = offlineCameras[camera.id] { return offline.browse.name }
        return CameraNaming.displayName(for: camera, onlyBodyName: onlyBodyName)
    }

    /// Reads the one named body again from the catalogue's Camera rows.
    public func refreshOnlyBodyName() async {
        guard let catalogue, let records = try? await catalogue.cameras() else { return }
        let name = CameraNaming.onlyBodyName(among: records)
        if name != onlyBodyName { onlyBodyName = name }
    }

    /// What the camera's row may say about the device: its battery level and the card's free space, only for a link that
    /// reports them (`CameraLinkCapabilities.reportsBatteryAndFreeSpace`; Wi-Fi's does not, B:70). `nil` for a value
    /// nobody has read: unknown is never shown as 0, so a Wi-Fi row can never grow a "0%" or "0 bytes free". The free
    /// space is the one last read (`cardFreeBytes`) unless one is given; the battery level isn't read yet
    /// (`unverified`).
    public func deviceStatusLines(for camera: CameraDescriptor, batteryPercent: Int? = nil,
                                  freeBytes: UInt64? = nil) -> [String] {
        CamerasWording.deviceStatus(carrier: camera.carrier, batteryPercent: batteryPercent,
                                    freeBytes: freeBytes ?? cardFreeBytes[camera.id])
    }

    // MARK: - The card's free space (I17)

    /// Browse listed `camera`'s live card: its catalogue has completed, so a USB link in Image Transfer (MTP) can now
    /// say how much space is free on the card.
    private func browseListed(_ camera: CameraDescriptor) {
        Task { [weak self] in await self?.readCardFreeSpace(of: camera) }
        // Browse wrote the camera's name to its row (D11), which may name the one body.
        Task { [weak self] in await self?.refreshOnlyBodyName() }
    }

    /// Reads the card's free space over `camera`'s link, when its carrier reports one (USB; never Wi-Fi, whose link
    /// would be joined just to ask, and whose storage reports nothing) and the link can read it
    /// (`CardFreeSpaceReading`: `USBLink` in MTP, after the catalogue, between downloads). A value it can't read now
    /// leaves the last one in place; the camera going away clears it.
    func readCardFreeSpace(of camera: CameraDescriptor) async {
        guard CameraLinkCapabilities.defaults(for: camera.carrier).reportsBatteryAndFreeSpace,
              let link = try? await discovery.cameraLink(for: camera.id),
              let reader = link as? any CardFreeSpaceReading
        else { return }
        guard let free = await reader.cardFreeSpace() else {
            services.log.note("cameras: the card's free space wasn't read")
            return
        }
        // The camera may have gone while the link was asked.
        guard cameras.contains(where: { $0.id == camera.id }) else { return }
        cardFreeBytes[camera.id] = free
        services.log.note("cameras: the card has \(free) bytes free")
    }

    // MARK: - Keys and the nearby badge (W16)

    /// Reads again the key of every listed camera whose key discovery knows.
    public func refreshKnownKeys() async {
        for camera in cameras {
            await readKnownKey(of: camera.id)
        }
    }

    private func readKnownKey(of id: CameraDescriptor.ID) async {
        let key = await discovery.knownKey(for: id)
        // The camera may have gone while discovery was asked.
        guard cameras.contains(where: { $0.id == id }) else { return }
        if knownKeys[id] != key { knownKeys[id] = key }
    }

    /// Whether to show the *nearby* badge on `camera`'s row: its key is known and `isNearby` says so for it
    /// (`ReminderModel.isNearby(_:)`, the proximity scan's reports). Unknown is not nearby.
    public func isNearby(_ camera: CameraDescriptor, by isNearby: (CameraKey) -> Bool) -> Bool {
        guard let key = knownKeys[camera.id] else { return false }
        return isNearby(key)
    }

    /// The person declined to open the camera (Not Now on the Local Network explanation): back to Cameras, with no message,
    /// since nothing went wrong.
    func openWasDeclined(_ id: CameraDescriptor.ID) {
        path.removeAll { $0.id == id }
    }

    /// The camera went away: if it is being browsed, back to Cameras with a message.
    public func cameraWentAway(_ id: CameraDescriptor.ID) {
        guard let browsed = path.first(where: { $0.id == id }) else { return }
        path.removeAll()
        noticeCount += 1
        notice = CamerasWording.disconnected(browsed)
        noticeCamera = id
    }

    func apply(_ event: CameraDiscoveryEvent) {
        switch event {
        case let .appeared(camera):
            if notice != nil, camera.id == noticeCamera {
                // Connected again: "connect it again" no longer applies.
                notice = nil
                noticeCamera = nil
            }
            if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
                cameras[index] = camera
            } else {
                cameras.append(camera)
            }
            // The import checks the engine itself: a job paused by a removal carries on if this is its camera.
            if let importModel {
                Task { await importModel.cameraConnected() }
            }
            let id = camera.id
            Task { [weak self] in await self?.readKnownKey(of: id) }
            Task { [weak self] in await self?.refreshOnlyBodyName() }
            // An offline Browse shown for this camera becomes the live one (W6-absent).
            if let shown = path.last, offlineCameras[shown.id] != nil {
                Task { [weak self] in await self?.matchOfflineCamera() }
            }
        case let .disappeared(id):
            cameras.removeAll { $0.id == id }
            knownKeys[id] = nil
            withdrawOfflineConnect(from: id)
            cardFreeBytes[id] = nil
            // A probe of the paused job may list its card again once it is back (D11).
            importModel?.cameraDisappeared(id)
            cameraWentAway(id)
        }
    }

    /// The discovery stream has one consumer and ends if its consuming task is cancelled, so it is read by one task
    /// for the model's lifetime, never tied to a view's appearance.
    private func watchDiscoveries() {
        guard watchTask == nil else { return }
        let stream = discovery.discoveries
        watchTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }
}

// MARK: - Not connected (W6-absent)

/// The camera an offline Browse stands for, and the listed Wi-Fi camera its Connect would open.
@MainActor
struct OfflineCamera {
    let descriptor: CameraDescriptor
    let browse: OfflineBrowse
    /// The listed Wi-Fi camera with this key, once there is one: Connect opens it.
    var listed: CameraDescriptor?
}

extension CamerasModel {
    /// The descriptor to push for an offline Browse of the camera whose catalogue key is `key` (W6-absent): a camera
    /// "Import new photos" asked for that isn't listed. Named as the catalogue names it (`HistoryWording.cameraName`) and
    /// reached as it was last set up for. It is never among `cameras`, and its Browse opens nothing
    /// (`BrowseModel.offline`).
    func offlineCamera(for key: CameraKey) async -> CameraDescriptor {
        if let known = offlineCamera(withKey: key) { return known.descriptor }
        var record: CameraRecord?
        if let catalogue { record = try? await catalogue.camera(key) }
        let name = HistoryWording.cameraName(record)
        let carrier: CameraCarrier = record?.preferredCarrier == .wifi ? .wifi : .usb
        // A camera asked for twice while the catalogue was read gets the first descriptor.
        if let known = offlineCamera(withKey: key) { return known.descriptor }
        let descriptor = CameraDescriptor(id: .init(rawValue: "offline-\(offlineCameras.count + 1)"), name: name,
                                          mode: carrier == .wifi ? .wifi(.cameraNetwork) : .usb(.massStorage))
        offlineCameras[descriptor.id] = OfflineCamera(descriptor: descriptor,
                                                      browse: OfflineBrowse(key: key, name: name, carrier: carrier))
        return descriptor
    }

    /// Whether `id` is an offline Browse's descriptor.
    func isOffline(_ id: CameraDescriptor.ID) -> Bool { offlineCameras[id] != nil }

    private func offlineCamera(withKey key: CameraKey) -> OfflineCamera? {
        offlineCameras.values.first { $0.browse.key == key }
    }

    /// The offline Browse on screen, if any, becomes the live Browse once its camera is listed: at once over USB, where
    /// listing opens nothing; a Wi-Fi camera's Browse offers Connect instead, since reaching it is a join, which only the
    /// person's tap starts (Shamil, 10 Nov). A camera listed over both goes live over USB: a Wi-Fi listing offering
    /// Connect doesn't hold back the cable. Matched by the key discovery knows for a camera (a Wi-Fi camera that has
    /// connected before), else, over USB, by the key read from its link (nothing is opened), as
    /// `link(forCameraWith:)` matches.
    func matchOfflineCamera() async {
        guard let shown = path.last, let offline = offlineCameras[shown.id] else { return }
        var overWiFi: CameraDescriptor?
        for camera in cameras {
            guard await isCamera(camera, withKey: offline.browse.key) else { continue }
            // The person may have left while discovery was asked.
            guard path.last?.id == shown.id else { return }
            if camera.carrier == .wifi {
                if overWiFi == nil { overWiFi = camera }
                continue
            }
            services.log.note("cameras: the camera shown as not connected is connected; opening its card")
            replaceOffline(shown.id, with: camera)
            return
        }
        guard let overWiFi, offlineCameras[shown.id]?.listed != overWiFi else { return }
        offlineCameras[shown.id]?.listed = overWiFi
        services.log.note("cameras: the camera shown as not connected is listed over Wi-Fi; offering Connect")
        offerConnect(true, on: shown.id)
    }

    /// Connect on an offline Browse: the live Browse on the listed Wi-Fi camera replaces it, and starts the join.
    func connectOffline(_ id: CameraDescriptor.ID) {
        // By ID: a Wi-Fi camera's descriptor is renamed by its model at its first connection (D11).
        guard path.last?.id == id, let listed = offlineCameras[id]?.listed,
              let live = cameras.first(where: { $0.id == listed.id }) else { return }
        replaceOffline(id, with: live)
    }

    private func replaceOffline(_ id: CameraDescriptor.ID, with live: CameraDescriptor) {
        onOfflineReplaced?(id, live)
        path = [live]
    }

    /// A listed Wi-Fi camera went: the offline Browse that offered Connect to it no longer does.
    private func withdrawOfflineConnect(from id: CameraDescriptor.ID) {
        for (offlineID, offline) in offlineCameras where offline.listed?.id == id {
            offlineCameras[offlineID]?.listed = nil
            offerConnect(false, on: offlineID)
        }
    }

    private func offerConnect(_ offered: Bool, on id: CameraDescriptor.ID) {
        browsing.removeAll { $0.model == nil }
        for entry in browsing where entry.model?.camera.id == id { entry.model?.offerConnect(offered) }
    }

    private func offlineBrowseModel(for camera: CameraDescriptor, _ offline: OfflineCamera) -> BrowseModel {
        let model = BrowseModel(
            camera: camera,
            openLink: { () async throws(CameraLinkFailure) -> any CameraLink in
                throw CameraLinkFailure(.disconnected, detail: "offline Browse")
            },
            services: services,
            onGone: { _ in },
            catalogue: catalogue.map { BrowseCatalogue(store: $0, cameraKey: cameraKey) },
            importer: importModel,
            leases: leases,
            offline: offline.browse
        )
        model.offerConnect(offline.listed != nil)
        model.onConnect = { [weak self] in self?.connectOffline(camera.id) }
        browsing.removeAll { $0.model == nil }
        browsing.append(WeakBrowse(model: model))
        return model
    }

    /// Whether `camera` is the one whose catalogue key is `key`, opening nothing: a Wi-Fi camera with no key yet has never
    /// connected, and asking for its link would start a join.
    private func isCamera(_ camera: CameraDescriptor, withKey key: CameraKey) async -> Bool {
        if let known = await discovery.knownKey(for: camera.id) { return known == key }
        guard camera.carrier != .wifi, let link = try? await discovery.cameraLink(for: camera.id) else { return false }
        return await cameraKey(camera, link) == key
    }
}

/// A Browse model held weakly: the screen owns it.
@MainActor
private struct WeakBrowse {
    weak var model: BrowseModel?
}
