import CameraTransport
import Catalogue
import Foundation
import Observation
import PhotosBridge

/// One capture day of one camera on the Staging screen, newest day first under its camera: the units the loupe
/// swipes through, in shooting order.
///
/// A camera is its **display name** as Staging's folders are named (D11): the folder under Staging that the staged
/// copies are in. So one camera's files staged in Image Transfer (MSC) and in MTP, which have two catalogue keys, are
/// one camera here, as they are one folder in Files.
public struct CullDayRow: Sendable, Hashable, Identifiable {
    public struct ID: Sendable, Hashable {
        public var camera: String
        /// `YYYYMMDD`, the camera's wall-clock day.
        public var day: String
    }

    public var cameraName: String
    /// `YYYYMMDD`, the camera's wall-clock day.
    public var day: String
    public var units: [CullUnit]

    public var id: ID { ID(camera: cameraName, day: day) }
}

/// One camera's days on the Staging screen.
public struct CullCameraSection: Sendable, Hashable, Identifiable {
    public var name: String
    /// Newest day first.
    public var days: [CullDayRow]

    public var id: String { name }
}

/// Staged files the Staging screen can't show, counted in files, so it says how many and why rather than leaving them
/// out silently.
public struct StagedUnavailable: Sendable, Hashable {
    /// Staged in iCloud Drive, which isn't available now (signed out, or this build has no iCloud yet).
    public var inICloudDrive = 0
    /// The copy isn't where the catalogue says (removed or replaced in Files).
    public var gone = 0
    /// The catalogue doesn't know where the copy is (an empty or out-of-Staging path, which is never resolved).
    public var unknownPlace = 0

    public init(inICloudDrive: Int = 0, gone: Int = 0, unknownPlace: Int = 0) {
        self.inICloudDrive = inICloudDrive
        self.gone = gone
        self.unknownPlace = unknownPlace
    }

    public var total: Int { inICloudDrive + gone + unknownPlace }
}

/// The cull session's marks saved in the catalogue (I7's `CullMark` rows): one call per unit, with both halves of a
/// pair together (D4). An unmarked mark clears them. Marks never touch the card or the staged file.
public struct CatalogueMarkWriter: CullMarkWriting {
    private let catalogue: any CatalogueStore
    private let now: @Sendable () -> Date

    public init(catalogue: any CatalogueStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalogue = catalogue
        self.now = now
    }

    public func write(_ mark: CullMark, for keys: [ObjectIdentity.ContentKey]) async throws {
        guard !mark.isUnmarked else {
            try await catalogue.clearMarks(of: keys)
            return
        }
        try await catalogue.setMark(Self.stored(mark.decision), rating: mark.rating, for: keys, at: now())
    }

    static func stored(_ decision: CullDecision?) -> MarkRecord.Decision? {
        switch decision {
        case .keep?: .keep
        case .reject?: .reject
        case nil: nil
        }
    }

    static func shown(_ decision: MarkRecord.Decision?) -> CullDecision? {
        switch decision {
        case .keep?: .keep
        case .reject?: .reject
        case nil: nil
        }
    }

    /// The session's mark for a stored one.
    static func mark(_ record: MarkRecord) -> CullMark {
        CullMark(decision: shown(record.decision), rating: record.rating)
    }
}

/// The Staging screen's model (backlog section 7.3; D5: culling of staged files only, in their own screen): the staged
/// files from the catalogue (`stagedRecords(camera: nil)`, no camera needed) by camera and capture day with their
/// counts, and the loupe over one day.
///
/// - **Files** are the staged copies, each resolved only with `StagedLocation.fileURL(in:)` under its root's Documents
///   folder: the app's own (On My iPhone) or the iCloud container's, as the staging locator finds it. A copy with an
///   unknown path, in iCloud Drive while it isn't available, or no longer in Staging (`StagedFileReading.presence`)
///   isn't shown, and `unavailable` counts it.
/// - **Marks** are the catalogue's, one per unit (D4), saved at once through `CatalogueMarkWriter`; a reject stays a
///   reject (D3): nothing here clears a mark but the person.
/// - **The loupe** (`CullLoupe`) is a `CullSession` over the day's units with a `PreviewPrefetcher` following it. The day's
///   counts follow its marks while it is open; when it closes its saves are waited for and the marks read back.
///
/// Pure logic on the main actor, so it runs on Linux against `InMemoryCatalogue` and a fake preview loader; the screens
/// (`CullScreen`, `LoupeView`) are compiled only by CI.
@MainActor
@Observable
public final class CullModel<Image: Sendable> {
    public enum Phase: Sendable, Hashable {
        case loading
        case loaded
        case failed
    }

