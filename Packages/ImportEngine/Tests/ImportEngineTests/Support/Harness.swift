import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge

/// One engine on a manual clock, with a trace recorder, a Photos fake and two staging fakes (on this iPhone and in
/// iCloud Drive), in a temporary folder of its own. Nothing in it waits on the wall clock: `advance(by:)` moves the clock and waits for the engine's tick.
final class Harness {
    static let t0 = Date(timeIntervalSince1970: 1_793_000_000) // 26 Oct 2026, 07:33:20 UTC
    /// Where the harness's routes stage unless a test says otherwise: this iPhone, as every build stages until the
    /// App ID has iCloud.
    static let onThisIPhone = StagingPlace.onThisIPhone(.containerUnavailable)

    let root: URL
    let staging: URL
    let filesDirectory: URL
    let zone = TimeZone(identifier: "UTC")!
    let camera = CameraKey(rawValue: "test-camera")
    let clock = ManualClock()
    let trace = TraceRecorder()
    let catalogue: any CatalogueStore
    let photos: FakeDestination
    /// The staging folder on this iPhone.
    let files: FakeDestination
    /// The staging folder in iCloud Drive.
    let iCloud: FakeDestination
    /// The Photos access the Photos route reads after a refused save; full access unless a test changes it.
    let photosAccess = FakePhotosAccess()
    let engine: ImportEngine
    private var links: [FakeCameraLink] = []
    private var resumingLinks: [ResumingLink] = []

    init(catalogue: any CatalogueStore = InMemoryCatalogue(), downloadsInFlight: Int = 1,
         policy: ImportPolicy = .standard, root existing: URL? = nil) {
        root = existing ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportEngineTests-\(UUID().uuidString)", isDirectory: true)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        filesDirectory = root.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        self.catalogue = catalogue
        photos = FakeDestination(kind: .photos, folder: root.appendingPathComponent("photos", isDirectory: true))
        files = FakeDestination(kind: .staging, folder: filesDirectory)
        iCloud = FakeDestination(kind: .staging, folder: root.appendingPathComponent("icloud", isDirectory: true),
                                 place: .iCloudDrive)
        let recorder = trace
        engine = ImportEngine(
            catalogue: catalogue, settings: ImportSettings(downloadsInFlight: downloadsInFlight),
            stagingDirectory: staging, clock: clock, timeZone: zone, policy: policy,
            trace: { recorder.record($0) }
        )
    }

    var photosRoute: ImportRoute { photosRoute(to: photos) }

    /// Into `destination` as Photos, with this harness's staging folder on this iPhone and Photos access.
    func photosRoute(to destination: any ImportDestination) -> ImportRoute {
        .photos(destination, staging: files, onThisIPhone: files, stagingPlace: Harness.onThisIPhone,
                authorisation: photosAccess.read)
    }

    /// Into Photos, with staging in iCloud Drive (and on this iPhone once iCloud Drive is lost).
    var photosRouteStagingInICloud: ImportRoute {
        .photos(photos, staging: iCloud, onThisIPhone: files, stagingPlace: .iCloudDrive,
                authorisation: photosAccess.read)
    }

    /// *Stage*, on this iPhone.
    var stageRoute: ImportRoute { stageRoute(reason: .chosen) }

    func stageRoute(reason: StagingReason) -> ImportRoute {
        .staging(files, reason: reason, place: Harness.onThisIPhone, onThisIPhone: files)
    }

    /// *Stage*, in iCloud Drive, with this iPhone for when iCloud Drive is lost.
    var stageRouteInICloud: ImportRoute {
        .staging(iCloud, reason: .chosen, place: .iCloudDrive, onThisIPhone: files)
    }

    func route(_ kind: DestinationKind) -> ImportRoute { kind == .photos ? photosRoute : stageRoute }

    /// A file on the card, its handle `"<prefix>-<name>"`.
    func item(_ name: String, size: UInt64, prefix: String = "s1", date: Date? = Harness.t0,
              folder: String = "DCIM/100MSDCF") -> CameraItem {
        CameraItem(id: .init(rawValue: "\(prefix)-\(name)"), folder: folder, name: name, size: size, captureDate: date)
    }

