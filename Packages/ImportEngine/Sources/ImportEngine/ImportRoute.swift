import PhotosBridge

/// Where a job's files go, and where they go instead when the destination can't take them mid-import.
///
/// The choice is made at each import (Shamil, 11 Nov): *Import to Photos* or *Stage*, which copies the camera's
/// originals into the staging folder (iCloud Drive › Shutter Bridge › Staging, or On My iPhone › Shutter Bridge ›
/// Staging when iCloud Drive isn't available). Staging replaced the Files folder. Two switches can happen during a
/// job, each once, and the Import screen says why:
/// - Photos refuses a save (`PHPhotosErrorDomain` 3311, `accessUserDenied`): that file and the rest are staged
///   (backlog section 5), as the Files folder took them before 11 Nov;
/// - iCloud Drive goes away while staging there (`ImportDestinationFailure.stagingUnavailable`): that file and the
///   rest are staged on this iPhone (`StagingFallbackReason.lostDuringImport`).
///
/// The caller builds it from the decision `PhotosAccessGate.decision(for:staging:)` gave just before starting (or
/// continuing), which is never `.askForPhotosAccess`: asking is the app's, before the engine is involved.
///
/// **The job's purpose comes from its route** (`purpose`): a staging decision makes a stage job, which leaves out
/// what is already staged; a Photos decision an import job, which leaves out what is already imported and ignores
/// staging. A stage job never becomes an import job (`ImportEngine.change(_:to:)`).
///
/// **A keepers route (`keepers(_:authorisation:)`) has no fallback** (backlog section 7.5): *Import keepers* reads its
/// files from Staging, so a Photos refusal (3311) can't stage them again; the engine ends the job with a Photos-access
/// stop instead (`JobOutcome.photosAccessNeeded`), and nothing goes to Staging.
public struct ImportRoute: Sendable {
    /// What the Import screen shows: Photos, or staging, where and why. Never `.askForPhotosAccess`.
    public let decision: DestinationDecision
    /// Photos, or the staging folder, as `decision` says.
    public let destination: any ImportDestination
    /// The staging folder in `stagingPlace`: the destination of a staging route, and of a Photos route once Photos
    /// refuses a save.
    public let staging: any ImportDestination
    /// The staging folder on this iPhone, where staging goes once iCloud Drive is lost mid-job. The same folder as
    /// `staging` when that is on this iPhone already.
    public let stagingOnThisIPhone: any ImportDestination
    /// Where `staging` stages.
    public let stagingPlace: StagingPlace
    /// Reads Photos access without asking, after a save is refused as a denial, so the rest of the import gives the
    /// right reason (`DestinationDecision.afterDeniedSave(authorisation:staging:)`: a restriction gets no Settings
    /// link).
    let authorisation: @Sendable () async -> PhotosAuthorisation
    /// Whether Photos refusing a save (3311) sends that file and the rest to `staging`: true for every route but a
    /// keepers job's (`keepers(_:authorisation:)`), whose files are in Staging already.
    public let fallsBackToStaging: Bool

    private init(decision: DestinationDecision, destination: any ImportDestination, staging: any ImportDestination,
                 stagingOnThisIPhone: any ImportDestination, stagingPlace: StagingPlace,
                 authorisation: @escaping @Sendable () async -> PhotosAuthorisation, fallsBackToStaging: Bool = true) {
        self.decision = decision
        self.destination = destination
        self.staging = staging
        self.stagingOnThisIPhone = stagingOnThisIPhone
        self.stagingPlace = stagingPlace
        self.authorisation = authorisation
        self.fallsBackToStaging = fallsBackToStaging
    }

    /// *Import keepers* (backlog section 7.5): into Photos with **no fallback**. The files come from Staging, so a save
    /// Photos refuses (3311) ends the job with a Photos-access stop (`JobOutcome.photosAccessNeeded`) rather than
    /// staging the rest again; its staging folders refuse anything handed to them (`NoFallbackDestination`), so nothing
    /// can reach Staging through this route. The job's record says `keepers` (`isKeepers`).
    ///
    /// - Parameter authorisation: Reads the `.readWrite` authorisation without asking, after a refused save, so the
    ///   stop says whether Settings can change it (a restriction can't).
    public static func keepers(
        _ photos: any ImportDestination, authorisation: @escaping @Sendable () async -> PhotosAuthorisation
    ) -> ImportRoute {
        let none = NoFallbackDestination()
        return ImportRoute(decision: .photos, destination: photos, staging: none, stagingOnThisIPhone: none,
                           stagingPlace: .onThisIPhone(.containerUnavailable), authorisation: authorisation,
                           fallsBackToStaging: false)
    }

    /// A keepers job's route (`keepers(_:authorisation:)`): Photos with no fallback.
    public var isKeepers: Bool { !fallsBackToStaging }

    /// Into Photos, with the staging folder ready in case Photos refuses a save.
    ///
    /// - Parameters:
    ///   - staging: The staging folder in `stagingPlace`.
    ///   - onThisIPhone: The staging folder on this iPhone (the same as `staging` when `stagingPlace` is on this
    ///     iPhone).
    ///   - stagingPlace: Where `staging` stages, as the app's staging locator found it just before.
    ///   - authorisation: Reads the `.readWrite` authorisation without asking (the app passes
    ///     `PhotoLibraryClient.authorisation`). Called only after a refused save, to tell a denial from a restriction.
    public static func photos(
        _ photos: any ImportDestination, staging: any ImportDestination, onThisIPhone: any ImportDestination,
        stagingPlace: StagingPlace, authorisation: @escaping @Sendable () async -> PhotosAuthorisation
    ) -> ImportRoute {
        ImportRoute(decision: .photos, destination: photos, staging: staging, stagingOnThisIPhone: onThisIPhone,
                    stagingPlace: stagingPlace, authorisation: authorisation)
    }