    public private(set) var phase: Phase = .loading
    public private(set) var sections: [CullCameraSection] = []
    public private(set) var unavailable = StagedUnavailable()
    /// The loupe while it is open.
    public private(set) var loupe: CullLoupe<Image>?
    /// The catalogue's marks of the files shown, by content key, as last read or written.
    public private(set) var marks: [ObjectIdentity.ContentKey: CullMark] = [:]
    /// The last load's failure has been closed by the person.
    private var loadFailureDismissed = false

    @ObservationIgnored private let catalogue: any CatalogueStore
    @ObservationIgnored private let onThisIPhone: URL
    @ObservationIgnored private let locator: any StagingLocator
    @ObservationIgnored private let reader: any StagedFileReading
    @ObservationIgnored private let loader: any PreviewLoading<Image>
    @ObservationIgnored private let files: any StagedFileAvailability
    @ObservationIgnored private let exif: (@Sendable (URL) async -> EXIFSummary?)?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let policy: PrefetchPolicy
    @ObservationIgnored private let writer: CatalogueMarkWriter
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private var loadGeneration = 0

    /// - Parameters:
    ///   - onThisIPhone: The app's Documents folder, the root of On My iPhone › Shutter Bridge › Staging.
    ///   - locator: Finds the iCloud container's Documents folder, the root of iCloud Drive › Shutter Bridge › Staging.
    ///   - reader: Tells whether a staged copy is still there (`StagedFileReaders.platform` in the app; an evicted iCloud
    ///     file counts as there).
    ///   - loader: Decodes previews (`ImageIOPreviewLoader` in the app).
    ///   - files: Whether a staged file is on the phone, and gets an evicted one (`UbiquitousFileAvailability` on iPhone).
    ///   - exif: Reads the loupe's EXIF line from a file (`EXIFSummary.read(from:)` in the app); nil for none.
    public init(catalogue: any CatalogueStore, onThisIPhone: URL, locator: any StagingLocator,
                reader: any StagedFileReading = StagedFileReaders.platform, loader: any PreviewLoading<Image>,
                files: any StagedFileAvailability = AlwaysLocalFiles(),
                exif: (@Sendable (URL) async -> EXIFSummary?)? = nil,
                clock: any Clock<Duration> = ContinuousClock(), policy: PrefetchPolicy = PrefetchPolicy(),
                now: @escaping @Sendable () -> Date = { Date() }, log: any BenchLog = SilentBenchLog()) {
        self.catalogue = catalogue
        self.onThisIPhone = onThisIPhone
        self.locator = locator
        self.reader = reader
        self.loader = loader
        self.files = files
        self.exif = exif
        self.clock = clock
        self.policy = policy
        self.writer = CatalogueMarkWriter(catalogue: catalogue, now: now)
        self.log = log
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// A refresh that failed over a list already shown, which stays as it was: said in a strip until closed. (With
    /// nothing listed, the screen shows the failure in place of the list instead.)
    public var loadFailureNotice: StatusNotice? {
        guard phase == .failed, !isEmpty, !loadFailureDismissed else { return nil }
        return StatusNotice(text: CullWording.refreshFailed, tone: .problem, systemImage: "exclamationmark.triangle",
                            dismissesItself: false)
    }

    public func dismissLoadFailure() { loadFailureDismissed = true }

    /// Every day row, camera by camera.
    public var rows: [CullDayRow] { sections.flatMap(\.days) }

    public func row(_ id: CullDayRow.ID) -> CullDayRow? { rows.first { $0.id == id } }

    // MARK: Loading

    /// Reads the staged files and their marks again. A load started while another runs replaces it.
    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if sections.isEmpty { phase = .loading }
        let records: [CatalogueRecord]
        let cameraRows: [CameraRecord]
        do {
            records = try await catalogue.stagedRecords(camera: nil)
            cameraRows = (try? await catalogue.cameras()) ?? []
        } catch {
            guard generation == loadGeneration else { return }
            log.note("cull: couldn't read the staged files (\(type(of: error)))", level: .error)
            failed()
            return
        }
        let iCloud = await locator.locate().iCloudDocuments
        let resolved = await Self.resolve(records, cameras: cameraRows, onThisIPhone: onThisIPhone, iCloud: iCloud,
                                          reader: reader)
        let built = Self.sections(of: resolved.files)
        let keys = built.flatMap(\.days).flatMap(\.units).flatMap(\.keys)
        let stored: [ObjectIdentity.ContentKey: MarkRecord]
        do {
            stored = try await catalogue.marks(of: keys)
        } catch {
            guard generation == loadGeneration else { return }
            log.note("cull: couldn't read the marks (\(type(of: error)))", level: .error)
            failed()
            return
        }
        guard generation == loadGeneration else { return }
        sections = built
        unavailable = resolved.unavailable
        marks = stored.mapValues(CatalogueMarkWriter.mark)
        phase = .loaded
        // Counts only: never a name, a path or a camera's folder.
        log.note("cull: listed staged files=\(keys.count) days=\(built.flatMap(\.days).count) "
            + "notShown=\(resolved.unavailable.total)")
    }

