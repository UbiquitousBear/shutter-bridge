/// A link that can stop the transfer it is running at once, for when the import must stop now: the continued task
/// expiring, or Stop in the system's progress UI (backlog Iteration 3, section 6; wireless plan W13's expiry: flush the
/// checkpoints, pause, then this). Callers reach it through `link as? any TransferAborting`, so the expiry hook depends
/// on no particular link.
///
/// What a link does is its own: `IPLink` cuts the connection off (a GetObject's data phase can't be withdrawn
/// otherwise), so the call in flight throws `disconnected` with its partial file kept for the resume, and the link
/// reports `.sessionLost`. A link with nothing in flight does nothing. A link that can't stop a transfer (USB:
/// ImageCaptureCore copies whole files) doesn't adopt this.
public protocol TransferAborting: CameraLink {
    /// Stops the transfer in flight, if any. Returns without waiting for the call it stops to end.
    func abortCurrentTransfer() async
}