    /// Into the staging folder in `place`: chosen (*Stage*), or forced because Photos is denied or restricted.
    ///
    /// - Parameter onThisIPhone: The staging folder on this iPhone, for when iCloud Drive is lost mid-job (the same
    ///   as `staging` when `place` is on this iPhone).
    public static func staging(_ staging: any ImportDestination, reason: StagingReason, place: StagingPlace,
                               onThisIPhone: any ImportDestination) -> ImportRoute {
        ImportRoute(decision: .staging(reason, place), destination: staging, staging: staging,
                    stagingOnThisIPhone: onThisIPhone, stagingPlace: place, authorisation: { .denied })
    }

    /// The route `decision` names (from `PhotosAccessGate.decision(for:staging:)` or `DestinationDecision.resolve`).
    ///
    /// - Parameters:
    ///   - staging: The staging folder in `stagingPlace`.
    ///   - onThisIPhone: The staging folder on this iPhone.
    ///   - stagingPlace: Where `staging` stages. A staging decision carries its own place, which wins.
    /// - Throws: `ImportEngineError.photosAccessNotAsked` for `.askForPhotosAccess`: ask for Photos access first
    ///   (the gate does), then build the route from the answer.
    public init(
        _ decision: DestinationDecision, photos: any ImportDestination, staging: any ImportDestination,
        onThisIPhone: any ImportDestination, stagingPlace: StagingPlace,
        authorisation: @escaping @Sendable () async -> PhotosAuthorisation
    ) throws(ImportEngineError) {
        switch decision {
        case .photos:
            self = .photos(photos, staging: staging, onThisIPhone: onThisIPhone, stagingPlace: stagingPlace,
                           authorisation: authorisation)
        case let .staging(reason, place):
            self = .staging(staging, reason: reason, place: place, onThisIPhone: onThisIPhone)
        case .askForPhotosAccess: throw .photosAccessNotAsked
        }
    }

    /// What a job on this route is for: `.staging` (a stage job) or `.photos` (an import job).
    public var purpose: DestinationKind { decision.kind ?? .photos }

    /// The route after Photos refused a save as a denial: the staging folder for this file and the rest, with the
    /// reason from the authorisation read after the refusal.
    func afterDeniedSave(_ authorisation: PhotosAuthorisation) -> ImportRoute {
        ImportRoute(decision: .afterDeniedSave(authorisation: authorisation, staging: stagingPlace),
                    destination: staging, staging: staging, stagingOnThisIPhone: stagingOnThisIPhone,
                    stagingPlace: stagingPlace, authorisation: self.authorisation)
    }

    /// Whether staging is in iCloud Drive, so losing it mid-job has somewhere to switch to.
    var stagesInICloudDrive: Bool { stagingPlace == .iCloudDrive }

    /// The route after iCloud Drive went away mid-job: staging on this iPhone, saying so
    /// (`StagingFallbackReason.lostDuringImport`), for this file and the rest. A Photos route keeps going to Photos
    /// with its fallback moved to this iPhone.
    func afterStagingLost() -> ImportRoute {
        let place = StagingPlace.onThisIPhone(.lostDuringImport)
        let decision = decision.staged(in: place)
        let destination = decision.kind == .staging ? stagingOnThisIPhone : destination
        return ImportRoute(decision: decision, destination: destination, staging: stagingOnThisIPhone,
                           stagingOnThisIPhone: stagingOnThisIPhone, stagingPlace: place,
                           authorisation: authorisation)
    }

    /// Whether a running job on this route may take `next` (on a continue or a reconnect): a stage job never becomes
    /// an import job (the choice is made at each import, Shamil, 11 Nov; as a Files job never moved to Photos, 8
    /// Nov), and staging on this iPhone never moves to iCloud Drive mid-job, so one job's staged files never come
    /// back from this iPhone to iCloud Drive half-way. An import job may be staged instead (Photos access was turned
    /// off meanwhile), and staging may move from iCloud Drive to this iPhone.
    func mayChange(to next: ImportRoute) -> Bool {
        // A keepers job takes only another keepers route (it is never staged), and no other job becomes one.
        if fallsBackToStaging != next.fallsBackToStaging { return false }
        if purpose == .staging && next.purpose == .photos { return false }
        if !stagesInICloudDrive && next.stagesInICloudDrive { return false }
        return true
    }
}

/// The staging folders of a keepers route (`ImportRoute.keepers(_:authorisation:)`), which has none: every commit is
/// refused, so nothing a keepers job holds can be staged even if a path the engine takes reached for its fallback.
struct NoFallbackDestination: ImportDestination {
    var kind: DestinationKind { .staging }

    func commit(_ unit: CommitUnit) async throws(ImportDestinationFailure) -> ImportResult {
        throw .rejected(detail: "a keepers job has no staging fallback")
    }

    func commitTarget(for unit: CommitUnit) -> CommitTarget {
        .stagingFolder(place: .onThisIPhone(.containerUnavailable), folderPath: "")
    }
}