    private func failed() {
        phase = .failed
        loadFailureDismissed = false
    }

    /// A staged file with the camera name it is listed under.
    struct NamedFile: Sendable {
        var cameraName: String
        var file: CullFile
    }

    struct Resolved: Sendable {
        var files: [NamedFile] = []
        var unavailable = StagedUnavailable()
    }

    /// Each record's staged copy as a file, or why it can't be shown. Off the main actor: the presence check reads the
    /// file system.
    static func resolve(_ records: [CatalogueRecord], cameras: [CameraRecord], onThisIPhone: URL, iCloud: URL?,
                        reader: any StagedFileReading) async -> Resolved {
        let names = Dictionary(cameras.map { ($0.key, Self.recordName($0)) }, uniquingKeysWith: { first, _ in first })
        return await Task.detached(priority: .userInitiated) {
            var resolved = Resolved()
            for record in records {
                guard let staged = record.staged else { continue }
                let documents: URL
                switch staged.root {
                case .onThisIPhone:
                    documents = onThisIPhone
                case .iCloudDrive:
                    guard let iCloud else {
                        resolved.unavailable.inICloudDrive += 1
                        continue
                    }
                    documents = iCloud
                }
                guard let url = staged.fileURL(in: documents) else {
                    resolved.unavailable.unknownPlace += 1
                    continue
                }
                guard reader.presence(of: url, expectedSize: record.identity.size) == .present else {
                    resolved.unavailable.gone += 1
                    continue
                }
                let name = Self.folderName(of: staged) ?? names[record.identity.camera] ?? CamerasWording.genericName
                resolved.files.append(NamedFile(cameraName: name, file: CullFile(identity: record.identity, url: url)))
            }
            return resolved
        }.value
    }

    /// The camera's folder under Staging ("ILCE-7CM2" in "Staging/ILCE-7CM2/2026-11-08/DSC00001.ARW"): the display
    /// name its files were staged under (D11). Nil for a copy directly in Staging.
    nonisolated static func folderName(of location: StagedLocation) -> String? {
        let components = location.relativePath.split(separator: "/")
        guard components.count >= 3 else { return nil }
        return String(components[1])
    }

    /// A camera's name from its catalogue row, for a copy with no camera folder.
    nonisolated static func recordName(_ record: CameraRecord) -> String {
        if !record.friendlyName.isEmpty { return record.friendlyName }
        if !record.model.isEmpty { return record.model }
        return CamerasWording.genericName
    }

    /// The files by camera name (in name order), each camera's days newest first, each day's units in shooting order.
    /// Pairs are made per catalogue key (`CullDay.days(of:)`, the rule Import uses), and the days of one name's keys are
    /// merged. Two staged copies of one file (one content key) are one unit, the first one listed: a mark couldn't tell
    /// them apart.
    nonisolated static func sections(of files: [NamedFile], rule: RawPairingRule = RawPairingRule()) -> [CullCameraSection] {
        var seen = Set<ObjectIdentity.ContentKey>()
        var byName: [String: [CullFile]] = [:]
        for named in files where seen.insert(named.file.contentKey).inserted {
            byName[named.cameraName, default: []].append(named.file)
        }
        let names = byName.keys.sorted { a, b in
            let (la, lb) = (a.lowercased(), b.lowercased())
            return la != lb ? la < lb : a < b
        }
        return names.map { name in
            var byDay: [String: [CullUnit]] = [:]
            for day in CullDay.days(of: byName[name] ?? [], rule: rule) {
                byDay[day.day, default: []].append(contentsOf: day.units)
            }
            let days = byDay.keys.sorted(by: >).map { day in
                CullDayRow(cameraName: name, day: day, units: (byDay[day] ?? []).sorted(by: shootingOrder))
            }
            return CullCameraSection(name: name, days: days)
        }
    }

