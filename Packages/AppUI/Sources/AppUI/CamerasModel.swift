import CameraTransport
import Catalogue
import Foundation
import Observation

/// What the Cameras screen needs from discovery: `USBCameraBrowser` in the app (its conformance sits behind
/// `#if canImport(ImageCaptureCore)`), a fake in tests.
public protocol CameraDiscovery: Actor {
    /// Cameras appearing and going away. One consumer: `CamerasModel`.
    nonisolated var discoveries: AsyncStream<USBDiscoveryEvent> { get }
    /// Asks for access and starts looking. Throws `notAuthorised` when access is denied or restricted. Starting a
    /// started discovery does nothing.
    func start() async throws(CameraLinkFailure)
    /// The link for an attached camera. Throws `disconnected` if it has gone.
    func cameraLink(for id: CameraDescriptor.ID) async throws(CameraLinkFailure) -> any CameraLink
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
            onGone: { [weak self] id in self?.cameraWentAway(id) },
            catalogue: catalogue.map { BrowseCatalogue(store: $0, cameraKey: cameraKey) },
            importer: importModel,
            leases: leases
        )
    }

    /// A link to the connected camera whose catalogue key is `key`, for the import to carry on through after a
    /// removal. Asks discovery for each connected camera's link (cheap: nothing is opened) until one matches.
    public func link(forCameraWith key: CameraKey) async -> (any CameraLink)? {
        for camera in cameras {
            guard let link = try? await discovery.cameraLink(for: camera.id) else { continue }
            if await cameraKey(camera, link) == key { return link }
        }
        return nil
    }

    /// The camera went away: if it is being browsed, back to Cameras with a message.
    public func cameraWentAway(_ id: CameraDescriptor.ID) {
        guard let browsed = path.first(where: { $0.id == id }) else { return }
        path.removeAll()
        noticeCount += 1
        notice = CamerasWording.disconnected(browsed)
        noticeCamera = id
    }

    func apply(_ event: USBDiscoveryEvent) {
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
