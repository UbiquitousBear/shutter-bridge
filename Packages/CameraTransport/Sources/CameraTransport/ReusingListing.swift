/// A link that can list the card again asking the camera only about files it hasn't seen, so a recovery or a Continue on a
/// new session doesn't relist the whole card (`IPLink.list(reusing:)`, W8: GetObjectInfo only for handles the known items
/// don't name; 7.2 s for 298 files in the 4 Nov 01:08 relist). Callers reach it through `link as? any ReusingListing`, as
/// they reach `TransferAborting`, so the recovery depends on no particular link; a link that can't (USB) is listed in full.
public protocol ReusingListing: CameraLink {
    /// The card, with `known` items whose handles are listed again kept as they are (a hint, checked when used) and the
    /// rest asked of the camera. With no known items this is `list()`.
    func list(reusing known: [CameraItem]) async throws(CameraLinkFailure) -> [CameraItem]
}

extension IPLink: ReusingListing {}