    private nonisolated static func shootingOrder(_ a: CullUnit, _ b: CullUnit) -> Bool {
        if a.captureDate != b.captureDate { return a.captureDate < b.captureDate }
        let (fa, fb) = (a.files[0].identity, b.files[0].identity)
        if fa.filename.uppercased() != fb.filename.uppercased() { return fa.filename.uppercased() < fb.filename.uppercased() }
        if fa.camera.rawValue != fb.camera.rawValue { return fa.camera.rawValue < fb.camera.rawValue }
        return fa.folder < fb.folder
    }

    // MARK: Marks and counts

    /// The unit's mark: the open loupe's, for a unit of its day, else the catalogue's (`CullMark.of`).
    public func mark(of unit: CullUnit) -> CullMark {
        if let loupe, loupe.row.units.contains(where: { $0.id == unit.id }) { return loupe.session.mark(of: unit) }
        return CullMark.of(unit, in: marks)
    }

    /// The day's counts, in units: "120 staged, 34 kept, 60 rejected".
    public func counts(of row: CullDayRow) -> CullCounts {
        if let loupe, loupe.row.id == row.id { return loupe.session.counts }
        return CullCounts(units: row.units, marks: marks)
    }

    // MARK: The loupe

    /// Opens the loupe on a day: at `index`, or at its first unit with no decision (the first unit when all have one).
    ///
    /// - Parameter maxPixelSize: the longer side, in pixels, of the screen the previews are drawn on.
    public func openLoupe(_ id: CullDayRow.ID, at index: Int? = nil, maxPixelSize: Int = 2_800) {
        guard let row = row(id), !row.units.isEmpty else { return }
        if let loupe { finish(loupe) }
        let start = index ?? row.units.firstIndex { CullMark.of($0, in: marks).decision == nil } ?? 0
        let prefetcher = PreviewPrefetcher<Image>(loader: loader, files: files, clock: clock, policy: policy,
                                                  maxPixelSize: maxPixelSize)
        let made = CullLoupe(row: row, marks: marks, startingAt: start, writer: writer, prefetcher: prefetcher,
                             loader: loader, exif: exif)
        // The error's type only: never a file name or a content key.
        let log = self.log
        made.session.onWriteFailure = { failure in
            log.note("cull: a mark couldn't be saved (\(failure.detail))", level: .error)
        }
        loupe = made
    }

    /// Closes the loupe: its previews are released, its marks are taken into the day's counts at once, and once its
    /// saves have settled the catalogue's marks are read back.
    public func closeLoupe() async {
        guard let loupe else { return }
        await closeLoupe(loupe)
    }

    /// Closes `which` if it is still the open loupe, and does nothing otherwise: a screen that saw one loupe dismissed
    /// never closes another opened since.
    public func closeLoupe(_ which: CullLoupe<Image>) async {
        guard let loupe, loupe === which else { return }
        self.loupe = nil
        finish(loupe)
        await loupe.settled()
        await reloadMarks()
    }

    /// Stops the loupe and takes its marks as they stand.
    private func finish(_ loupe: CullLoupe<Image>) {
        loupe.stop()
        for unit in loupe.row.units {
            let mark = loupe.session.mark(of: unit)
            for key in unit.keys { marks[key] = mark.isUnmarked ? nil : mark }
        }
    }

    /// Reads the marks of the files shown again; on a failure the marks stay as they are.
    private func reloadMarks() async {
        let keys = rows.flatMap(\.units).flatMap(\.keys)
        guard let stored = try? await catalogue.marks(of: keys) else { return }
        marks = stored.mapValues(CatalogueMarkWriter.mark)
    }
}

