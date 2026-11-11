#if os(iOS)
import Foundation

// The iCloud side of staging (Shamil, 11 Nov). iOS only, so compiled only by CI's Xcode job; the rule, the folder
// layout and the placement it relies on are tested on Linux.
//
// Until the App ID has iCloud and the app is signed with the iCloud entitlements (a follow-up change, docs/ci.md),
// `url(forUbiquityContainerIdentifier:)` answers nil and staging goes to the app's folder on this iPhone.

/// Finds the app's iCloud Drive folder: the Documents folder of the container `containerIdentifier`, which Files
/// shows as iCloud Drive › Shutter Bridge.
///
/// - `url(forUbiquityContainerIdentifier:)` can block (Apple's iCloud Design Guide: call it from a background
///   thread), so it runs on the actor's executor, never on the main actor.
/// - The answer is cached, and the cache cleared when the iCloud account changes (`NSUbiquityIdentityDidChange`:
///   signed out, another account, iCloud Drive turned off), so the next import asks again.
/// - The Documents folder gets complete-until-first-unlock protection (`StagingProtection.prepareDirectory`), so a
///   commit in the seconds after the phone locks still works (decision 9).
public actor UbiquityStagingLocator: StagingLocator {
    /// The app's iCloud container.
    public static let containerIdentifier = "iCloud.net.shamil.shutter-bridge"

    private var cached: StagingAvailability?
    /// The `NSUbiquityIdentityDidChange` observer. The locator lives as long as the app; the observer holds it weakly.
    private var observer: (any NSObjectProtocol)?

    public init() {}

    public func locate() async -> StagingAvailability {
        observeIdentityChanges()
        if let cached { return cached }
        let found = Self.find()
        cached = found
        return found
    }

    /// Forgets the cached answer, so the next `locate()` asks iCloud again.
    public func forget() {
        cached = nil
    }

    private func observeIdentityChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil,
                                                          queue: nil) { [weak self] _ in
            guard let self else { return }
            Task { await self.forget() }
        }
    }

    /// Asks iCloud: no account with iCloud Drive on, no container for this app, or the container's Documents folder.
    private static func find() -> StagingAvailability {
        let fm = FileManager.default
        guard fm.ubiquityIdentityToken != nil else { return .unavailable(.iCloudDriveOff) }
        guard let container = fm.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return .unavailable(.containerUnavailable)
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        do {
            try StagingProtection.prepareDirectory(documents)
        } catch {
            return .unavailable(.containerUnavailable)
        }
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
