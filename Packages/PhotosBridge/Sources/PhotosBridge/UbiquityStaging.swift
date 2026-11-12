#if os(iOS)
import Foundation

// The iCloud side of staging (Shamil, 11 Nov). iOS only, so compiled only by CI's Xcode job; the rule, the folder
// layout and the placement it relies on are tested on Linux.
//
// The app is signed with the iCloud entitlements and declares the container in its Info.plist (12 Nov, docs/ci.md).
// A build without that declaration (the spike, or an older build) gets `.containerUnavailable` without asking iCloud,
// and staging goes to the app's folder on this iPhone, saying "iCloud Drive isn't available to Shutter Bridge".

/// Finds the app's iCloud Drive folder: the Documents folder of the container `containerIdentifier`, which Files
/// shows as iCloud Drive › Shutter Bridge.
///
/// - Unless the app declares the container (`NSUbiquitousContainers` in its Info.plist, added with the iCloud
///   entitlements; docs/ci.md), iCloud isn't asked at all: the answer is `.containerUnavailable`
///   ("iCloud Drive isn't available to Shutter Bridge"). Asking would mislead: `ubiquityIdentityToken` is commonly
///   reported nil for an app without the entitlement (unverified on the iPhone; bench S1), which would read as
///   iCloud Drive being off for a person who is signed in with it on.
/// - The container is asked for first, and the token only when there is none, to tell signed out or iCloud Drive
///   off (`.iCloudDriveOff`) from the app's own switch under iCloud Drive being off (`.containerUnavailable`). Apple
///   documents the token as nil when iCloud is unavailable for any reason, so the app's switch being off may still
///   read as `.iCloudDriveOff` (unverified; bench S10).
/// - Nothing is cached: every import, continue and Settings refresh asks again, so turning the app's switch back on,
///   or signing in, is seen at once without waiting for `NSUbiquityIdentityDidChange` (which the app's own switch
///   may not post). `url(forUbiquityContainerIdentifier:)` can block, mostly on its first call (Apple's iCloud Design
///   Guide: call it from a background thread), so it runs on the actor's executor, never on the main actor; when
///   iCloud is unavailable it answers quickly.
/// - The Documents folder gets complete-until-first-unlock protection (`StagingProtection`), so a commit in the
///   seconds after the phone locks still works (decision 9). That is best effort: a folder that exists but refuses
///   the attribute is still used, since a staged file keeps the protection its temporary file was given.
public actor UbiquityStagingLocator: StagingLocator {
    /// The app's iCloud container.
    public static let containerIdentifier = "iCloud.net.shamil.shutter-bridge"

    public init() {}

    public func locate() async -> StagingAvailability {
        Self.find()
    }

    /// Whether the app's Info.plist declares the container under `NSUbiquitousContainers`, added with the iCloud
    /// entitlements (docs/ci.md, "iCloud for staging").
    static var declaresContainer: Bool {
        guard let containers = Bundle.main.object(forInfoDictionaryKey: "NSUbiquitousContainers") as? [String: Any]
        else { return false }
        return containers[containerIdentifier] != nil
    }

    /// Asks iCloud: the container's Documents folder; or why there is none (this build isn't set up for iCloud, no
    /// account with iCloud Drive on, or no container for this app).
    private static func find() -> StagingAvailability {
        guard declaresContainer else { return .unavailable(.containerUnavailable) }
        let fm = FileManager.default
        guard let container = fm.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return .unavailable(fm.ubiquityIdentityToken == nil ? .iCloudDriveOff : .containerUnavailable)
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        do {
            try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        } catch {
            return .unavailable(.containerUnavailable)
        }
        try? StagingProtection.prepareDirectory(documents) // best effort: the folder exists
        return .iCloudDrive(documents: documents)
    }
}

/// Moves a staged file into the app's iCloud Drive folder with `FileManager.setUbiquitous(true, itemAt:
/// destinationURL:)`, the documented way to move a local file into iCloud, which coordinates the move itself; and
/// back out with `setUbiquitous(false, …)`. Runs inside the staging destination's actor, never on the main actor (it
/// mustn't be called from the main thread). The move into the container is expected to be a rename on the same data
/// volume (to be confirmed on the device).
public struct UbiquitousFileMover: StagedFileMover {
    public init() {}

    public func place(_ staged: URL, at target: URL) throws {
        try FileManager.default.setUbiquitous(true, itemAt: staged, destinationURL: target)
    }

    public func takeBack(_ target: URL, to staged: URL) throws {
        try FileManager.default.setUbiquitous(false, itemAt: target, destinationURL: staged)
    }

    /// The capture date is set on the staged file before the move and travels with it; no uncoordinated write to a
    /// file in iCloud Drive afterwards.
    public var setsDateAfterPlacing: Bool { false }
}
#endif