/// One VoiceOver announcement from the loupe; `id` tells two with the same text apart, so each is spoken.
public struct LoupeAnnouncement: Sendable, Hashable {
    public var id: Int
    public var announcement: StatusAnnouncement
}

/// The loupe over one day (backlog section 7.3): the `CullSession` (where the person is, the marks, undo) with the
/// `PreviewPrefetcher` following its position, and the EXIF line of the unit on screen (D5). Each action says what
/// VoiceOver should announce (`announcement`), since a custom action changes the photo without VoiceOver reading it.
///
/// Zoomed in past the preview's own pixels, the view asks for the region on screen from the original
/// (`showDetail(_:maxPixelSize:)`, `LoupeZoom.detailRegion`), so a pinch reaches the original's 100 %: one image at most
/// screen-sized, the current unit's only, held beside the prefetcher's previews (about 15 MB within the app's 150 MB).
///
/// A Keep or Reject moves on to the next unit (not past the last), so a day is culled one gesture a photo; Undo goes
/// back to the unit it reverts.
@MainActor
@Observable
public final class CullLoupe<Image: Sendable>: Identifiable {
    public let row: CullDayRow
    public let session: CullSession
    public let prefetcher: PreviewPrefetcher<Image>
    /// The EXIF line's facts for the unit on screen, once read; nil while reading, while its iCloud file downloads, or
    /// when the file has none.
    public private(set) var exif: EXIFSummary?
    public private(set) var announcement: LoupeAnnouncement?
    /// The region on screen decoded from the original, while zoomed in past the preview's own pixels; the current unit's
    /// only.
    public private(set) var detail: LoupeDetail<Image>?

    @ObservationIgnored private let loader: any PreviewLoading<Image>
    @ObservationIgnored private let exifReader: (@Sendable (URL) async -> EXIFSummary?)?
    @ObservationIgnored private var exifTask: Task<Void, Never>?
    @ObservationIgnored private var exifUnit: CullUnit.ID?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var detailRequest: DetailRequest?
    @ObservationIgnored private var announcements = 0

    private struct DetailRequest: Hashable {
        var unit: CullUnit.ID
        var region: LoupeRegion
    }

    init(row: CullDayRow, marks: [ObjectIdentity.ContentKey: CullMark], startingAt start: Int,
         writer: any CullMarkWriting, prefetcher: PreviewPrefetcher<Image>, loader: any PreviewLoading<Image>,
         exif: (@Sendable (URL) async -> EXIFSummary?)?) {
        self.row = row
        session = CullSession(units: row.units, marks: marks, startingAt: start, writer: writer)
        session.advancesAfterDecision = true
        self.prefetcher = prefetcher
        self.loader = loader
        exifReader = exif
        prefetcher.show(row.units, focusing: session.index)
        // An evicted file's EXIF line is read once its download has finished.
        prefetcher.onFileLocal = { [weak self] id in
            guard let self, self.current?.id == id else { return }
            self.readEXIF()
        }
        readEXIF()
    }

    // MARK: What the loupe shows

    public var current: CullUnit? { session.current }
    public var currentMark: CullMark { session.currentMark }
    /// "12 of 120".
    public var position: String { CullWording.position(session.index, of: session.count) }
    public var preview: LoadedPreview<Image>? { current.flatMap(prefetcher.preview(for:)) }
    /// While the unit's evicted file downloads.
    public var download: DownloadProgress? { current.flatMap(prefetcher.downloadProgress(for:)) }
    public var previewFailed: Bool { current.map(prefetcher.hasFailed) ?? false }
    /// The unit has nothing to preview (a video or a sidecar on its own).
    public var hasNoPreview: Bool { current.map { $0.previewSource.file == nil } ?? false }

    /// The photo's VoiceOver label and value.
    public var accessibilityLabel: String { current.map(CullWording.unitLabel) ?? "" }
    public var accessibilityValue: String {
        CullWording.unitValue(index: session.index, count: session.count, mark: session.currentMark)
    }

    /// A save that failed, until dismissed.
    public var writeFailureNotice: StatusNotice? {
        session.writeFailure.map { _ in
            StatusNotice(text: CullWording.writeFailed, tone: .problem, systemImage: "exclamationmark.triangle",
                         dismissesItself: false)
        }
    }

    // MARK: Actions

    public func next() {
        if session.next() { moved() } else { announce(CullWording.lastPhoto) }
    }

