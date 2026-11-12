import CameraTransport
import Catalogue
import Foundation

/// The connected camera for History's *Resume* and *Re-run* (backlog section 4), found without starting a join: a link
/// someone already holds (Browse open on the camera, or its import), then a USB camera on the port, whose link costs
/// nothing to ask for. A Wi-Fi camera that isn't open isn't connected, so its row says to open it in Cameras, rather
/// than a History tap joining the camera's network with no screen to show it.
@MainActor
public final class HistoryCameraFinder: CameraFinding {
    private let leases: LinkLeases
    private let cameras: @MainActor () -> [CameraDescriptor]
    private let link: @MainActor (CameraDescriptor.ID) async -> (any CameraLink)?
    private let key: CameraKeying

    /// - Parameters:
    ///   - cameras: The cameras listed now (`CamerasModel.cameras`).
    ///   - link: A listed camera's link (`CameraDiscovery.cameraLink(for:)`), asked only for USB cameras.
    ///   - key: The catalogue key of a camera's link, as Browse and the import read it.
    public init(leases: LinkLeases, cameras: @escaping @MainActor () -> [CameraDescriptor],
                link: @escaping @MainActor (CameraDescriptor.ID) async -> (any CameraLink)?,
                key: @escaping CameraKeying) {
        self.leases = leases
        self.cameras = cameras
        self.link = link
        self.key = key
    }

    public func link(forCameraWith wanted: CameraKey) async -> (any CameraLink)? {
        for held in leases.heldLinks where await key(held.descriptor, held) == wanted {
            return held
        }
        for camera in cameras() where camera.carrier == .usb {
            guard let candidate = await link(camera.id) else { continue }
            if await key(camera, candidate) == wanted { return candidate }
        }
        return nil
    }
}
