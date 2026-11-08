/// What USB discovery reports (backlog section 2, *Discover*): a camera appearing with its descriptor, or going
/// away. `USBCameraBrowser` produces these over ImageCaptureCore; the type itself is transport-neutral so screens and
/// tests can use it on Linux with a fake.
public enum USBDiscoveryEvent: Sendable, Hashable {
    /// A camera the browser can open. Its mode comes from the transport type: MSC for `ICTransportTypeMassStorage`,
    /// MTP for `ICTransportTypeUSB` until the catalogue says Remote Shoot (PC Remote) (`USBLink.mode`).
    case appeared(CameraDescriptor)
    /// The camera went away (cable pulled, camera off). Its link, if open, also reports `CameraLinkEvent.removed`.
    case disappeared(CameraDescriptor.ID)
}
