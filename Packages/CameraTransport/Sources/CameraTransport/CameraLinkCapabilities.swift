import Foundation

/// What a link can do, so the engine and the screens follow the link's rules and never `if carrier == .usb`
/// (wireless plan, decision 5). Every field is a fact about the link, read once when the engine takes it.
///
/// `CameraLinkCapabilities.defaults(for:)` is each carrier's baseline, from the bench; a link may report less
/// (a Wi-Fi link whose camera lacks 0x9211 would say `resumesPartialFiles: false`), never more than it can do.
public struct CameraLinkCapabilities: Sendable, Hashable {
    /// Downloads the link can run at once. The engine runs `min(its setting, this)` (`ImportEngine`, W7). USB 2:
    /// the setting's range is 1–2 and ImageCaptureCore takes both. Wi-Fi 1: a PTP/IP session carries one
    /// transaction at a time (backlog Iteration 3, "One transaction at a time"), and the spike's client threw
    /// `.busy` on a second `perform`. Two in flight on a real camera was never tried (`unverified`; the test was
    /// dropped). Never below 1, whatever is assigned: a limit of 0 would start no download and hang the job.
    public var maxDownloadsInFlight: Int {
        didSet { maxDownloadsInFlight = max(1, maxDownloadsInFlight) }
    }

    /// Whether `bytes(of:into:resuming:…)` honours a `PartialDownload` and continues from its offset. Wi-Fi: true,
    /// over Sony's 0x9211 (a read cut at 54 % resumed at the saved offset and the SHA-256 matched, 2 Nov 23:10).
    /// USB: false; ImageCaptureCore copies whole files, so the engine deletes a partial file and starts at 0.
    public var resumesPartialFiles: Bool

    /// Whether the camera's battery level and the card's free space can be read over this link. USB: true in
    /// principle (`unverified`: the app reads neither yet). Wi-Fi: false, the whole-card session lists no device
    /// properties and the storage reports capacity 0, so the Cameras screen hides both rather than show 0.
    public var reportsBatteryAndFreeSpace: Bool

    /// Whether files can be deleted on the camera through this link. Wi-Fi: false, the session's storage is
    /// read-only without deletion. USB: true in principle (`unverified`: ImageCaptureCore can delete, but the
    /// contract has no delete call and 1.0 never deletes).
    public var deletes: Bool

    /// Whether a `CameraItem.ID` from one session names the same file in the next. Wi-Fi: true, PTP handles were
    /// stable across sessions on the bench. USB: false, ImageCaptureCore's item identifiers are per session, so a
    /// replug maps files again by identity. Still a hint on every link: the engine checks name and size before it
    /// resumes or skips a file found by ID (backlog Iteration 3, section 2, "Identity still decides").
    public var itemIDsSurviveReopen: Bool

    public init(
        maxDownloadsInFlight: Int,
        resumesPartialFiles: Bool,
        reportsBatteryAndFreeSpace: Bool,
        deletes: Bool,
        itemIDsSurviveReopen: Bool
    ) {
        self.maxDownloadsInFlight = max(1, maxDownloadsInFlight)
        self.resumesPartialFiles = resumesPartialFiles
        self.reportsBatteryAndFreeSpace = reportsBatteryAndFreeSpace
        self.deletes = deletes
        self.itemIDsSurviveReopen = itemIDsSurviveReopen
    }

    /// `USBLink`'s capabilities: two downloads at a time, no resume, every file copied again from its start.
    public static let usb = CameraLinkCapabilities(
        maxDownloadsInFlight: 2, resumesPartialFiles: false, reportsBatteryAndFreeSpace: true, deletes: true,
        itemIDsSurviveReopen: false)

    /// `IPLink`'s capabilities over Sony's whole-card session: one transaction at a time, 0x9211 resume, nothing
    /// read from the device, no deletion, handles that outlive the session.
    public static let wifi = CameraLinkCapabilities(
        maxDownloadsInFlight: 1, resumesPartialFiles: true, reportsBatteryAndFreeSpace: false, deletes: false,
        itemIDsSurviveReopen: true)

    /// The baseline for a carrier.
    public static func defaults(for carrier: CameraCarrier) -> CameraLinkCapabilities {
        switch carrier {
        case .usb: .usb
        case .wifi: .wifi
        }
    }
}
