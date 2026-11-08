import PhotosBridge

/// Where a job's files go, and where they go instead if Photos refuses a save mid-import (PHPhotosErrorDomain 3311,
/// `accessUserDenied`): then that file and the rest go to the Files folder and the Import screen says why (backlog
/// section 5). The caller builds it from the app-wide destination setting and the Photos access it read just before
/// starting (`PhotosAuthorisation.destination(setting:)`).
public struct ImportRoute: Sendable {
    /// Photos, or the Files folder.
    public let destination: any ImportDestination
    /// The Files folder: the destination when Photos refuses a save during the import.
    public let filesFolder: any ImportDestination
    /// Why `destination` was chosen.
    public let reason: DestinationReason

    private init(destination: any ImportDestination, filesFolder: any ImportDestination, reason: DestinationReason) {
        self.destination = destination
        self.filesFolder = filesFolder
        self.reason = reason
    }

    /// What the Import screen shows: the destination and why.
    public var decision: DestinationDecision { DestinationDecision(kind: destination.kind, reason: reason) }

    /// Into Photos, as the setting says, with the Files folder ready in case Photos refuses a save.
    public static func photos(_ photos: any ImportDestination, filesFolder: any ImportDestination) -> ImportRoute {
        ImportRoute(destination: photos, filesFolder: filesFolder, reason: .chosen)
    }

    /// Into the Files folder: chosen in the setting, or forced because Photos is denied or restricted.
    public static func filesFolder(_ files: any ImportDestination, reason: DestinationReason) -> ImportRoute {
        ImportRoute(destination: files, filesFolder: files, reason: reason)
    }

    /// The route `decision` names (from `PhotosAuthorisation.destination(setting:)`).
    public init(_ decision: DestinationDecision, photos: any ImportDestination, filesFolder: any ImportDestination) {
        switch decision.kind {
        case .photos: self.init(destination: photos, filesFolder: filesFolder, reason: decision.reason)
        case .filesFolder: self.init(destination: filesFolder, filesFolder: filesFolder, reason: decision.reason)
        }
    }
}
