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
}

extension CameraDiscovery {
    /// USB reads the key from the link (`CameraKeys`), so it knows none beforehand.
    public func knownKey(for id: CameraDescriptor.ID) async -> CameraKey? { nil }
    public func openFailureText(for id: CameraDescriptor.ID) async -> String? { nil }
    public func openWasDeclined(for id: CameraDescriptor.ID) async -> Bool { false }
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
/// paused by a removed cable carries on once the camera is back and listed (decision 7).
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
    public var path: [CameraDescriptor] = []
    /// A message for the top of the screen, such as a camera disconnected while it was browsed. It goes when that
    /// camera is connected again, or when the person closes it.
    public var notice: String?
    /// `notice` as the strip shows it, numbered so a second disconnect with the same text is announced again.
    public var noticeStatus: StatusNotice? { notice.map { StatusNotice.cameras($0, id: noticeCount) } }

    /// The import, told when a camera is connected, and handed Browse's selection. Set by the app (`AppModel`).
    @ObservationIgnored public weak var importModel: ImportModel?

    @ObservationIgnored private let discovery: any CameraDiscovery
    @ObservationIgnored private let services: BrowseServices
    @ObservationIgnored private let catalogue: (any CatalogueStore)?
    @ObservationIgnored private let cameraKey: CameraKeying
    @ObservationIgnored private let leases: LinkLeases
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var launched = false
    /// The camera `notice` is about, if it is about one.
    @ObservationIgnored private var noticeCamera: CameraDescriptor.ID?
    /// Counts the disconnect notices (`noticeStatus`'s id).
    private var noticeCount = 0

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
        let discovery = self.discovery
        let id = camera.id
        return BrowseModel(
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
            leases: leases
        )
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

    /// What the camera's row may say about the device: its battery level and the card's free space, only for a link that
    /// reports them (`CameraLinkCapabilities.reportsBatteryAndFreeSpace`; Wi-Fi's does not, B:70). `nil` for a value
    /// nobody has read: unknown is never shown as 0. The app reads neither over USB yet (`unverified`), so today the
    /// rule has nothing to show; it is here so a Wi-Fi row can never grow a "0%" or "0 bytes free".
    public func deviceStatusLines(for camera: CameraDescriptor, batteryPercent: Int? = nil,
                                  freeBytes: UInt64? = nil) -> [String] {
        CamerasWording.deviceStatus(carrier: camera.carrier, batteryPercent: batteryPercent, freeBytes: freeBytes)
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
        case let .disappeared(id):
            cameras.removeAll { $0.id == id }
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