    public func previous() {
        if session.previous() { moved() } else { announce(CullWording.firstPhoto) }
    }

    public func keep() { decide(.keep) }
    public func reject() { decide(.reject) }
    public func clearDecision() { decide(nil) }

    /// Sets the unit's stars (0 to 5), keeping its decision.
    public func setRating(_ rating: Int) {
        guard current != nil else { return }
        session.setRating(rating)
        announce(CullWording.rated(session.currentMark.rating))
    }

    public func undo() {
        guard session.undo() else {
            announce(CullWording.nothingToUndo)
            return
        }
        moved()
        announce(CullWording.undone(index: session.index, count: session.count, mark: session.currentMark))
    }

    public func retryPreview() {
        if let current { prefetcher.retry(current) }
    }

    public func dismissWriteFailure() { session.dismissWriteFailure() }

    private func decide(_ decision: CullDecision?) {
        guard current != nil else { return }
        let before = session.index
        session.setDecision(decision)
        let advanced = session.index != before
        if advanced { moved() }
        announce(CullWording.marked(decision, movedTo: advanced ? position : nil))
    }

    private func moved() {
        prefetcher.focus(on: session.index)
        clearDetail()
        readEXIF()
    }

    private func announce(_ text: String) {
        announcements += 1
        announcement = LoupeAnnouncement(id: announcements, announcement: StatusAnnouncement(text))
    }

    // MARK: Zoom

    /// Shows `region` of the current unit decoded from the original, at most `maxPixelSize` on its longer side (the
    /// screen's), once the decode is done; the region shown before stays until then. Nothing happens for a preview
    /// with no `fullPixelSize`, or for the region already shown or being decoded.
    public func showDetail(_ region: LoupeRegion, maxPixelSize: Int) {
        guard let unit = current, let preview, preview.fullPixelSize != nil, let region = region.clipped,
              maxPixelSize > 0
        else {
            clearDetail()
            return
        }
        let request = DetailRequest(unit: unit.id, region: region)
        if let detail, detail.unit == unit.id, detail.region == region { return }
        if detailRequest == request { return }
        if let detail, detail.unit != unit.id { self.detail = nil }
        detailTask?.cancel()
        detailRequest = request
        let (loader, source) = (loader, unit.previewSource)
        detailTask = Task { [weak self] in
            let loaded = try? await loader.loadDetail(source, region: region, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled, let self, self.detailRequest == request else { return }
            self.detailRequest = nil
            if let loaded { self.detail = LoupeDetail(unit: request.unit, region: region, preview: loaded) }
        }
    }

    /// Drops the region decoded from the original (the photo fits the screen again, or another unit is shown).
    public func clearDetail() {
        detailTask?.cancel()
        detailTask = nil
        detailRequest = nil
        detail = nil
    }

    // MARK: EXIF

    /// Reads the current unit's EXIF line, once its file is on the phone: an evicted iCloud file is read when the
    /// prefetcher's download finishes (`PreviewPrefetcher.onFileLocal`), never while it would block on the download.
    private func readEXIF() {
        guard let unit = current, unit.id != exifUnit else { return }
        exifTask?.cancel()
        exif = nil
        guard let reader = exifReader, let url = unit.previewSource.file?.url else {
            exifUnit = unit.id
            return
        }
        guard prefetcher.isFileLocal(unit) else {
            exifUnit = nil
            return
        }
        exifUnit = unit.id
        let id = unit.id
        exifTask = Task { [weak self] in
            let summary = await reader(url)
            guard !Task.isCancelled, let self, self.exifUnit == id else { return }
            self.exif = summary.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    // MARK: Ending

    /// Stops fetching and releases every preview.
    func stop() {
        exifTask?.cancel()
        clearDetail()
        prefetcher.stop()
    }

    /// Waits until every mark made so far is saved or has failed, and the EXIF read and the detail decode under way
    /// have ended.
    public func settled() async {
        await session.settled()
        await exifTask?.value
        await detailTask?.value
    }
}

/// A region of a unit decoded from the original, for the loupe zoomed in past the preview's own pixels.
public struct LoupeDetail<Image: Sendable>: Sendable {
    public var unit: CullUnit.ID
    /// Where it sits in the photo.
    public var region: LoupeRegion
    public var preview: LoadedPreview<Image>
}
