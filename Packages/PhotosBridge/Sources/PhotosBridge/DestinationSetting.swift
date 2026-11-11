import Foundation

/// The remembered choice: what Browse's Import button does by default, *Import to Photos* or *Stage*, default Photos.
///
/// The choice is made at each import (Shamil, 11 Nov): the button offers both, and the last one used becomes its
/// default, app-wide rather than per camera. That replaced the app-wide destination setting of 8 Nov (Photos or
/// Files, chosen in Settings); the stored value is the same one, so what an earlier build stored still reads: Files,
/// which staging replaced, reads as Stage (`DestinationKind`). A plain `Codable` value: the app layer (AppUI)
/// persists it; nothing here touches `UserDefaults`.
public struct DestinationSetting: Sendable, Hashable, Codable {
    /// The choice the Import button offers first. Photos access can still turn *Import to Photos* into staging (see
    /// `DestinationDecision`).
    public var preferred: DestinationKind

    public init(preferred: DestinationKind = .photos) {
        self.preferred = preferred
    }

    /// Photos, as decided.
    public static let `default` = DestinationSetting()

    private enum CodingKeys: String, CodingKey { case preferred }

    /// Lenient: a stored value this build doesn't know (written by a later version, say) reads as the default rather
    /// than failing, so a downgrade can't lose the rest of the app's settings. `"filesFolder"` reads as staging.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferred = (try? container.decodeIfPresent(DestinationKind.self, forKey: .preferred)) ?? .photos
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preferred, forKey: .preferred)
    }
}

/// Why an import is staged, for the Import screen (backlog section 5, *It says so*).
public enum StagingReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The person chose *Stage*. No Settings link.
    case chosen
    /// The person chose *Import to Photos*, but Photos access is denied: *Don't Allow* at the prompt, *None* in
    /// Settings, or a save refused with `PHPhotosErrorDomain` 3311 during the import. Links to the app's page in
    /// Settings.
    case photosDenied
    /// The person chose *Import to Photos*, but Photos access is restricted (parental controls or device management).
    /// No Settings link: the person can't change it there (decision 9, 8 Nov). Untested on a device.
    case photosRestricted

    /// Whether the Import screen offers the button that opens the app's page in Settings: only for a denial.
    public var offersSettingsLink: Bool { self == .photosDenied }

    /// Whether staging was forced by Photos access rather than chosen.
    public var isForced: Bool { self != .chosen }

    /// A default line for the Import screen, in British English. AppUI may word or localise its own; this is so the
    /// reason always has something to show.
    public var explanation: String {
        switch self {
        case .chosen:
            "Staging the originals, as chosen. Nothing is added to Photos."
        case .photosDenied:
            "Photos access is off, so photos are staged instead. Allow access in Settings to import to Photos."
        case .photosRestricted:
            "Photos is restricted on this iPhone, so photos are staged instead."
        }
    }
}

/// Where the next import (or the continuing one) goes, from the choice, the Photos authorisation and where staging
/// can go.
public enum DestinationDecision: Sendable, Hashable {
    /// Import to Photos (full or Limited Access; Limited is not a denial, decision 9).
    case photos
    /// Stage, for this reason, in this place (iCloud Drive, or this iPhone and why).
    case staging(StagingReason, StagingPlace)
    /// The choice is *Import to Photos* and the app hasn't asked yet: ask for `.readWrite` once (iOS shows the prompt
    /// only once), then decide again. `PhotosAccessGate` does both.
    case askForPhotosAccess

    /// The rule (backlog section 5, *Trigger* and *It says so*; decision 9 as decided on 7 and 8 Nov; Shamil, 11 Nov):
    /// - *Stage* → staging, chosen, whatever the authorisation (never asks for Photos access, and never offers the
    ///   Settings link: granting access wouldn't send anything to Photos);
    /// - *Import to Photos* with access denied or restricted → staging, forced, with the reason;
    /// - *Import to Photos* with limited or full access → Photos; not determined → ask first.
    ///
    /// - Parameter staging: Where staging goes now (`StagingAvailability.place`, read by the caller beforehand):
    ///   iCloud Drive, or this iPhone and why.
    public static func resolve(choice: DestinationKind, authorisation: PhotosAuthorisation,
                               staging: StagingPlace) -> DestinationDecision {
        switch choice {
        case .staging:
            return .staging(.chosen, staging)
        case .photos:
            switch authorisation {
            case .denied: return .staging(.photosDenied, staging)
            case .restricted: return .staging(.photosRestricted, staging)
            case .notDetermined: return .askForPhotosAccess
            case .limited, .authorised: return .photos
            }
        }
    }

    /// After a save failed as a denial (`ImportDestinationFailure.photosAccessDenied`) during an import: that file
    /// and the rest are staged, in `staging`. The reason comes from the authorisation read after the failure, so a
    /// restriction (`PHPhotosErrorDomain` 3310, or `.restricted`) gets no Settings link.
    public static func afterDeniedSave(authorisation: PhotosAuthorisation,
                                       staging: StagingPlace) -> DestinationDecision {
        .staging(authorisation == .restricted ? .photosRestricted : .photosDenied, staging)
    }

    /// The destination, or nil while access still has to be asked for.
    public var kind: DestinationKind? {
        switch self {
        case .photos: .photos
        case .staging: .staging
        case .askForPhotosAccess: nil
        }
    }

    /// Why the import is staged, when it is.
    public var stagingReason: StagingReason? {
        if case let .staging(reason, _) = self { reason } else { nil }
    }

    /// Where the import is staged, when it is.
    public var stagingPlace: StagingPlace? {
        if case let .staging(_, place) = self { place } else { nil }
    }

    /// The same decision staged in `place` instead, for an import that keeps staging after iCloud Drive went away
    /// mid-job; Photos and asking are returned unchanged.
    public func staged(in place: StagingPlace) -> DestinationDecision {
        if case let .staging(reason, _) = self { .staging(reason, place) } else { self }
    }
}
