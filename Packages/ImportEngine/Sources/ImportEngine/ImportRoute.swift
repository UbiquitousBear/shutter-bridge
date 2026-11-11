import PhotosBridge

/// Where a job's files go, and where they go instead if Photos refuses a save mid-import (`PHPhotosErrorDomain` 3311,
/// `accessUserDenied`): then that file and the rest are staged and the Import screen says why (backlog section 5;
/// staging replaced the Files folder, Shamil, 11 Nov). Until the engine's own staging route lands, the staging
/// destination sits in the slot the Files folder had (`filesFolder`), and a staged commit is recorded as the Files
/// folder's was. The caller builds it from the decision `PhotosAccessGate.decision(for:staging:)` gave just before
/// starting (or continuing), which is never `.askForPhotosAccess`: asking is the app's, before the engine is involved.
public struct ImportRoute: Sendable {
    /// What the Import screen shows: Photos, or staging and why. Never `.askForPhotosAccess`.
    public let decision: DestinationDecision
    /// Photos, or the staging folder, as `decision` says.
    public let destination: any ImportDestination
    /// The staging folder: the destination when Photos refuses a save during the import.
    public let filesFolder: any ImportDestination
    /// Where `filesFolder` stages, for the decision after a refused save.
    let stagingPlace: StagingPlace
    /// Reads Photos access without asking, after a save is refused as a denial, so the rest of the import gives the
    /// right reason (`DestinationDecision.afterDeniedSave(authorisation:)`: a restriction gets no Settings link).
    let authorisation: @Sendable () async -> PhotosAuthorisation

    private init(decision: DestinationDecision, destination: any ImportDestination,
                 filesFolder: any ImportDestination, stagingPlace: StagingPlace,
                 authorisation: @escaping @Sendable () async -> PhotosAuthorisation) {
        self.decision = decision
        self.destination = destination
        self.filesFolder = filesFolder
        self.stagingPlace = stagingPlace
        self.authorisation = authorisation
    }

    /// Where staging goes when the caller doesn't say: the app's folder on this iPhone, because no build can use
    /// iCloud Drive until the App ID has iCloud (docs/ci.md). Interim, until the app passes what its staging locator
    /// found with each route.
    public static let defaultStagingPlace = StagingPlace.onThisIPhone(.containerUnavailable)

    /// Into Photos, with the staging folder ready in case Photos refuses a save.
    ///
    /// - Parameters:
    ///   - stagingPlace: Where `filesFolder` stages.
    ///   - authorisation: Reads the `.readWrite` authorisation without asking (the app passes
    ///     `PhotoLibraryClient.authorisation`). Called only after a refused save, to tell a denial from a restriction.
    public static func photos(
        _ photos: any ImportDestination, filesFolder: any ImportDestination,
        stagingPlace: StagingPlace = defaultStagingPlace,
        authorisation: @escaping @Sendable () async -> PhotosAuthorisation
    ) -> ImportRoute {
        ImportRoute(decision: .photos, destination: photos, filesFolder: filesFolder, stagingPlace: stagingPlace,
                    authorisation: authorisation)
    }

    /// Into the staging folder: chosen, or forced because Photos is denied or restricted.
    public static func filesFolder(_ files: any ImportDestination, reason: StagingReason,
                                   place: StagingPlace = defaultStagingPlace) -> ImportRoute {
        ImportRoute(decision: .staging(reason, place), destination: files, filesFolder: files, stagingPlace: place,
                    authorisation: { .denied })
    }

    /// The route `decision` names (from `PhotosAccessGate.decision(for:staging:)` or `DestinationDecision.resolve`).
    ///
    /// - Parameter stagingPlace: Where `filesFolder` stages, for a Photos route's fallback; a staging decision
    ///   carries its own place.
    /// - Throws: `ImportEngineError.photosAccessNotAsked` for `.askForPhotosAccess`: ask for Photos access first
    ///   (the gate does), then build the route from the answer.
    public init(
        _ decision: DestinationDecision, photos: any ImportDestination, filesFolder: any ImportDestination,
        stagingPlace: StagingPlace = defaultStagingPlace,
        authorisation: @escaping @Sendable () async -> PhotosAuthorisation
    ) throws(ImportEngineError) {
        switch decision {
        case .photos:
            self = .photos(photos, filesFolder: filesFolder, stagingPlace: stagingPlace, authorisation: authorisation)
        case let .staging(reason, place): self = .filesFolder(filesFolder, reason: reason, place: place)
        case .askForPhotosAccess: throw .photosAccessNotAsked
        }
    }

    /// The route after Photos refused a save as a denial: the staging folder for this file and the rest, with the
    /// reason from the authorisation read after the refusal.
    func afterDeniedSave(_ authorisation: PhotosAuthorisation) -> ImportRoute {
        ImportRoute(decision: .afterDeniedSave(authorisation: authorisation, staging: stagingPlace),
                    destination: filesFolder, filesFolder: filesFolder, stagingPlace: stagingPlace,
                    authorisation: self.authorisation)
    }
}
