/// What a camera source reports (backlog section 2, *Discover*; wireless plan W15): a camera appearing with its
/// descriptor, or going away. USB's browser, the Wi-Fi cameras the app knows and `CompositeDiscovery`'s merge of them
/// all use it, so the Cameras screen reads one stream whatever the carrier. The type is transport-neutral, so screens
/// and tests use it on Linux with a fake.
///
/// A camera that is already listed and appears again with the same `CameraDescriptor.ID` is an update (its name or
/// mode changed), not a second camera.
public enum CameraDiscoveryEvent: Sendable, Hashable {
    /// A camera a link can be opened to. Over USB its mode comes from the transport type: MSC for
    /// `ICTransportTypeMassStorage`, MTP for `ICTransportTypeUSB` until the catalogue says Remote Shoot
    /// (`USBLink.mode`). Over Wi-Fi it is a camera the person set up, listed whether or not it is in reach: reaching it
    /// is the join's job, when it is opened.
    case appeared(CameraDescriptor)
    /// The camera went away (cable pulled, camera off) or was removed from the app. Its link, if open, also reports
    /// `CameraLinkEvent.removed`.
    case disappeared(CameraDescriptor.ID)
}
