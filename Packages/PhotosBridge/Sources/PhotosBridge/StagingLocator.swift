import Foundation

// Where staging goes (Shamil, 11 Nov): the app's iCloud Drive folder when iCloud Drive is available, otherwise the
// app's folder on this iPhone, and the app says so. The rule and the values are pure Foundation, tested on Linux; the
// iCloud side (`UbiquityStagingLocator`, `UbiquitousFileMover`) is in `UbiquityStaging.swift`, iOS only.

/// Why staging goes to this iPhone rather than iCloud Drive.
public enum StagingFallbackReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// No iCloud account with iCloud Drive on: signed out of iCloud, or iCloud Drive turned off.
    case iCloudDriveOff
    /// Signed in with iCloud Drive on, but the app's iCloud Drive folder isn't available: the app's switch under
    /// iCloud Drive is off, or this build can't use iCloud Drive yet (the App ID doesn't have iCloud until the
    /// owner's portal step, so no build signs with the entitlement before it; docs/ci.md).
    case containerUnavailable
    /// iCloud Drive went away during the import (signed out, or turned off, mid-job): the rest is staged on this
    /// iPhone.
    case lostDuringImport

    /// A default line for Settings and the Import screen, in British English; AppUI may word its own.
    public var explanation: String {
        switch self {
        case .iCloudDriveOff:
            "iCloud Drive is off or you're not signed in to iCloud, so staging is on this iPhone."
        case .containerUnavailable:
            "iCloud Drive isn't available to Shutter Bridge, so staging is on this iPhone."
        case .lostDuringImport:
            "iCloud Drive became unavailable, so the rest are staged on this iPhone."
        }
    }
}

/// Where staged files go.
public enum StagingPlace: Sendable, Hashable {
    /// iCloud Drive › Shutter Bridge › Staging: the Documents folder of the app's iCloud container
    /// (`UbiquityStagingLocator.containerIdentifier`).
    case iCloudDrive
    /// On My iPhone › Shutter Bridge › Staging: the app's own Documents folder, which Files shows (the Info.plist sets
    /// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`), for this reason.
    case onThisIPhone(StagingFallbackReason)

    /// The staging folder as Files names it, in British English.
    public var folderPath: String {
        switch self {
        case .iCloudDrive: "iCloud Drive › Shutter Bridge › Staging"
        case .onThisIPhone: "On My iPhone › Shutter Bridge › Staging"
        }
    }

    /// Why staging isn't in iCloud Drive, when it isn't.
    public var fallbackReason: StagingFallbackReason? {
        if case let .onThisIPhone(reason) = self { reason } else { nil }
    }
}

/// What a `StagingLocator` found.
public enum StagingAvailability: Sendable, Hashable {
    /// iCloud Drive is available: `documents` is the Documents folder of the app's iCloud container, the staging
    /// root (`StagingFolderDestination.root`).
    case iCloudDrive(documents: URL)
    /// iCloud Drive isn't available, for this reason: staging goes to the app's own Documents folder.
    case unavailable(StagingFallbackReason)

    /// Where staging goes.
    public var place: StagingPlace {
        switch self {
        case .iCloudDrive: .iCloudDrive
        case let .unavailable(reason): .onThisIPhone(reason)
        }
    }

    /// The iCloud staging root, when iCloud Drive is available.
    public var iCloudDocuments: URL? {
        if case let .iCloudDrive(documents) = self { documents } else { nil }
    }
}

/// Finds out whether staging can go to iCloud Drive. The app reads it before each import and before a continue, and
/// Settings reads it to show where staging goes. `UbiquityStagingLocator` on iOS; `FakeStagingLocator` in tests.
public protocol StagingLocator: Sendable {
    func locate() async -> StagingAvailability
}

/// A `StagingLocator` that answers what it was given, for tests and previews on any platform.
public actor FakeStagingLocator: StagingLocator {
    public private(set) var availability: StagingAvailability
    /// How many times `locate()` was called.
    public private(set) var locateCount = 0

    public init(_ availability: StagingAvailability) {
        self.availability = availability
    }

    public func set(_ availability: StagingAvailability) {
        self.availability = availability
    }

    public func locate() -> StagingAvailability {
        locateCount += 1
        return availability
    }
}
