import PhotosBridge

/// Where a job's files go, and where they go instead if Photos refuses a save mid-import (`PHPhotosErrorDomain` 3311,
/// `accessUserDenied`): then that file and the rest go to the Files folder and the Import screen says why (backlog
/// section 5). The caller builds it from the decision `PhotosAccessGate.decision(for:)` gave just before starting
/// (or continuing), which is never `.askForPhotosAccess`: asking is the app's, before the engine is involved.
public struct ImportRoute: Sendable {
    /// What the Import screen shows: Photos, or the Files folder and why. Never `.askForPhotosAccess`.
    public let decision: DestinationDecision
    /// Photos, or the Files folder, as `decision` says.
    public let destination: any ImportDestination
    /// The Files folder: the destination when Photos refuses a save during the import.
    public let filesFolder: any ImportDestination
    /// Reads Photos access without asking, after a save is refused as a denial, so the rest of the import gives the
    /// right reason (`DestinationDecision.afterDeniedSave(authorisation:)`: a restriction gets no Settings link).
    let authorisation: @Sendable () async -> PhotosAuthorisation

    private init(decision: DestinationDecision, destination: any ImportDestination,
                 filesFolder: any ImportDestination,
                 authorisation: @escaping @Sendable () async -> PhotosAuthorisation) {
        self.decision = decision
        self.destination = destination
        self.filesFolder = filesFolder
        self.authorisation = authorisation
    }

    /// Into Photos, with the Files folder ready in case Photos refuses a save.
    ///
    /// - Parameter authorisation: Reads the `.readWrite` authorisation without asking (the app passes
    ///   `PhotoLibraryClient.authorisation`). Called only after a refused save, to tell a denial from a restriction.
    public static func photos(
        _ photos: any ImportDestination, filesFolder: any ImportDestination,
        authorisation: @escaping @Sendable () async -> PhotosAuthorisation
    ) -> ImportRoute {
        ImportRoute(decision: .photos, destination: photos, filesFolder: filesFolder, authorisation: authorisation)
    }

    /// Into the Files folder: chosen in the setting, or forced because Photos is denied or restricted.
    public static func filesFolder(_ files: any ImportDestination, reason: FilesReason) -> ImportRoute {
        ImportRoute(decision: .files(reason), destination: files, filesFolder: files, authorisation: { .denied })
    }

    /// The route `decision` names (from `PhotosAccessGate.decision(for:)` or `DestinationDecision.resolve`).
    ///
    /// - Throws: `ImportEngineError.photosAccessNotAsked` for `.askForPhotosAccess`: ask for Photos access first
    ///   (the gate does), then build the route from the answer.
    public init(
        _ decision: DestinationDecision, photos: any ImportDestination, filesFolder: any ImportDestination,
        authorisation: @escaping @Sendable () async -> PhotosAuthorisation
    ) throws(ImportEngineError) {
        switch decision {
        case .photos: self = .photos(photos, filesFolder: filesFolder, authorisation: authorisation)
        case let .files(reason): self = .filesFolder(filesFolder, reason: reason)
        case .askForPhotosAccess: throw .photosAccessNotAsked
        }
    }

    /// The route after Photos refused a save as a denial: the Files folder for this file and the rest, whatever the
    /// setting, with the reason from the authorisation read after the refusal.
    func afterDeniedSave(_ authorisation: PhotosAuthorisation) -> ImportRoute {
        ImportRoute(decision: .afterDeniedSave(authorisation: authorisation), destination: filesFolder,
                    filesFolder: filesFolder, authorisation: self.authorisation)
    }
}
