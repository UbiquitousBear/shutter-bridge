#if canImport(ImageCaptureCore) && os(iOS)
import Foundation
import ImageCaptureCore

/// USB discovery over ImageCaptureCore (backlog section 2, *Discover*): an `ICDeviceBrowser` with the
/// "Cameras, local" mask (0x101), which found the α7C II in MSC, MTP and PC Remote on the bench. Each camera is
/// surfaced as a `CameraDescriptor` whose mode comes from the transport type (`USBModeClassifier`); Live Stream (USB
/// Streaming) never enumerates. The browser also owns ImageCaptureCore's lifecycle callbacks (will suspend, did
/// suspend, cancelled suspending, resumed operations) and passes them to every link it has handed out.
///
/// Runs on the main actor's executor, like `USBLink`, so the two can share ImageCaptureCore's objects safely.
public actor USBCameraBrowser {
    public nonisolated var unownedExecutor: UnownedSerialExecutor { MainActor.sharedUnownedExecutor }

    /// Cameras appearing and going away. One consumer (the Cameras screen's model). An `appeared` for a camera
    /// already reported is an update (ImageCaptureCore renamed it).
    public nonisolated let discoveries: AsyncStream<USBDiscoveryEvent>
    private let discoverySink: AsyncStream<USBDiscoveryEvent>.Continuation

    private struct Device {
        let camera: ICCameraDevice
        let uuid: String?
    }

    private struct WeakLink {
        weak var link: USBLink?
    }

    private var browser: ICDeviceBrowser?
    private var delegate: USBBrowserDelegate?
    private var signalTask: Task<Void, Never>?
    /// One entry per descriptor ID, the newest device for it (ImageCaptureCore can list a camera twice).
    private var attached = USBAttachedCameras()
    private var devices: [ObjectIdentifier: Device] = [:]
    /// Keyed by the link's device, not its descriptor ID, so a removal reaches only the link on the device that went.
    private var links: [ObjectIdentifier: WeakLink] = [:]
    private var unnamedDevices = 0

    public init() {
        (discoveries, discoverySink) = AsyncStream.makeStream()
    }

    /// The cameras attached now.
    public var cameras: [CameraDescriptor] { attached.cameras }

    /// Asks for access and starts browsing. Contents access is what listing and downloading need; control access is
    /// asked too, as the proposal's privacy table says, though no PTP command is sent. On iOS 27.2 neither showed a
    /// prompt and both returned `authorized`. Throws `notAuthorised` if contents access is denied or restricted.
    /// Starting a started browser does nothing.
    public func start() async throws(CameraLinkFailure) {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        let (signals, sink) = AsyncStream<USBBrowserSignal>.makeStream()
        let delegate = USBBrowserDelegate(sink)
        browser.delegate = delegate

        let contents: USBContentsAccess = await withCheckedContinuation { continuation in
            browser.requestContentsAuthorization { @Sendable status in
                continuation.resume(returning: USBContentsAccess(status))
            }
        }
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<USBContentsAccess, Never>) in
            browser.requestControlAuthorization { @Sendable status in
                continuation.resume(returning: USBContentsAccess(status))
            }
        }
        guard contents.allowsBrowsing else {
            browser.delegate = nil
            throw CameraLinkFailure(.notAuthorised, detail: "browse: contents access \(contents.rawValue)")
        }
        guard self.browser == nil else { return }   // a concurrent start got there first

        // "Cameras, local", as the spike's default that worked: the camera type ORed with the local location.
        let raw = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: raw) ?? .camera

        self.browser = browser
        self.delegate = delegate
        signalTask = Task { [weak self] in
            for await signal in signals {
                guard let self else { return }
                await self.handle(signal)
            }
        }
        browser.start()
    }

    /// Stops browsing. Links already handed out keep their sessions; every camera is reported gone.
    public func stop() {
        guard let browser else { return }
        browser.stop()
        browser.delegate = nil
        self.browser = nil
        delegate = nil
        signalTask?.cancel()
        signalTask = nil
        for event in attached.removeAll() { discoverySink.yield(event) }
        devices.removeAll()
    }

    /// The link for an attached camera, on the newest device listed for it: the one already handed out for that
    /// device while it is usable, otherwise a new one (after a replug, or when ImageCaptureCore lists the camera again,
    /// it is a new device, so a new link). Throws `disconnected` if the camera isn't attached.
    public func link(for id: CameraDescriptor.ID) async throws(CameraLinkFailure) -> USBLink {
        guard let identifier = attached.device(for: id), let device = devices[identifier],
              let descriptor = attached.descriptor(of: identifier) else {
            throw CameraLinkFailure(.disconnected, detail: "link: the camera isn't attached")
        }
        if let existing = links[identifier]?.link, await existing.isUsable { return existing }
        let link = USBLink(device: ICObject(object: device.camera), descriptor: descriptor, deviceUUID: device.uuid)
        links[identifier] = WeakLink(link: link)
        return link
    }

    // MARK: - Browser signals

    private func handle(_ signal: USBBrowserSignal) async {
        switch signal {
        case let .added(box):
            added(box.object)
        case let .removed(identifier):
            // Reaches only the link on this device; `disappeared` only if no other listing of the camera is left.
            devices[identifier] = nil
            for event in attached.remove(identifier) { discoverySink.yield(event) }
            if let link = links.removeValue(forKey: identifier)?.link { await link.browserReportedRemoval() }
        case let .renamed(identifier):
            guard let device = devices[identifier] else { return }
            for event in attached.rename(identifier, to: device.camera.name) { discoverySink.yield(event) }
        case let .lifecycle(event):
            links = links.filter { $0.value.link != nil }
            for entry in links.values {
                if let link = entry.link { await link.forward(event) }
            }
        }
    }

    private func added(_ device: ICDevice) {
        // Only cameras whose transport type is one the α7C II showed: MSC, or MTP / Remote Shoot.
        guard let camera = device as? ICCameraDevice,
              let mode = USBModeClassifier.provisionalMode(transportType: camera.transportType) else { return }
        let identifier = ObjectIdentifier(camera)
        guard devices[identifier] == nil else { return }
        let uuid = camera.uuidString.flatMap { $0.isEmpty ? nil : $0 }
        let id: CameraDescriptor.ID
        if let uuid {
            id = CameraDescriptor.ID(rawValue: uuid)
        } else {
            unnamedDevices += 1
            id = CameraDescriptor.ID(rawValue: "usb-device-\(unnamedDevices)")
        }
        let descriptor = CameraDescriptor(id: id, name: camera.name ?? "Camera", mode: .usb(mode))
        // An older listing of the same camera stops being offered (`link(for:)` takes the newest), but its device is
        // kept until its own removal, so that removal reaches its link and it can be offered again if the newer goes.
        devices[identifier] = Device(camera: camera, uuid: uuid)
        for event in attached.add(identifier, descriptor) { discoverySink.yield(event) }
    }
}
#endif
