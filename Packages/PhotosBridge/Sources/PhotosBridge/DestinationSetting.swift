import Foundation

/// The app-wide destination setting (Shamil, 8 Nov, their own choice (b)): Photos or Files, default Photos. Not per
/// camera or per import. A plain `Codable` value: the app layer (AppUI) persists it; nothing here touches
/// `UserDefaults`.
public struct DestinationSetting: Sendable, Hashable, Codable {
    /// Where the person wants imports to go. Photos access can still force Files (see `DestinationDecision`).
    public var preferred: DestinationKind

    public init(preferred: DestinationKind = .photos) {
        self.preferred = preferred
    }

    /// Photos, as decided.
    public static let `default` = DestinationSetting()

    private enum CodingKeys: String, CodingKey { case preferred }

    /// Lenient: a stored value this build doesn't know (written by a later version, say) reads as the default rather
    /// than failing, so a downgrade can't lose the rest of the app's settings.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferred = (try? container.decodeIfPresent(DestinationKind.self, forKey: .preferred)) ?? .photos
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preferred, forKey: .preferred)
    }
}

/// Why an import goes to Files, for the Import screen (backlog section 5, *It says so*).
public enum FilesReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The destination setting says Files. No Settings link.
    case chosen
    /// Photos access is denied: *Don't Allow* at the prompt, *None* in Settings, or a save refused with
    /// `PHPhotosErrorDomain` 3311 during the import. Links to the app's page in Settings.
    case photosDenied
    /// Photos access is restricted (parental controls or device management). No Settings link: the person can't
    /// change it there (decision 9, 8 Nov). Untested on a device.
    case photosRestricted

    /// Whether the Import screen offers the button that opens the app's page in Settings: only for a denial.
    public var offersSettingsLink: Bool { self == .photosDenied }

    /// Whether Files was forced by Photos access rather than chosen.
    public var isForced: Bool { self != .chosen }

    /// A default line for the Import screen, in British English. AppUI may word or localise its own; this is so the
    /// reason always has something to show.
    public var explanation: String {
        switch self {
        case .chosen:
            "Importing to Files, as set in Settings."
        case .photosDenied:
            "Photos access is off, so photos are imported to Files. Allow access in Settings to import to Photos."
        case .photosRestricted:
            "Photos is restricted on this iPhone, so photos are imported to Files."
        }
    }
}

/// Where the next import (or the continuing one) goes, from the setting and the Photos authorisation.
public enum DestinationDecision: Sendable, Hashable {
    /// Import to Photos (full or Limited Access; Limited is not a denial, decision 9).
    case photos
    /// Import to the Files folder, for this reason.
    case files(FilesReason)
    /// The setting says Photos and the app hasn't asked yet: ask for `.readWrite` once (iOS shows the prompt only
    /// once), then decide again. `PhotosAccessGate` does both.
    case askForPhotosAccess

    /// The rule (backlog section 5, *Trigger* and *It says so*; decision 9 as decided on 7 and 8 Nov):
    /// - the setting says Files → Files, chosen, whatever the authorisation (never asks for Photos access, and never
    ///   offers the Settings link: granting access wouldn't send anything to Photos);
    /// - otherwise denied or restricted → Files, forced, with the reason;
    /// - otherwise limited or full access → Photos; not determined → ask first.
    public static func resolve(setting: DestinationSetting, authorisation: PhotosAuthorisation) -> DestinationDecision {
        if setting.preferred == .filesFolder { return .files(.chosen) }
        switch authorisation {
        case .denied: return .files(.photosDenied)
        case .restricted: return .files(.photosRestricted)
        case .notDetermined: return .askForPhotosAccess
        case .limited, .authorised: return .photos
        }
    }

    /// After a save failed as a denial (`ImportDestinationFailure.photosAccessDenied`) during an import: that file
    /// and the rest go to Files whatever the setting says. The reason comes from the authorisation read after the
    /// failure, so a restriction (`PHPhotosErrorDomain` 3310, or `.restricted`) gets no Settings link.
    public static func afterDeniedSave(authorisation: PhotosAuthorisation) -> DestinationDecision {
        authorisation == .restricted ? .files(.photosRestricted) : .files(.photosDenied)
    }

    /// The destination, or nil while access still has to be asked for.
    public var kind: DestinationKind? {
        switch self {
        case .photos: .photos
        case .files: .filesFolder
        case .askForPhotosAccess: nil
        }
    }

    /// The reason for Files, when the decision is Files.
    public var filesReason: FilesReason? {
        if case let .files(reason) = self { reason } else { nil }
    }
}
