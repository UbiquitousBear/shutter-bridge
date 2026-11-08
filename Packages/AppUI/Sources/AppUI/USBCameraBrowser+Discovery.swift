#if canImport(ImageCaptureCore) && os(iOS)
import CameraTransport

/// The real discovery: PR #79's `USBCameraBrowser`, whose `discoveries` and `start()` already match.
extension USBCameraBrowser: CameraDiscovery {
    public func cameraLink(for id: CameraDescriptor.ID) async throws(CameraLinkFailure) -> any CameraLink {
        try await link(for: id)
    }
}
#endif