    /// RAW+JPEG frames DSC00001…, frame i taken at t0 + i s; ARW about 4 KB and JPG about 2 KB.
    func card(frames: Int, prefix: String = "s1") -> [CameraItem] {
        (1 ... max(1, frames)).flatMap { i -> [CameraItem] in
            let stem = "DSC" + String(repeating: "0", count: 5 - String(i).count) + String(i)
            let date = Harness.t0.addingTimeInterval(TimeInterval(i))
            return [item(stem + ".ARW", size: 4000 + UInt64(i) * 16, prefix: prefix, date: date),
                    item(stem + ".JPG", size: 2000 + UInt64(i) * 16, prefix: prefix, date: date)]
        }
    }

    /// Single JPEGs with the given names, newest last, each 3000 B unless sized.
    func singles(_ names: [String], prefix: String = "s1", sizes: [UInt64]? = nil) -> [CameraItem] {
        names.enumerated().map { i, name in
            item(name, size: sizes?[i] ?? 3000, prefix: prefix, date: Harness.t0.addingTimeInterval(TimeInterval(i)))
        }
    }

    func identity(of item: CameraItem) -> ObjectIdentity { item.identity(camera: camera, timeZone: zone)! }

    func link(_ card: [CameraItem], mode: CameraMode = .usb(.massStorage)) -> FakeCameraLink {
        let l = FakeCameraLink(card: card, mode: mode)
        links.append(l)
        return l
    }

    /// A link that resumes (`CameraLinkCapabilities.wifi` unless given), shut down by `cleanup()`.
    func resumingLink(_ card: [CameraItem], chunk: UInt64 = 300,
                      capabilities: CameraLinkCapabilities = .wifi) -> ResumingLink {
        let l = ResumingLink(card: card, chunk: chunk, capabilities: capabilities)
        resumingLinks.append(l)
        return l
    }

    @discardableResult
    func start(_ selection: ImportSelection, from link: any CameraLink,
               to route: ImportRoute? = nil) async throws -> ImportJobID {
        try await engine.start(selection, from: link, camera: camera, to: route ?? photosRoute)
    }

    /// Moves the clock and waits for the engine's tick at the new time. Needs a running ticker (a job, or progress
    /// waiting to go out) and at least the progress interval, so a tick is due.
    func advance(by duration: Duration) async {
        precondition(duration >= ImportPolicy.standard.progressInterval)
        let mark = trace.count
        let target = clock.now.offset + duration
        clock.advance(by: duration)
        await trace.wait(from: mark) { if case let .tick(t) = $0 { t >= target } else { false } }
    }

    /// The outcome of the first job to finish at or after trace index `mark`.
    func waitFinished(after mark: Int = 0) async -> JobOutcome {
        let event = await trace.wait(from: mark) { if case .finished = $0 { true } else { false } }
        guard case let .finished(outcome) = event else { fatalError("unreachable") }
        return outcome
    }

    /// Regular files anywhere under `url`.
    func regularFiles(under url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        else { return 0 }
        var n = 0
        for case let file as URL in e where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?
            .isRegularFile == true {
            n += 1
        }
        return n
    }

    var stagedFiles: Int { regularFiles(under: staging) }

    func records() async -> [CatalogueRecord] {
        if let c = catalogue as? InMemoryCatalogue { return await c.allRecords }
        if let c = catalogue as? FailingCatalogue { return await c.allRecords }
        return []
    }

    func record(for item: CameraItem) async -> CatalogueRecord? {
        try? await catalogue.record(for: identity(of: item))
    }

    func outcome(of item: CameraItem) async -> FileOutcome? { await engine.outcomes()[identity(of: item)] }

    func cleanup() async {
        await engine.cancel()
        for l in links { await l.shutdown() }
        for l in resumingLinks { await l.shutdown() }
        try? FileManager.default.removeItem(at: root)
    }
}

extension EngineTrace {
    var isPublished: Bool { if case .published = self { true } else { false } }
    var isResumed: Bool { self == .resumed }
    var isDestinationChanged: Bool { if case .destinationChanged = self { true } else { false } }

    static func isRetrying(_ name: String, _ retry: Int) -> @Sendable (EngineTrace) -> Bool {
        { if case let .retrying(n, r, _) = $0 { n == name && r == retry } else { false } }
    }
}
