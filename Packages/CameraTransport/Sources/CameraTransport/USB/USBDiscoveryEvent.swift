/// What USB discovery reports (backlog section 2, *Discover*): the same events every camera source reports
/// (`CameraDiscoveryEvent`), kept under its USB name so `USBCameraBrowser` and its tests read as they always did.
/// `USBCameraBrowser` produces these over ImageCaptureCore.
public typealias USBDiscoveryEvent = CameraDiscoveryEvent
