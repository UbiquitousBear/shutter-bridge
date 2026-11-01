import Foundation
import Observation
import CoreGraphics   // CGImage in cameraDevice(_:didReceiveThumbnail:for:error:); don't rely on a re-export
import ImageCaptureCore
import CryptoKit
import PTPKit

/// Days 2–5: everything we do with one ICCameraDevice over USB-C.
///
/// Every action is one tap in the Wired tab, runs one at a time (`perform`), logs what it observed and records
/// the measurement names the Log tab's Markdown export maps onto docs/spike-plan.md. Nothing here is production
/// code. ImageCaptureCore calls the delegate on the main thread; completion blocks arrive on any queue and are
/// funnelled through `callback`, which also stops waiting when the cable is pulled (didRemove) or a timeout hits.
@Observable
@MainActor
final class CameraSession: NSObject {
    let device: ICCameraDevice
    let log: SpikeLog
    let lifecycle: LifecycleMonitor

    // Shown by the Wired tab.
    private(set) var isOpen = false
    private(set) var catalogComplete = false
    private(set) var removed = false
    /// Newest first (creation date, then name).
    private(set) var files: [ICCameraFile] = []
    private(set) var deviceInfo: PTPDeviceInfo?
    /// The running operation; nil when idle. The Wired tab disables its buttons while this is set.
    private(set) var activity: String?
    private(set) var progressText = ""
    private(set) var lastResult = ""
    private(set) var resumeSummary: String = USBResumeStore.load()?.summary ?? "none saved"
    private(set) var stopRequested = false
    /// ImageCaptureCore's contentCatalogPercentCompleted as last polled while waiting for the catalogue.
    private(set) var cataloguePercent = 0

    var isBusy: Bool { activity != nil }

    var stateDescription: String {
        if removed { return "camera disconnected" }
        if linkStalled { return "stalled: unplug, replug, choose MTP, then Open session" }
        if !isOpen { return "closed" }
        return catalogComplete ? "open" : "open, cataloguing \(cataloguePercent) %"
    }

    @ObservationIgnored private var tx = PTPTransactionCounter()
    @ObservationIgnored private var openRequestedAt: ContinuousClock.Instant?
    @ObservationIgnored private var abortHandlers: [UUID: (Error) -> Void] = [:]
    @ObservationIgnored private var layoutsSeen: Set<String> = []
    @ObservationIgnored private var recentEvents: [RecentEvent] = []
    @ObservationIgnored private var eventSourceCounts: [String: Int] = [:]
    @ObservationIgnored private var savedEventCodes: Set<UInt16> = []
    @ObservationIgnored private var objectAddedFlagged = false
    @ObservationIgnored private var newObjectEventAt: Date?
    @ObservationIgnored private var iccAddedAfterCatalogue: [String] = []
    @ObservationIgnored private var lastSerialARWThroughput: Double?
    @ObservationIgnored private var closingSession = false
    @ObservationIgnored private var loggedDownloadName = false
    @ObservationIgnored private var thumbnailRuns = 0
    @ObservationIgnored private var successfulOpens = 0
    /// Devices any CameraSession has opened in this process: a new session on one of them (after a stall) is still a
    /// reopen, and ImageCaptureCore may keep its catalogue. A replugged camera is a new ICCameraDevice.
    private static let openedDevices = NSHashTable<ICCameraDevice>.weakObjects()
    @ObservationIgnored private var openIsReopen = false
    /// PTP pass-through commands sent between this open's request and ImageCaptureCore's complete catalogue: they
    /// share the link with the catalogue, so a catalogue time with any of them is not a cold figure.
    @ObservationIgnored private var ptpCommandsDuringCatalogue = 0
    /// Pass-through commands logged with their timing while ImageCaptureCore's catalogue ran (the first few per open,
    /// and any that waited more than 2 s): does pass-through wait for the catalogue?
    @ObservationIgnored private var catalogueTimingNotes = 0
    /// Objects the spike has sent a per-object command for in this session (GetObjectInfo, GetThumb,
    /// GetPartialObject, GetObjectPropList): the camera may answer those from a cache, so listings time them apart.
    @ObservationIgnored private var touchedHandles: Set<PTPObjectHandle> = []
    /// This session's catalogue figure (measurement name, seconds, a note such as REOPEN), for the listing contexts.
    /// SpikeLog.measurements is restored across launches, so the last logged value may be another session's.
    @ObservationIgnored private var sessionCatalogue: (seconds: Double, name: String, note: String)?
    /// This session's PTP listing time (usb.ptp.catalog), for the MTP listing's context. Cleared with the PTP caches.
    @ObservationIgnored private var sessionPTPListingSeconds: Double?
    /// Open session with the wait turned off: polls the catalogue outside `perform` until it completes.
    @ObservationIgnored private var catalogueMonitor: Task<Void, Never>?
    /// The running monitor's token; a cancelled monitor that wakes later must not touch a newer open's state.
    @ObservationIgnored private var catalogueMonitorID: UUID?
    // PTP handle lookup (resolveHandle). ImageCaptureCore's ptpObjectHandle is 0 for every file in the camera's
    // MTP mode (iOS 27.2), so handles are found over PTP. All three are per session: cleared on open, close and
    // removal, because handles are not stable across sessions.
    @ObservationIgnored private var ptpHandles: [PTPObjectHandle]?
    @ObservationIgnored private var ptpObjectInfos: [PTPObjectHandle: PTPObjectInfo] = [:]
    @ObservationIgnored private var resolvedHandles: [FileKey: PTPObjectHandle] = [:]
    /// Requests in a row that got no answer (a timeout, or an empty pass-through reply). On 1 Nov the camera stopped
    /// answering altogether after one GetObjectPropList, and every later request waited out its full timeout; from
    /// two in a row this connection is marked stalled and the spike stops sending on it until the camera is replugged.
    @ObservationIgnored private var consecutiveNoAnswers = 0
    private(set) var linkStalled = false
    @ObservationIgnored private var mtpSummaries: [PTPObjectHandle: MTPObjectSummary] = [:]
    /// Every object a PTP listing read, set only when its loop finished. `ptpObjectInfos` also holds what
    /// resolveHandle and a stopped listing read, which is not a listing of the card.
    @ObservationIgnored private var ptpListingInfos: [PTPObjectHandle: PTPObjectInfo] = [:]
    /// Stamped into USBResumeState: a resume counts as a link-drop resume only in a different CameraSession.
    private let sessionID = UUID()

    private struct RecentEvent {
        let data: Data
        let at: Date
        let source: String
    }

    /// (name, size) of an ICCameraFile, the key a resolved PTP handle is cached under. Name lower-cased.
    private struct FileKey: Hashable {
        let name: String
        let size: Int64
    }

    init(device: ICCameraDevice, log: SpikeLog, lifecycle: LifecycleMonitor) {
        self.device = device
        self.log = log
        self.lifecycle = lifecycle
        super.init()
        device.delegate = self
        // Day 4: raw PTP event containers. Apple: when this handler is set it is called *instead of*
        // cameraDevice(_:didReceivePTPEvent:); both paths feed `receiveEvent`, which de-duplicates.
        // @Sendable: the handler runs on an ImageCaptureCore queue, so it must not inherit this init's main-actor
        // isolation (Swift 6 mode or DynamicActorIsolation would trap on the executor check).
        device.ptpEventHandler = { @Sendable [weak self] data in
            Task { @MainActor in self?.receiveEvent(data, source: "ptpEventHandler") }
        }
    }

    /// Call before replacing this session: ICDevice.delegate is unowned(unsafe).
    func detach() {
        device.delegate = nil
        device.ptpEventHandler = { _ in }
        stopCatalogueMonitor()
        abortPending(.sessionReplaced)
    }

    func requestStop() {
        guard let activity else { return }
        stopRequested = true
        log.note("Stop requested: \(activity)")
    }

    // MARK: - One operation at a time

    private func perform(_ title: String, _ work: () async throws -> Void) async {
        if let activity {
            log.warn("\(title): busy with \(activity); wait for it or tap Stop")
            return
        }
        if removed {
            log.error("\(title): the camera was disconnected. Plug it back in, then Day 2 · Open session.")
            return
        }
        activity = title
        stopRequested = false
        progressText = ""
        let running = "\(title): running…"
        lastResult = running
        log.note("▶ \(title)")
        do {
            try await work()
            if lastResult == running { lastResult = "\(title): done" }
        } catch USBSpikeError.stopped {
            log.warn("\(title): stopped [\(lifecycle.stateDescription)]")
            lastResult = "\(title): stopped"
        } catch {
            log.error("\(title) failed: \(describe(error)) [\(lifecycle.stateDescription)]")
            lastResult = "\(title): failed — \(describe(error))"
        }
        activity = nil
        progressText = ""
        stopRequested = false
    }

    /// An open session with ImageCaptureCore's catalogue complete: for everything that picks files from `files`
    /// (thumbnails, downloads, the newest ARW). `files` stays empty until the catalogue completes.
    private func requireOpen() throws {
        try requireSession()
        guard catalogComplete else {
            throw USBSpikeError.catalogueIncomplete(device.contentCatalogPercentCompleted, device.mediaFiles?.count ?? 0)
        }
    }

    /// An open session, catalogue complete or not: for PTP commands that don't need ImageCaptureCore's file list.
    private func requireSession() throws {
        if removed { throw USBSpikeError.deviceRemoved }
        guard isOpen else { throw USBSpikeError.sessionNotOpen }
        if linkStalled { throw USBSpikeError.linkStalled }
    }

    /// Counts a request that got no answer; from two in a row the link is marked stalled (see `linkStalled`).
    private func noteNoAnswer(_ what: String) {
        consecutiveNoAnswers += 1
        guard consecutiveNoAnswers >= 2 else { return }
        markLinkStalled("\(consecutiveNoAnswers) requests in a row got no answer (the last was \(what))")
    }

    /// From here every action refuses with `.linkStalled` until the camera is replugged (a new CameraSession).
    private func markLinkStalled(_ why: String) {
        guard !linkStalled else { return }
        linkStalled = true
        log.warn("The camera has stopped answering: \(why). Unplug it, plug it back in, choose MTP, then Open session. The spike sends nothing more on this connection.")
    }

    // MARK: - Completion-handler plumbing

    /// Starts an ImageCaptureCore request and waits for its completion, a timeout, or the camera going away.
    private func callback<T>(_ what: String, timeout: Double?,
                             _ start: (_ done: @escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        if removed { throw USBSpikeError.deviceRemoved }
        let id = UUID()
        var timeoutTask: Task<Void, Never>?
        defer {
            timeoutTask?.cancel()
            abortHandlers[id] = nil
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let box = PendingRequest<T>(continuation)
            abortHandlers[id] = { error in box.finish(.failure(error)) }
            if let timeout {
                timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { box.finish(.failure(USBSpikeError.timedOut(what, timeout))) }
                }
            }
            start { result in box.finish(result) }
        }
    }

    private func abortPending(_ error: USBSpikeError) {
        let handlers = abortHandlers
        abortHandlers.removeAll()
        for handler in handlers.values { handler(error) }
    }

    // MARK: - Day 2 · session and catalogue

    /// `waitForCatalogue` off (Wired tab toggle): returns as soon as requestOpenSession completes, and a monitor task
    /// outside `perform` (so other buttons stay usable) logs the catalogue until it completes. Buttons that need
    /// ImageCaptureCore's file list refuse until then (`requireOpen`). usb.catalog.complete is stamped by
    /// deviceDidBecomeReady(withCompleteContentCatalog:) either way.
    func openSession(waitForCatalogue: Bool = true) async {
        await perform("Open session") {
            if isOpen { log.note("Session already open"); return }
            var staleCloseUnconfirmed = false
            if device.hasOpenSession {
                // A new CameraSession on a device ImageCaptureCore still has open (the previous one stalled and the
                // camera was not unplugged): close it first so the open below starts clean. No answer is expected
                // on a stalled connection, so this waits 10 s at most.
                log.warn("ImageCaptureCore still has a session open on this camera (no cable pull since the last one); closing it first")
                // As in closeSession: this close's own didCloseSession must not abort it.
                closingSession = true
                defer { closingSession = false }
                do {
                    let _: Void = try await callback("requestCloseSession (stale)", timeout: 10) { done in
                        self.device.requestCloseSession(options: nil) { error in
                            if let error { done(.failure(error)) } else { done(.success(())) }
                        }
                    }
                    log.note("  stale session closed")
                } catch USBSpikeError.sessionClosed {
                    log.note("  stale session closed (didCloseSession)")
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    staleCloseUnconfirmed = true
                    log.warn("  closing the stale session failed: \(describe(error))")
                }
            }
            if staleCloseUnconfirmed {
                throw USBSpikeError.nothingToDo("ImageCaptureCore didn't confirm closing the stalled session within 10 s, so the camera is still not answering. Unplug it and plug it back in (if the camera is then listed twice, tap the lower row), or turn the camera off and on, then Open session.")
            }
            stopCatalogueMonitor()
            clearPTPCaches()
            catalogComplete = false
            files = []   // the previous session's ICCameraFile objects must not be acted on in this one
            cataloguePercent = 0
            sessionCatalogue = nil
            let clock = ContinuousClock()
            let start = clock.now
            openRequestedAt = start
            ptpCommandsDuringCatalogue = 0
            catalogueTimingNotes = 0
            touchedHandles.removeAll()
            // A reopen on the same ICCameraDevice may find the catalogue ImageCaptureCore kept from the last session.
            openIsReopen = successfulOpens > 0 || Self.openedDevices.contains(device)
            // Only this open may stamp usb.catalog.complete: a ready callback after it (a reopen by ImageCaptureCore,
            // a failed or stopped open) must not be timed from this request. When not waiting, the monitor owns
            // `openRequestedAt` from here and clears it when it ends.
            var monitorOwnsStamp = false
            defer { if !monitorOwnsStamp { openRequestedAt = nil } }
            let _: Void = try await callback("requestOpenSession", timeout: 60) { done in
                self.device.requestOpenSession(options: nil) { error in
                    if let error { done(.failure(error)) } else { done(.success(())) }
                }
            }
            isOpen = true
            successfulOpens += 1
            Self.openedDevices.add(device)
            consecutiveNoAnswers = 0
            log.measure("usb.openSession", (clock.now - start).inSeconds, "s", context: device.name ?? "camera")
            logCapabilities("after open")
            let percentAtOpen = device.contentCatalogPercentCompleted

            if !waitForCatalogue && !catalogComplete {
                monitorOwnsStamp = true
                cataloguePercent = percentAtOpen
                startCatalogueMonitor(start: start, percentAtOpen: percentAtOpen)
                log.note("Not waiting for ImageCaptureCore's catalogue (\(percentAtOpen)% at open). PTP buttons work now; thumbnails, downloads and the newest-file tests wait for usb.catalog.complete.")
                lastResult = "Open session: catalogue \(percentAtOpen)%, not waiting"
                return
            }
            try await awaitCatalogue(start: start, percentAtOpen: percentAtOpen, inOperation: true)
            refreshCatalogue(record: true)
            lastResult = "Open session: \(files.count) files"
        }
    }

    /// Polls until ImageCaptureCore's catalogue is complete, logging `catalogue n%, m files so far` every 2 s.
    /// `inOperation`: inside `perform` (Stop ends it, the overlay shows the percentage); otherwise the monitor,
    /// which ends when its task is cancelled. Either way it ends on removal, session close or after 300 s.
    private func awaitCatalogue(start: ContinuousClock.Instant, percentAtOpen: Int, inOperation: Bool) async throws {
        // usb.catalog.complete is recorded by deviceDidBecomeReady(withCompleteContentCatalog:) itself, from
        // `openRequestedAt`; this loop only waits for it.
        // If the callback never comes (possible when a session is reopened on the same device), the first
        // moment contentCatalogPercentCompleted reads 100 is used instead, 10 s later, and labelled as such. If
        // it already read 100 when the open completed, ImageCaptureCore kept the catalogue from an earlier
        // session: that is not a listing of the card, so nothing is recorded.
        let clock = ContinuousClock()
        var lastNote = clock.now
        var fullAt: ContinuousClock.Instant?
        var commandsWhenFull = 0   // pass-through commands up to that moment, not the 10 s after it
        while !catalogComplete {
            if removed { throw USBSpikeError.deviceRemoved }
            if !isOpen { throw USBSpikeError.sessionClosed }
            if inOperation && stopRequested { throw USBSpikeError.stopped }
            try Task.checkCancellation()
            if clock.now - start > .seconds(300) { throw USBSpikeError.timedOut("the complete content catalogue", 300) }
            let percentDone = device.contentCatalogPercentCompleted
            if cataloguePercent != percentDone { cataloguePercent = percentDone }
            if inOperation { progressText = "cataloguing \(percentDone)%" }
            if percentDone >= 100, fullAt == nil {
                fullAt = clock.now
                commandsWhenFull = ptpCommandsDuringCatalogue
            }
            if let fullAt, clock.now - fullAt > .seconds(10) {
                if openIsReopen && percentAtOpen >= 100 {
                    log.warn("Reopen: the catalogue already read 100 % when the session opened (kept from the earlier session) and no ready callback came, so this was not a listing of the card: usb.catalog.complete not recorded. Unplug and re-plug the camera for a cold listing.")
                } else {
                    log.warn("deviceDidBecomeReady(withCompleteContentCatalog:) did not arrive within 10 s of the catalogue reading 100 %; using that moment instead")
                    recordCatalogueComplete((fullAt - start).inSeconds, commands: commandsWhenFull,
                                            context: "open request → contentCatalogPercentCompleted = 100 (no ready callback), \(device.mediaFiles?.count ?? 0) files"
                                                + (openIsReopen ? "; REOPEN on the same device, the catalogue may be cached (re-plug for a cold figure)" : ""),
                                            note: openIsReopen ? "no ready callback; REOPEN, may be cached" : "no ready callback")
                }
                catalogComplete = true
                break
            }
            if clock.now - lastNote > .seconds(2) {
                lastNote = clock.now
                log.note("  catalogue \(percentDone)%, \(device.mediaFiles?.count ?? 0) files so far")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startCatalogueMonitor(start: ContinuousClock.Instant, percentAtOpen: Int) {
        catalogueMonitor?.cancel()   // openSession already stopped any earlier one; this is belt and braces
        let id = UUID()
        catalogueMonitorID = id
        catalogueMonitor = Task { [weak self] in
            guard let self else { return }
            await self.monitorCatalogue(id: id, start: start, percentAtOpen: percentAtOpen)
        }
    }

    private func monitorCatalogue(id: UUID, start: ContinuousClock.Instant, percentAtOpen: Int) async {
        do {
            try await awaitCatalogue(start: start, percentAtOpen: percentAtOpen, inOperation: false)
            guard catalogueMonitorID == id else { return }
            refreshCatalogue(record: true)
            log.note("Catalogue monitor: ImageCaptureCore's catalogue is complete, \(files.count) files; file-list buttons work now")
        } catch {
            // Cancelled by close, removal, a new open or detach: whoever cancelled it says why.
            guard catalogueMonitorID == id else { return }
            log.warn("Catalogue monitor ended: \(describe(error)) [\(lifecycle.stateDescription)]")
        }
        catalogueMonitorID = nil
        catalogueMonitor = nil
        openRequestedAt = nil
    }

    /// Ends the catalogue monitor quietly; the caller logs why. No effect when none is running.
    private func stopCatalogueMonitor() {
        guard let monitor = catalogueMonitor else { return }
        monitor.cancel()
        catalogueMonitor = nil
        catalogueMonitorID = nil
        openRequestedAt = nil
    }

    /// Records this open's catalogue time: usb.catalog.complete, or usb.catalog.complete.contended when `commands`
    /// PTP pass-through commands from the spike shared the link with the catalogue. Remembers it for this session's
    /// listing contexts (`sessionCatalogue`).
    private func recordCatalogueComplete(_ seconds: Double, commands: Int, context: String, note: String) {
        let contended = commands > 0
        let name = contended ? "usb.catalog.complete.contended" : "usb.catalog.complete"
        let detail = contended ? "; \(commands) PTP pass-through commands from the spike ran during it, not a cold figure" : ""
        log.measure(name, seconds, "s", context: context + detail)
        sessionCatalogue = (seconds: seconds, name: name, note: note)
    }

    func closeSession() async {
        await perform("Close session") {
            guard isOpen else { log.note("Session is not open"); return }
            closingSession = true
            defer { closingSession = false }
            do {
                let _: Void = try await callback("requestCloseSession", timeout: linkStalled ? 10 : 30) { done in
                    self.device.requestCloseSession(options: nil) { error in
                        if let error { done(.failure(error)) } else { done(.success(())) }
                    }
                }
            } catch let closeError where linkStalled {
                // The camera stopped answering, so CloseSession can't be answered either. Treat the session as closed
                // here, or Open session would stay disabled with every other button refusing.
                log.warn("requestCloseSession on the stalled connection: \(describe(closeError)). Treated as closed; unplug and replug the camera (or turn it off and on) before Open session.")
            }
            isOpen = false
            catalogComplete = false
            files = []
            stopCatalogueMonitor()
            clearPTPCaches()
            log.note("Session closed")
        }
    }

    /// Walks `mediaFiles` (and the `contents` tree, to compare) and logs what the findings page needs to check
    /// "metadata matches the card". `record` adds usb.catalog.count.
    func refreshCatalogue(record: Bool) {
        if !catalogComplete {
            // `files` stays empty until the catalogue completes, so file-list buttons can't act on a partial list.
            log.warn("ImageCaptureCore's catalogue is not complete yet (\(device.contentCatalogPercentCompleted)%, \(device.mediaFiles?.count ?? 0) files so far); not refreshed, usb.catalog.count not recorded")
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        let flat = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var treeCount = 0
        countFiles(in: device.contents ?? [], into: &treeCount)
        files = flat.sorted(by: Self.isNewer)
        let walkSeconds = (clock.now - start).inSeconds
        guard record else { return }

        log.measure("usb.catalog.count", Double(files.count), "files",
                    context: "mediaFiles; contents tree has \(treeCount) files; walk \(fmt(walkSeconds * 1000, 1)) ms")
        let byExtension = Dictionary(grouping: files) { Self.ext($0) }
        for (ext, group) in byExtension.sorted(by: { $0.key < $1.key }) {
            let bytes = group.reduce(Int64(0)) { $0 + Int64($1.fileSize) }
            log.note("  .\(ext.isEmpty ? "?" : ext): \(group.count) files, \(mb(bytes))")
        }
        for file in files.prefix(5) {
            log.note("  \(file.name ?? "?") \(file.fileSize) B, created \(file.creationDate.map { $0.formatted(date: .numeric, time: .standard) } ?? "no date"), handle \(hex32(file.ptpObjectHandle)), uti \(file.uti ?? "?")")
        }
        if files.count > 5 { log.note("  … \(files.count - 5) more. Compare these with the camera's playback screen.") }
    }

    private func countFiles(in items: [ICCameraItem], into count: inout Int) {
        for item in items {
            if let folder = item as? ICCameraFolder {
                countFiles(in: folder.contents ?? [], into: &count)
            } else if item is ICCameraFile {
                count += 1
            }
        }
    }

    // MARK: - Day 2 · thumbnails

    func timeThumbnails(count: Int = 50) async {
        await perform("Thumbnails, \(count) newest") {
            try requireOpen()
            thumbnailRuns += 1
            let run = thumbnailRuns
            if run > 1 {
                log.warn("Thumbnail run \(run) in this session: ImageCaptureCore may serve these from its cache. For the cold figure use the first run after Open session.")
            }
            let sample = Array(files.prefix(count))
            guard !sample.isEmpty else { throw USBSpikeError.nothingToDo("no files on the card") }
            let clock = ContinuousClock()
            var times: [Double] = []
            var bytes = 0
            var failures: [String] = []
            var thumbFailuresInARow = 0
            for (index, file) in sample.enumerated() {
                if stopRequested { throw USBSpikeError.stopped }
                if !isOpen { throw removed ? USBSpikeError.deviceRemoved : USBSpikeError.sessionClosed }
                if linkStalled { throw USBSpikeError.linkStalled }
                let name = file.name ?? "?"
                let start = clock.now
                do {
                    let data: Data = try await callback("requestThumbnailData", timeout: 10) { done in
                        file.requestThumbnailData(options: nil) { data, error in
                            if let error { done(.failure(error)) }
                            else if let data { done(.success(data)) }
                            else { done(.failure(USBSpikeError.noData("requestThumbnailData"))) }
                        }
                    }
                    let ms = (clock.now - start).inSeconds * 1000
                    times.append(ms)
                    bytes += data.count
                    if index < 3 { log.note("  thumbnail \(name): \(data.count) B in \(fmt(ms)) ms, starts \(data.hexDump(limit: 4))") }
                    thumbFailuresInARow = 0
                    consecutiveNoAnswers = 0
                } catch {
                    if removed { throw USBSpikeError.deviceRemoved }
                    if let e = error as? USBSpikeError, case .timedOut = e { noteNoAnswer("requestThumbnailData") }
                    failures.append("\(name): \(describe(error))")
                    thumbFailuresInARow += 1
                    if thumbFailuresInARow >= 3 {
                        throw USBSpikeError.nothingToDo("3 thumbnail requests in a row failed, so the run stopped: \(failures.suffix(3).joined(separator: "; "))")
                    }
                }
                lifecycle.noteProgress("thumbnail \(index + 1)/\(sample.count)", link: "usb")
                progressText = "\(index + 1)/\(sample.count)"
            }
            guard !times.isEmpty else { throw USBSpikeError.nothingToDo("every thumbnail request failed: \(failures.prefix(3).joined(separator: "; "))") }
            let avg = times.reduce(0, +) / Double(times.count)
            let minMs = times.min() ?? 0
            let maxMs = times.max() ?? 0
            log.measure("usb.thumb.avg", avg, "ms",
                        context: "\(times.count) of \(sample.count) newest ok, min \(fmt(minMs)) max \(fmt(maxMs)) ms, avg \(bytes / max(times.count, 1) / 1000) KB, run \(run) this session [\(lifecycle.stateDescription)]")
            for failure in failures.prefix(5) { log.warn("  thumbnail failed: \(failure)") }
            lastResult = "Thumbnails: \(fmt(avg)) ms average"
        }
    }

    // MARK: - Day 3 · downloads and throughput

    func downloadBatch(_ preset: USBDownloadPreset) async {
        await perform(preset.label) {
            try requireOpen()
            let selection = newest(preset.fileExtension, preset.count)
            guard !selection.isEmpty else { throw USBSpikeError.nothingToDo("no .\(preset.fileExtension) files on the card") }
            if selection.count < preset.count {
                log.warn("only \(selection.count) .\(preset.fileExtension) files on the card (the plan asks for \(preset.count))")
            }
            let total = selection.reduce(Int64(0)) { $0 + Int64($1.fileSize) }
            try ensureFreeSpace(for: total)
            let dir = try freshDirectory("Downloads")
            defer { try? FileManager.default.removeItem(at: dir) }
            log.note("Downloading \(selection.count) × .\(preset.fileExtension), \(mb(total)), \(preset.parallel) in flight…")

            let result = await log.withMemoryPeak("usb.download", context: preset.label) {
                await self.runBatch(selection, parallel: preset.parallel, dir: dir, title: preset.label)
            }
            if removed { throw USBSpikeError.deviceRemoved }
            if !isOpen {
                log.warn("The camera closed the session after \(result.ok) of \(selection.count) files; \(preset.measurement) not recorded (the per-file figures above stand).")
                throw USBSpikeError.sessionClosed
            }
            if result.stopped {
                log.warn("Batch stopped after \(result.ok) of \(selection.count) files; \(preset.measurement) not recorded (the per-file figures above stand).")
                throw USBSpikeError.stopped
            }
            guard result.ok > 0, result.seconds > 0 else { throw USBSpikeError.nothingToDo("no file downloaded") }
            let mbps = Double(result.bytes) / result.seconds / 1_000_000
            log.throughput(preset.measurement, bytes: Int(result.bytes), seconds: result.seconds,
                           context: "\(result.ok) of \(selection.count) files, \(mb(result.bytes)) on disk in \(fmt(result.seconds, 2)) s, \(preset.parallel) in flight" + (result.failed.isEmpty ? "" : ", \(result.failed.count) failed"))
            if preset == .arwSerial { lastSerialARWThroughput = mbps }
            lastResult = "\(preset.label): \(fmt(mbps)) MB/s"
        }
    }

    private struct BatchResult {
        var bytes: Int64 = 0
        var seconds: Double = 0
        var ok = 0
        var failed: [String] = []
        var stopped = false
    }

    private struct DownloadOutcome: Sendable {
        let name: String
        let bytes: Int64
        let seconds: Double
        let error: String?
    }

    /// Downloads `selection` with `parallel` requests in flight. The batch time is the wall time from the first
    /// request to the last completion; copies are deleted by the caller after the batch, outside that time.
    private func runBatch(_ selection: [ICCameraFile], parallel: Int, dir: URL, title: String) async -> BatchResult {
        var result = BatchResult()
        let clock = ContinuousClock()
        let start = clock.now
        var finished = 0
        await withTaskGroup(of: DownloadOutcome.self) { group in
            var next = 0
            while next < min(max(parallel, 1), selection.count) {
                let file = selection[next]
                next += 1
                group.addTask { @MainActor in await self.downloadOutcome(file, dir: dir) }
            }
            while let outcome = await group.next() {
                finished += 1
                if let error = outcome.error {
                    result.failed.append("\(outcome.name): \(error)")
                    log.error("  ✗ \(outcome.name): \(error) [\(lifecycle.stateDescription)]")
                } else {
                    result.ok += 1
                    result.bytes += outcome.bytes
                    log.throughput("usb.download.file", bytes: Int(outcome.bytes), seconds: outcome.seconds,
                                   context: "\(outcome.name) \(mb(outcome.bytes)) in \(fmt(outcome.seconds, 2)) s, \(title) [\(lifecycle.stateDescription)]")
                    lifecycle.noteProgress("downloaded \(outcome.name) (\(finished)/\(selection.count))", link: "usb")
                }
                progressText = "\(finished)/\(selection.count)"
                if stopRequested || removed || !isOpen {
                    result.stopped = true
                } else if next < selection.count {
                    let file = selection[next]
                    next += 1
                    group.addTask { @MainActor in await self.downloadOutcome(file, dir: dir) }
                }
            }
        }
        result.seconds = (clock.now - start).inSeconds
        return result
    }

    private func downloadOutcome(_ file: ICCameraFile, dir: URL) async -> DownloadOutcome {
        let name = file.name ?? "?"
        do {
            let downloaded = try await downloadFile(file, to: dir)
            return DownloadOutcome(name: name, bytes: downloaded.bytes, seconds: downloaded.seconds, error: nil)
        } catch {
            return DownloadOutcome(name: name, bytes: 0, seconds: 0, error: describe(error))
        }
    }

    /// One requestDownload. Bytes are the size of the file on disk afterwards; seconds are request → completion.
    /// `timeout` nil (day 3, day 5): no bound, since a long clip can take minutes. Stop doesn't end the wait; a cable
    /// pull does.
    private func downloadFile(_ file: ICCameraFile, to dir: URL, timeout: Double? = nil) async throws -> (url: URL, bytes: Int64, seconds: Double) {
        if linkStalled { throw USBSpikeError.linkStalled }
        let name = file.name ?? "?"
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: dir,
            .overwrite: true,
        ]
        let clock = ContinuousClock()
        let start = clock.now
        let saved: String
        do {
            saved = try await callback("requestDownload \(name)", timeout: timeout) { done in
                // The completion is not declared @Sendable but runs "on any available queue" (Apple): keep it nonisolated.
                _ = file.requestDownload(options: options) { @Sendable filename, error in
                    if let error { done(.failure(error)) } else { done(.success(filename ?? name)) }
                }
            }
        } catch let error as USBSpikeError {
            if case .timedOut = error { noteNoAnswer("requestDownload \(name)") }
            throw error
        }
        consecutiveNoAnswers = 0
        let seconds = (clock.now - start).inSeconds
        // verify on day 1: the completion's String is documented only as "String?"; treated as a file name inside
        // `dir`, or as a path if it is absolute. The log line below shows which.
        let url = saved.hasPrefix("/") ? URL(fileURLWithPath: saved) : dir.appendingPathComponent(saved)
        if !loggedDownloadName {
            loggedDownloadName = true
            log.note("requestDownload completion string for \(name): '\(saved)' (\(saved.hasPrefix("/") ? "a path" : "a file name")). Findings-page fact.")
        }
        guard let size = PartFileWriter.sizeOnDisk(url) else {
            throw USBSpikeError.noData("requestDownload said '\(saved)' but no such file is in \(dir.lastPathComponent)")
        }
        let bytes = Int64(size)
        if bytes != Int64(file.fileSize) {
            log.warn("  \(name): \(bytes) B on disk, the camera reported \(file.fileSize) B")
        }
        return (url, bytes, seconds)
    }

    // MARK: - Day 4 · PTP pass-through

    private struct RawPTPReply: Sendable {
        let first: Data
        let second: Data
        let error: Error?
    }

    /// Sends one command through requestSendPTPCommand and decodes the reply with PTPPassThrough.
    private func send(_ command: PTPContainer, timeout: Double = 60) async throws -> PTPPassThrough.Reply {
        let name = command.operationCode.description
        let encoded = command.encode()
        // Shares the link with ImageCaptureCore's catalogue if that is still running for this open.
        let catalogueOpenedAt: ContinuousClock.Instant? = catalogComplete ? nil : openRequestedAt
        if catalogueOpenedAt != nil { ptpCommandsDuringCatalogue += 1 }
        let sentAt = ContinuousClock().now
        var outcome = "got no answer"
        defer { if let catalogueOpenedAt { noteDuringCatalogue(name, outcome, openedAt: catalogueOpenedAt, sentAt: sentAt) } }
        let raw: RawPTPReply
        do {
            raw = try await callback(name, timeout: timeout) { done in
                self.device.requestSendPTPCommand(encoded, outData: nil) { first, second, error in
                    done(.success(RawPTPReply(first: first, second: second, error: error)))
                }
            }
        } catch let error as USBSpikeError {
            if case .timedOut = error {
                noteNoAnswer(name)
                outcome = "got no answer (timed out)"
            } else {
                outcome = "ended (\(describe(error)))"
            }
            throw error
        }
        if raw.first.isEmpty && raw.second.isEmpty {
            noteNoAnswer(name)
        } else {
            consecutiveNoAnswers = 0
        }
        let reply: PTPPassThrough.Reply
        do {
            reply = try PTPPassThrough.decodeReply(raw.first, raw.second, for: command)
        } catch {
            outcome = raw.first.isEmpty && raw.second.isEmpty ? "got no answer (two empty values)"
                : "sent no response container (\(raw.first.count) + \(raw.second.count) B)"
            let bytes = "first \(raw.first.count) B [\(raw.first.hexDump(limit: 24))], second \(raw.second.count) B [\(raw.second.hexDump(limit: 24))]"
            if let iccError = raw.error {
                throw USBSpikeError.passThrough(name, "\(describe(iccError)); \(bytes)")
            }
            throw USBSpikeError.passThrough(name, "no response container; \(bytes)")
        }
        if let iccError = raw.error {
            log.warn("\(name): ImageCaptureCore reported \(describe(iccError)) alongside response \(reply.responseCode)")
        }
        noteLayout(reply, op: name, command: command, raw: raw)
        outcome = "answered \(reply.responseCode)"
        return reply
    }

    /// Whether a pass-through command waits for ImageCaptureCore's catalogue, which decides if the app can show the
    /// newest shots before a 65 s MTP catalogue ends. Logs the first 5 commands of each open that started during the
    /// catalogue, and any that took more than 2 s.
    private func noteDuringCatalogue(_ name: String, _ outcome: String, openedAt: ContinuousClock.Instant, sentAt: ContinuousClock.Instant) {
        let took = (ContinuousClock().now - sentAt).inSeconds
        guard catalogueTimingNotes < 5 || took > 2 else { return }
        catalogueTimingNotes += 1
        let state = catalogComplete ? "the catalogue had completed by then" : "catalogue still at \(device.contentCatalogPercentCompleted) %"
        log.note("  during ImageCaptureCore's catalogue: \(name) sent \(fmt((sentAt - openedAt).inSeconds, 1)) s after Open session, \(outcome) \(fmt(took * 1000, 0)) ms later; \(state). Findings-page fact: does pass-through wait for the catalogue?")
    }

    /// The (data, response) order and header handling of requestSendPTPCommand is a findings-page fact: logged once
    /// per session, and again only if another operation shows a different layout.
    private func noteLayout(_ reply: PTPPassThrough.Reply, op: String, command: PTPContainer, raw: RawPTPReply) {
        let key = reply.layout.rawValue
        guard !layoutsSeen.contains(key) else { return }
        layoutsSeen.insert(key)
        let renumbered = reply.response.transactionID != command.transactionID
        log.note("Pass-through layout: \(key) — first seen on \(op): first value \(raw.first.count) B, second \(raw.second.count) B, data phase \(reply.data.count) B; response transaction \(reply.response.transactionID), ours \(command.transactionID)\(renumbered ? " (ImageCaptureCore renumbers transactions)" : ""). Findings-page fact.")
        if layoutsSeen.count > 1 { log.warn("Pass-through layout differs between operations: \(layoutsSeen.sorted().joined(separator: ", "))") }
    }

    private func check(_ reply: PTPPassThrough.Reply, _ what: String) throws {
        guard reply.responseCode.isOK else {
            if reply.responseCode == .invalidTransactionID {
                log.warn("\(what): InvalidTransactionID. ImageCaptureCore seems to pass our transaction ID through unchanged while it runs its own counter; findings-page fact.")
            }
            throw USBSpikeError.ptp(what, reply.responseCode)
        }
    }

    func ptpGetDeviceInfo() async {
        await perform("GetDeviceInfo") {
            try requireSession()
            let info = try await loadDeviceInfo()
            lastResult = "DeviceInfo: \(info.model) \(info.deviceVersion), \(info.operationsSupported.count) operations"
        }
    }

    private func deviceInfoOrFetch() async throws -> PTPDeviceInfo {
        if let deviceInfo { return deviceInfo }
        log.note("Fetching DeviceInfo first…")
        return try await loadDeviceInfo()
    }

    @discardableResult
    private func loadDeviceInfo() async throws -> PTPDeviceInfo {
        let reply = try await send(PTPCommand.getDeviceInfo(tx: tx.take()))
        try check(reply, "GetDeviceInfo")
        FixtureStore.saveDeviceInfo(reply.data, link: .usb, log: log)
        let info = try PTPDeviceInfo.decode(reply.data)
        deviceInfo = info
        FixtureStore.recordFirmware(model: info.model, version: info.deviceVersion, link: .usb, log: log)
        let vendor = info.vendorExtension.map { "\($0)" } ?? "unknown"
        log.note("DeviceInfo: \(info.manufacturer) \(info.model), firmware \(info.deviceVersion), \(redactedSerial(info.serialNumber))")
        log.note("  PTP \(info.standardVersion), vendor extension \(hex32(info.vendorExtensionID)) (\(vendor)) v\(info.vendorExtensionVersion) '\(info.vendorExtensionDescription)', functional mode \(info.functionalMode)")
        log.note("  operations (\(info.operationsSupported.count)): " + info.operationsSupported.map { named($0, PTPOperationCode(rawValue: $0).description) }.joined(separator: ", "))
        log.note("  events (\(info.eventsSupported.count)): " + info.eventsSupported.map { named($0, PTPEventCode(rawValue: $0).description) }.joined(separator: ", "))
        log.note("  device properties (\(info.devicePropertiesSupported.count)): " + info.devicePropertiesSupported.map { named($0, devicePropertyNames[$0] ?? "") }.joined(separator: ", "))
        log.note("  capture formats (\(info.captureFormats.count)): " + info.captureFormats.map { named($0, PTPObjectFormat(rawValue: $0).description) }.joined(separator: ", "))
        log.note("  image formats (\(info.imageFormats.count)): " + info.imageFormats.map { named($0, PTPObjectFormat(rawValue: $0).description) }.joined(separator: ", "))
        log.note("  GetPartialObject 0x101B \(yesNo(info.supports(.getPartialObject))) · GetPartialObject64 0x95C1 \(yesNo(info.supports(.getPartialObject64))) · Sony GetPartialLargeObject 0x9211 \(yesNo(info.supports(.sonySDIOGetPartialLargeObject))) · GetObjectHandles \(yesNo(info.supports(.getObjectHandles))) · ObjectAdded 0x4002 \(yesNo(info.emits(.objectAdded))) · Sony ObjectAdded 0xC201 \(yesNo(info.emits(.sonyObjectAdded))) · BatteryLevel 0x5001 \(yesNo(info.devicePropertiesSupported.contains(batteryLevelProperty)))")
        return info
    }

    func ptpStorage() async {
        await perform("GetStorageIDs + GetStorageInfo") {
            try requireSession()
            let reply = try await send(PTPCommand.getStorageIDs(tx: tx.take()))
            try check(reply, "GetStorageIDs")
            FixtureStore.save(reply.data, link: .usb, name: "storageids.bin", log: log)
            let ids = try PTPStorageID.decodeArray(reply.data)
            log.note("GetStorageIDs: \(ids.count) store(s): " + ids.map { "\(hex32($0.rawValue))\($0.hasLogicalStore ? "" : " (no logical store)")" }.joined(separator: ", "))
            var savedFirst = false
            for id in ids {
                let infoReply = try await send(PTPCommand.getStorageInfo(id, tx: tx.take()))
                guard infoReply.responseCode.isOK else {
                    log.warn("  GetStorageInfo \(hex32(id.rawValue)): \(infoReply.responseCode)")
                    continue
                }
                if !savedFirst {
                    FixtureStore.save(infoReply.data, link: .usb, name: "storageinfo.bin", log: log)
                    savedFirst = true
                }
                let si = try PTPStorageInfo.decode(infoReply.data)
                log.note("  \(hex32(id.rawValue)) '\(si.storageDescription)' label '\(si.volumeLabel)': capacity \(gb(si.maxCapacity)), free \(gb(si.freeSpaceInBytes)), free images \(si.freeSpaceInImages), storage type \(si.storageType), filesystem \(si.filesystemType), access \(si.accessCapability)")
            }
            lastResult = "\(ids.count) store(s)"
        }
    }

    func ptpObjectHandles() async {
        await perform("GetObjectHandles") {
            try requireSession()
            let clock = ContinuousClock()
            let start = clock.now
            let reply: PTPPassThrough.Reply
            do {
                reply = try await send(PTPCommand.getObjectHandles(storage: .all, tx: tx.take()), timeout: 120)
            } catch let interruption as USBSpikeError where interruption.isInterruption {
                // A cable pull, a session closed under us or Stop says nothing about what ImageCaptureCore allows.
                throw interruption
            } catch {
                log.warn("GetObjectHandles through pass-through: no reply (\(describe(error))). ImageCaptureCore allows it: no.")
                lastResult = "GetObjectHandles: not allowed"
                return
            }
            let seconds = (clock.now - start).inSeconds
            guard reply.responseCode.isOK else {
                log.warn("GetObjectHandles through pass-through: response \(reply.responseCode). ImageCaptureCore allows it: no (or the camera refused it).")
                lastResult = "GetObjectHandles: \(reply.responseCode)"
                return
            }
            FixtureStore.save(reply.data, link: .usb, name: "objecthandles.bin", log: log)
            let handles = try PTPObjectHandle.decodeArray(reply.data)
            ptpHandles = handles
            let iccHandles = Set(files.map { $0.ptpObjectHandle })
            let known = handles.filter { iccHandles.contains($0.rawValue) }.count
            let iccFiles = catalogComplete ? "ImageCaptureCore lists \(files.count) files (the difference is folders and objects it hides)"
                                           : "ImageCaptureCore's catalogue is not complete (\(device.contentCatalogPercentCompleted)%)"
            log.note("GetObjectHandles through pass-through: allowed. \(handles.count) handles in \(fmt(seconds, 2)) s; \(known) match an ICCameraFile.ptpObjectHandle; \(iccFiles).")
            lastResult = "GetObjectHandles: \(handles.count) handles"
        }
    }

    func ptpObjectInfo() async {
        await perform("GetObjectInfo") {
            try requireOpen()
            guard let arw = newest("ARW", 1).first else { throw USBSpikeError.nothingToDo("no ARW on the card") }
            let arwInfo = try await objectInfo(for: arw, saveFixture: true, compare: true)
            let siblings = files.filter { file in
                let ext = Self.ext(file)
                return (ext == "JPG" || ext == "HIF") && Self.stem(file) == arwInfo.pairStem
            }
            if siblings.isEmpty {
                log.note("No JPG/HIF sibling of \(arwInfo.pairStem) (shoot RAW+JPEG or RAW+HEIF to capture a pair); using the newest JPG and HIF instead.")
                for ext in ["JPG", "HIF"] {
                    if let other = newest(ext, 1).first { try await objectInfo(for: other, saveFixture: true, compare: true) }
                }
            }
            for sibling in siblings { try await objectInfo(for: sibling, saveFixture: true, compare: true) }
            if let mp4 = newest("MP4", 1).first { try await objectInfo(for: mp4, saveFixture: true, compare: true) }
            lastResult = "ObjectInfo: \(arwInfo.filename) + \(siblings.count) sibling(s)"
        }
    }

    @discardableResult
    private func objectInfo(for file: ICCameraFile, saveFixture: Bool, compare: Bool) async throws -> PTPObjectInfo {
        let name = file.name ?? "?"
        let handle = try await resolveHandle(for: file)
        let reply = try await send(PTPCommand.getObjectInfo(handle, tx: tx.take()))
        try check(reply, "GetObjectInfo \(name)")
        let info = try PTPObjectInfo.decode(reply.data)
        ptpObjectInfos[handle] = info
        if saveFixture {
            let ext = (info.fileExtension.isEmpty ? Self.ext(file) : info.fileExtension).lowercased()
            FixtureStore.save(reply.data, link: .usb, name: "objectinfo-\(ext.isEmpty ? "unknown" : ext).bin", log: log)
        }
        if compare {
            log.note("GetObjectInfo \(handle): \(info.filename), format \(info.objectFormat) (\(info.mediaKind.rawValue)), \(info.objectCompressedSize) B, \(info.imagePixWidth)×\(info.imagePixHeight) \(info.imageBitDepth)-bit, captured '\(info.captureDateRaw)', modified '\(info.modificationDateRaw)', thumb \(info.thumbFormat) \(info.thumbCompressedSize) B \(info.thumbPixWidth)×\(info.thumbPixHeight), storage \(hex32(info.storageID.rawValue)), parent \(info.parentObject), sequence \(info.sequenceNumber), keywords '\(info.keywords)'")
            compareWithCatalogue(info, file)
        }
        return info
    }

    private func compareWithCatalogue(_ info: PTPObjectInfo, _ file: ICCameraFile) {
        var mismatches: [String] = []
        let iccName = file.name ?? ""
        if info.filename != iccName { mismatches.append("name '\(info.filename)' vs '\(iccName)'") }
        let iccSize = UInt64(max(0, file.fileSize))
        if info.objectCompressedSize == UInt32.max {
            log.note("  ObjectCompressedSize is 0xFFFFFFFF (object of 4 GiB or more); ImageCaptureCore reports \(iccSize) B")
        } else if UInt64(info.objectCompressedSize) != iccSize {
            mismatches.append("size \(info.objectCompressedSize) vs \(iccSize)")
        }
        if let ptpDate = info.captureDate, let iccDate = file.creationDate {
            let delta = ptpDate.timeIntervalSince(iccDate)
            if abs(delta) > 1 {
                mismatches.append("date '\(info.captureDateRaw)' vs \(iccDate.formatted(date: .numeric, time: .standard)) (Δ \(fmt(delta, 0)) s)")
            }
        } else {
            mismatches.append("date '\(info.captureDateRaw)' vs \(file.creationDate.map { $0.formatted(date: .numeric, time: .standard) } ?? "none") (one side missing or unparsable)")
        }
        if mismatches.isEmpty {
            log.note("  matches ICCameraFile (name, size, date)")
        } else {
            log.warn("  ObjectInfo vs ICCameraFile mismatch: " + mismatches.joined(separator: "; "))
        }
    }

    // MARK: Day 4 · PTP object handles

    /// The PTP handle of an ImageCaptureCore file. ImageCaptureCore's own if it has one; in the camera's MTP mode
    /// it gives 0 for every file (iOS 27.2), so the handle is then found over PTP: GetObjectHandles (cached for the
    /// session), then GetObjectInfo per handle, highest first (newest objects usually have the highest handles),
    /// until one has the file's name (ignoring case) and size. Folders are skipped. Each ObjectInfo read is cached by
    /// handle and the match by (name, size), so later lookups cost nothing.
    private func resolveHandle(for file: ICCameraFile) async throws -> PTPObjectHandle {
        if file.ptpObjectHandle != 0 { return PTPObjectHandle(rawValue: file.ptpObjectHandle) }
        let name = file.name ?? ""
        guard !name.isEmpty else { throw USBSpikeError.noHandle("a file without a name", "nothing to match on") }
        let size = Int64(file.fileSize)
        let key = FileKey(name: name.lowercased(), size: size)
        if let handle = resolvedHandles[key] { return handle }

        let clock = ContinuousClock()
        let start = clock.now
        var calls = 0
        var failures: [String] = []
        func found(_ handle: PTPObjectHandle) -> PTPObjectHandle {
            resolvedHandles[key] = handle
            log.note("handle for \(name): \(handle) after \(calls) GetObjectInfo call(s) in \(fmt((clock.now - start).inSeconds, 2)) s (ImageCaptureCore gave 0)")
            return handle
        }

        // Objects already read this session (PTP listing, earlier lookups) need no call.
        let known = ptpObjectInfos.filter { Self.matches($0.value, name: name, size: size) }
        if let handle = known.keys.max(by: { $0.rawValue < $1.rawValue }) { return found(handle) }

        // A cached handle list may predate objects shot since: if nothing in it matches, it is read once more.
        let listWasCached = ptpHandles != nil
        for pass in 0 ..< 2 {
            if pass == 1 {
                guard listWasCached else { break }
                ptpHandles = nil
            }
            let handles = try await objectHandles()
            for handle in handles.sorted(by: { $0.rawValue > $1.rawValue }) where ptpObjectInfos[handle] == nil {
                if stopRequested { throw USBSpikeError.stopped }
                if !isOpen { throw removed ? USBSpikeError.deviceRemoved : USBSpikeError.sessionClosed }
                calls += 1
                progressText = "finding \(name): \(calls) GetObjectInfo"
                do {
                    let info = try await readObjectInfo(handle)
                    if Self.matches(info, name: name, size: size) { return found(handle) }
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    failures.append("\(handle): \(describe(error))")
                    if failures.count >= 3 || linkStalled {
                        throw USBSpikeError.noHandle(name, "GetObjectInfo failed \(failures.count) times: \(failures.prefix(3).joined(separator: "; "))")
                    }
                }
            }
        }

        let sameName = ptpObjectInfos.filter { !$0.value.isFolder && $0.value.filename.caseInsensitiveCompare(name) == .orderedSame }
        let otherSizes = sameName.map { "\($0.key) \($0.value.sizeExceeds32Bits ? "≥ 4 GiB" : "\($0.value.objectCompressedSize) B")" }.sorted()
        var detail = "none of \(ptpHandles?.count ?? 0) PTP objects is \(name) at \(size) B (\(calls) GetObjectInfo call(s) in \(fmt((clock.now - start).inSeconds, 2)) s)"
        if !otherSizes.isEmpty { detail += "; same name, other size: \(otherSizes.joined(separator: ", "))" }
        if !failures.isEmpty { detail += "; \(failures.count) GetObjectInfo failure(s): \(failures.joined(separator: "; "))" }
        throw USBSpikeError.noHandle(name, detail)
    }

    /// Same object: name equal ignoring case, and size equal (ObjectCompressedSize, or its 0xFFFFFFFF sentinel for
    /// a file of 4 GiB or more). Folders (associations) never match.
    nonisolated private static func matches(_ info: PTPObjectInfo, name: String, size: Int64) -> Bool {
        guard !info.isFolder, info.filename.caseInsensitiveCompare(name) == .orderedSame else { return false }
        if info.sizeExceeds32Bits { return size >= Int64(UInt32.max) }
        return Int64(info.objectCompressedSize) == size
    }

    /// GetObjectHandles for every store, once per session (`ptpHandles`).
    private func objectHandles() async throws -> [PTPObjectHandle] {
        if let ptpHandles { return ptpHandles }
        let reply = try await send(PTPCommand.getObjectHandles(storage: .all, tx: tx.take()), timeout: 120)
        try check(reply, "GetObjectHandles")
        let handles = try PTPObjectHandle.decodeArray(reply.data)
        ptpHandles = handles
        return handles
    }

    /// GetObjectInfo for one handle, decoded and cached by handle.
    private func readObjectInfo(_ handle: PTPObjectHandle) async throws -> PTPObjectInfo {
        touchedHandles.insert(handle)
        let reply = try await send(PTPCommand.getObjectInfo(handle, tx: tx.take()))
        try check(reply, "GetObjectInfo \(handle)")
        let info = try PTPObjectInfo.decode(reply.data)
        ptpObjectInfos[handle] = info
        return info
    }

    private func clearPTPCaches() {
        ptpHandles = nil
        ptpObjectInfos.removeAll()
        resolvedHandles.removeAll()
        mtpSummaries.removeAll()
        ptpListingInfos.removeAll()
        sessionPTPListingSeconds = nil
    }

    // MARK: Day 2 · PTP listing

    /// Lists the card ourselves: GetObjectHandles, then GetObjectInfo for every object, timed together, to compare
    /// with ImageCaptureCore's catalogue. Works whether that catalogue is complete or not; fills resolveHandle's caches.
    func ptpListing() async {
        await perform("PTP listing") {
            try requireSession()
            let iccPercentAtStart: Int? = catalogComplete ? nil : device.contentCatalogPercentCompleted
            clearPTPCaches()
            let clock = ContinuousClock()
            let start = clock.now
            let handles = try await objectHandles()
            let handlesSeconds = (clock.now - start).inSeconds
            log.note("  GetObjectHandles: \(handles.count) handles in \(fmt(handlesSeconds, 2)) s; ImageCaptureCore catalogue \(iccPercentAtStart.map { "\($0)%" } ?? "complete")")
            var infos: [PTPObjectHandle: PTPObjectInfo] = [:]
            var failures: [String] = []
            var failuresInARow = 0
            for (index, handle) in handles.enumerated() {
                if stopRequested { throw USBSpikeError.stopped }
                if !isOpen { throw removed ? USBSpikeError.deviceRemoved : USBSpikeError.sessionClosed }
                do {
                    infos[handle] = try await readObjectInfo(handle)
                    failuresInARow = 0
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    failures.append("\(handle): \(describe(error))")
                    failuresInARow += 1
                    if failuresInARow >= 3 || linkStalled {
                        throw USBSpikeError.nothingToDo("GetObjectInfo failed \(failuresInARow) times in a row after \(infos.count) objects: \(failures.suffix(3).joined(separator: "; "))")
                    }
                }
                progressText = "GetObjectInfo \(index + 1)/\(handles.count)"
                if (index + 1) % 50 == 0 { lifecycle.noteProgress("PTP listing \(index + 1)/\(handles.count)", link: "usb") }
            }
            let seconds = (clock.now - start).inSeconds
            ptpListingInfos = infos   // the whole card as listed; GetThumb picks from this

            let folderCount = infos.values.filter { $0.isFolder }.count
            let fileInfos = infos.filter { !$0.value.isFolder }
            let unreadable = failures.isEmpty ? "" : ", \(failures.count) unreadable"
            log.note("PTP listing: \(handles.count) objects (\(fileInfos.count) files, \(folderCount) folders\(unreadable)) in \(fmt(seconds, 2)) s: GetObjectHandles \(fmt(handlesSeconds, 2)) s + \(handles.count) GetObjectInfo")
            let byExtension = Dictionary(grouping: fileInfos.values) { $0.fileExtension }
            for (ext, group) in byExtension.sorted(by: { $0.key < $1.key }) {
                let bytes = group.reduce(UInt64(0)) { $0 + UInt64($1.objectCompressedSize) }
                let large = group.filter { $0.sizeExceeds32Bits }.count
                log.note("  .\(ext.isEmpty ? "?" : ext): \(group.count) files, \(mb(bytes))\(large > 0 ? " (\(large) of 4 GiB or more, counted as 0xFFFFFFFF B)" : "")")
            }
            let newestFirst = fileInfos.sorted { a, b in
                let da = a.value.captureDate ?? .distantPast
                let db = b.value.captureDate ?? .distantPast
                if da != db { return da > db }
                return a.key.rawValue > b.key.rawValue
            }
            for entry in newestFirst.prefix(5) {
                let info = entry.value
                log.note("  \(info.filename) \(entry.key), \(info.sizeExceeds32Bits ? "≥ 4 GiB" : "\(info.objectCompressedSize) B"), captured '\(info.captureDateRaw)', format \(info.objectFormat), parent \(info.parentObject)")
            }
            for failure in failures.prefix(5) { log.warn("  GetObjectInfo failed: \(failure)") }

            let icc: String
            if catalogComplete, let catalogue = sessionCatalogue {
                icc = "ImageCaptureCore \(catalogue.name) \(fmt(catalogue.seconds, 1)) s"
                    + (catalogue.note.isEmpty ? "" : " (\(catalogue.note))")
                    + (iccPercentAtStart.map { ", completed during this listing (\($0)% at its start)" } ?? "")
            } else if catalogComplete {
                icc = "ImageCaptureCore catalogue complete, not timed this session"
            } else {
                icc = "ImageCaptureCore catalogue not complete (\(device.contentCatalogPercentCompleted)%)"
            }
            log.measure("usb.ptp.catalog", seconds, "s",
                        context: "\(handles.count) objects, \(fileInfos.count) files, \(folderCount) folders\(unreadable); GetObjectHandles \(fmt(handlesSeconds, 2)) s; \(icc)")
            log.measure("usb.ptp.catalog.count", Double(handles.count), "objects",
                        context: "\(fileInfos.count) files, \(folderCount) folders\(unreadable)")
            // After clearPTPCaches at the start, which clears both.
            sessionPTPListingSeconds = seconds
            lastResult = "PTP listing: \(handles.count) objects in \(fmt(seconds, 2)) s"
        }
    }

    // MARK: Day 2 · MTP listing (one object at a time)

    /// MTP GetObjectPropList (0x9805) for one object at a time (depth 0, every property), newest handle first, timed
    /// per object, to compare with GetObjectInfo (about 165 ms per object on 1 Nov). On 1 Nov one object answered in
    /// 0.01 s. A single request for the whole card is never sent: ImageCaptureCore ends a pass-through request after
    /// about 60 s, both whole-card forms got no answer, and after one of them the camera answered nothing until it was
    /// replugged. Fills resolveHandle's (name, size) cache and GetThumb's newest-first picks.
    func mtpListing() async {
        await perform("MTP listing (GetObjectPropList per object)") {
            try requireSession()
            let iccAtStart = catalogComplete ? "ImageCaptureCore catalogue complete"
                                             : "ImageCaptureCore catalogue running (\(device.contentCatalogPercentCompleted) % at the start)"
            let touchedBefore = touchedHandles
            let clock = ContinuousClock()
            let start = clock.now
            let handles = try await objectHandles()
            let handlesSeconds = (clock.now - start).inSeconds
            log.note("  GetObjectHandles: \(handles.count) handles in \(fmt(handlesSeconds, 2)) s; \(iccAtStart)")
            var elements: [MTPObjectPropElement] = []
            var summaries: [PTPObjectHandle: MTPObjectSummary] = [:]
            // Untouched by the spike and sent after ImageCaptureCore's catalogue completed; sent while it ran; touched.
            var coldMs: [Double] = []
            var duringCatalogueMs: [Double] = []
            var warmMs: [Double] = []
            var lastHandle: PTPObjectHandle?
            var failures: [String] = []
            var failuresInARow = 0
            var newest50Seconds: Double?
            var newest50Catalogue = ""
            var savedFixture = false
            for (index, handle) in handles.sorted(by: { $0.rawValue > $1.rawValue }).enumerated() {
                if stopRequested { throw USBSpikeError.stopped }
                if !isOpen { throw removed ? USBSpikeError.deviceRemoved : USBSpikeError.sessionClosed }
                if linkStalled {
                    // How far the listing got, before the stall ends it.
                    for failure in failures.suffix(5) { log.warn("  GetObjectPropList failed: \(failure)") }
                    log.warn("  MTP listing stopped by the stall after \(summaries.count) of \(handles.count) objects; the last handle tried was \(lastHandle.map { "\($0)" } ?? "none")")
                    throw USBSpikeError.linkStalled
                }
                if failuresInARow >= 3 {
                    for failure in failures.prefix(5) { log.warn("  GetObjectPropList failed: \(failure)") }
                    throw USBSpikeError.nothingToDo("3 GetObjectPropList requests in a row failed without a response after \(summaries.count) objects: \(failures.suffix(3).joined(separator: "; "))")
                }
                lastHandle = handle
                let catalogueRunning = !catalogComplete
                let requestStart = clock.now
                do {
                    touchedHandles.insert(handle)
                    let reply = try await send(PTPCommand.getObjectPropList(handle: handle, depth: 0, tx: tx.take()), timeout: 10)
                    // Any response shows the camera is answering; only requests with none count toward the stop.
                    failuresInARow = 0
                    let ms = (clock.now - requestStart).inSeconds * 1000
                    if !reply.responseCode.isOK {
                        failures.append("\(handle): \(reply.responseCode)")
                    } else {
                        if touchedBefore.contains(handle) { warmMs.append(ms) }
                        else if catalogueRunning { duringCatalogueMs.append(ms) }
                        else { coldMs.append(ms) }
                        if !savedFixture {
                            savedFixture = true
                            FixtureStore.save(reply.data, link: .usb, name: "objectproplist-one.bin", log: log,
                                              detail: "all properties of the newest object (\(handle)), depth 0")
                        }
                        do {
                            let list = try MTPObjectPropList.decode(reply.data)
                            elements.append(contentsOf: list.elements)
                            if let objectSummary = list.summaries()[handle] { summaries[handle] = objectSummary }
                            if index < 3 { log.note("  \(handle): \(propSummary(list, handle)) in \(fmt(ms)) ms") }
                        } catch {
                            failures.append("\(handle): answered OK with \(reply.data.count) B but didn't decode: \(describe(error)); starts \(reply.data.hexDump(limit: 16))")
                        }
                    }
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    failures.append("\(handle): \(describe(error))")
                    failuresInARow += 1
                }
                if index + 1 == 50 {
                    newest50Seconds = (clock.now - start).inSeconds
                    newest50Catalogue = catalogComplete ? "catalogue complete by the 50th" : "catalogue still running at the 50th"
                }
                progressText = "GetObjectPropList \(index + 1)/\(handles.count)"
                if (index + 1) % 50 == 0 { lifecycle.noteProgress("MTP listing \(index + 1)/\(handles.count)", link: "usb") }
            }
            let seconds = (clock.now - start).inSeconds
            let iccAtEnd = catalogComplete ? "complete at the end" : "still running at the end"
            for failure in failures.prefix(5) { log.warn("  GetObjectPropList failed: \(failure)") }
            guard !summaries.isEmpty else {
                throw USBSpikeError.nothingToDo("no object's properties decoded: \(failures.prefix(3).joined(separator: "; "))")
            }

            let properties = Set(elements.map { $0.property })
            // Without ObjectFormat every summary's isFolder is false: folders would be counted as files.
            let formatKnown = properties.contains(.objectFormat)
            mtpSummaries = formatKnown ? summaries : [:]
            let files = summaries.filter { !$0.value.isFolder }
            let folders = summaries.count - files.count
            var keyed = 0
            for (handle, summary) in files {
                guard let name = summary.filename, let size = summary.size else { continue }
                resolvedHandles[FileKey(name: name.lowercased(), size: Int64(clamping: size))] = handle
                keyed += 1
            }
            let split = formatKnown ? "\(files.count) files, \(folders) folders" : "\(summaries.count) objects (ObjectFormat not sent)"
            log.note("MTP listing: \(split) from \(handles.count) handles in \(fmt(seconds, 2)) s; \(failures.count) failed")
            log.note("  properties sent: " + properties.map { "\($0)" }.sorted().joined(separator: ", "))
            let byExtension = Dictionary(grouping: files.values) { ($0.filename.flatMap { $0.split(separator: ".").last.map(String.init) } ?? "?").uppercased() }
            for (ext, group) in byExtension.sorted(by: { $0.key < $1.key }) {
                log.note("  .\(ext): \(group.count), \(mb(group.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }))")
            }
            if keyed < files.count { log.warn("  \(files.count - keyed) files have no name or size, so they can't be matched to ImageCaptureCore's files") }
            // DeviceInfo for the serial check, after the clock so it can't hold up the listing.
            if deviceInfo == nil {
                do {
                    _ = try await deviceInfoOrFetch()
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    log.warn("  GetDeviceInfo for the serial check failed: \(describe(error))")
                }
            }
            notePersistentIDs(elements, summaries: summaries)

            func stats(_ values: [Double]) -> String {
                guard !values.isEmpty else { return "none" }
                return "\(values.count) at \(fmt(values.reduce(0, +) / Double(values.count))) ms average (min \(fmt(values.min() ?? 0)), max \(fmt(values.max() ?? 0)))"
            }
            let all = coldMs + duringCatalogueMs + warmMs
            let ptp = sessionPTPListingSeconds.map { "PTP listing \(fmt($0, 2)) s this session" } ?? "no PTP listing this session"
            log.measure("usb.mtp.listing", seconds, "s",
                        context: "\(split), one GetObjectPropList per object, newest first; GetObjectHandles \(fmt(handlesSeconds, 2)) s; \(ptp); \(iccAtStart), \(iccAtEnd)")
            if !all.isEmpty {
                log.measure("usb.mtp.proplist.perObject", all.reduce(0, +) / Double(all.count), "ms",
                            context: "untouched, after ImageCaptureCore's catalogue: \(stats(coldMs)); untouched, while it ran: \(stats(duringCatalogueMs)); touched earlier this session (GetObjectInfo, GetThumb, GetPartialObject, a listing): \(stats(warmMs))")
            }
            if let newest50Seconds {
                log.measure("usb.mtp.listing.newest50", newest50Seconds, "s", context: "GetObjectHandles plus the 50 highest handles; \(iccAtStart), \(newest50Catalogue)")
            }
            lastResult = "MTP listing: \(summaries.count) objects in \(fmt(seconds, 2)) s"
        }
    }

    /// One line for an object's decoded properties: name, size, date, format.
    private func propSummary(_ list: MTPObjectPropList, _ handle: PTPObjectHandle) -> String {
        guard let s = list.summaries()[handle] else { return "\(list.elements.count) properties, no summary" }
        return "\(s.filename ?? "?"), \(s.size.map { "\($0) B" } ?? "no size"), created '\(s.dateCreatedRaw ?? "")', format \(s.format.map { "\($0)" } ?? "?"), \(list.elements.count) properties"
    }

    /// PersistentUniqueObjectIdentifier (0xDC41): whether every file has one, whether they are unique, whether any
    /// contains the camera's serial number (then objectproplist fixtures must not be committed as they are), and
    /// whether each file keeps its ID across sessions. The IDs never reach the log: only a keyed tag of each is kept
    /// (CameraSerialTag's per-install key), by file name and size, in UserDefaults.
    private func notePersistentIDs(_ elements: [MTPObjectPropElement], summaries: [PTPObjectHandle: MTPObjectSummary]) {
        var ids: [PTPObjectHandle: Data] = [:]
        for element in elements where element.property == .persistentUniqueObjectIdentifier {
            switch element.value {
            case .uint128(let bytes), .int128(let bytes): ids[element.handle] = bytes
            case .uint(let v): ids[element.handle] = withUnsafeBytes(of: v.littleEndian) { Data($0) }
            default: break
            }
        }
        guard !ids.isEmpty else {
            log.note("  PersistentUniqueObjectIdentifier: not sent")
            return
        }
        let unique = Set(ids.values).count
        var serialFound = "not checked (no DeviceInfo this session)"
        if let serial = deviceInfo?.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines), !serial.isEmpty {
            // The serial as sent and without leading zeros (at least 6 characters, so a short tail can't match by
            // chance), each as ASCII, as UTF-16LE, and as text inside the ID's hex in either byte order.
            let significant = String(serial.drop { $0 == "0" })
            let forms = Set([serial, significant].filter { $0.count >= 6 }.map { $0.lowercased() })
            let hit = ids.values.contains { id in
                let hex = id.map { String(format: "%02x", $0) }.joined()
                let reversedHex = Data(id.reversed()).map { String(format: "%02x", $0) }.joined()
                return forms.contains { form in
                    id.range(of: Data(form.utf8)) != nil || id.range(of: Data(form.uppercased().utf8)) != nil
                        || id.range(of: Data(form.uppercased().utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) != nil
                        || hex.contains(form) || reversedHex.contains(form)
                }
            }
            serialFound = hit ? "YES" : forms.isEmpty ? "not checked (serial shorter than 6 characters)" : "not found as text or hex (it could still be encoded some other way)"
        }
        let key = "spike.mtp.persistentIDTags"
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        var updated = stored
        var same = 0, changed = 0, unseen = 0
        for (handle, id) in ids {
            guard let s = summaries[handle], let name = s.filename, let size = s.size else { continue }
            let fileKey = "\(name.lowercased())|\(size)"
            let tag = CameraSerialTag.tag(bytes: id)
            if let previous = stored[fileKey] {
                if previous == tag { same += 1 } else { changed += 1 }
            } else {
                unseen += 1
            }
            updated[fileKey] = tag
        }
        if updated.count <= 5_000 { UserDefaults.standard.set(updated, forKey: key) }
        log.note("  PersistentUniqueObjectIdentifier: \(ids.count) of \(summaries.count) objects, \(unique) distinct, \(ids.values.first.map { "\($0.count) B" } ?? "?") each; contains the camera's serial: \(serialFound); against earlier listings on this phone: \(same) same, \(changed) changed, \(unseen) not seen before. Findings-page fact (identity across sessions).")
    }

    // MARK: Day 2 · thumbnails over PTP

    /// GetThumb (0x100A) for the newest files, timed, to compare with ImageCaptureCore's requestThumbnailData
    /// (usb.thumb.avg). Picks the newest files from a PTP listing, or an MTP listing with object formats, if one
    /// finished this session, otherwise the highest handles; doesn't need ImageCaptureCore's catalogue.
    func ptpThumbnails(count: Int = 50) async {
        await perform("GetThumb, \(count) newest (PTP)") {
            try requireSession()
            let iccAtStart = catalogComplete ? "ImageCaptureCore catalogue complete" : "ImageCaptureCore catalogue running (\(device.contentCatalogPercentCompleted) % at the start)"
            let highestHandles = "the highest handles (no finished listing with object formats this session, so folders may be among them)"
            let picks: [PTPObjectHandle]
            let source: String
            // Only a finished listing: ptpObjectInfos may hold just what resolveHandle or a stopped listing read.
            if !ptpListingInfos.isEmpty {
                picks = ptpListingInfos.filter { !$0.value.isFolder }
                    .sorted { ($0.value.captureDate ?? .distantPast, $0.key.rawValue) > ($1.value.captureDate ?? .distantPast, $1.key.rawValue) }
                    .prefix(count).map { $0.key }
                source = "the PTP listing"
            } else if !mtpSummaries.isEmpty {
                picks = mtpSummaries.filter { !$0.value.isFolder }
                    .sorted { ($0.value.dateCreated ?? .distantPast, $0.key.rawValue) > ($1.value.dateCreated ?? .distantPast, $1.key.rawValue) }
                    .prefix(count).map { $0.key }
                source = "the MTP listing"
            } else {
                let handles = try await objectHandles()
                picks = Array(handles.sorted { $0.rawValue > $1.rawValue }.prefix(count))
                source = highestHandles
            }
            guard !picks.isEmpty else { throw USBSpikeError.nothingToDo("no objects to fetch thumbnails for") }
            if picks.count < count && source != highestHandles {
                log.warn("  only \(picks.count) files in \(source), fewer than the \(count) asked for: usb.ptp.thumb.avg will average \(picks.count)")
            }
            log.note("  GetThumb for \(picks.count) objects from \(source)")
            let clock = ContinuousClock()
            var times: [Double] = []
            var bytes = 0
            var failures: [String] = []
            var failuresInARow = 0
            for (index, handle) in picks.enumerated() {
                if stopRequested { throw USBSpikeError.stopped }
                if !isOpen { throw removed ? USBSpikeError.deviceRemoved : USBSpikeError.sessionClosed }
                if linkStalled { throw USBSpikeError.linkStalled }
                if failuresInARow >= 3 {
                    for failure in failures.prefix(5) { log.warn("  GetThumb failed: \(failure)") }
                    throw USBSpikeError.nothingToDo("3 GetThumb requests in a row got no answer, so the run stopped: \(failures.suffix(3).joined(separator: "; "))")
                }
                let start = clock.now
                do {
                    touchedHandles.insert(handle)
                    let reply = try await send(PTPCommand.getThumb(handle, tx: tx.take()), timeout: 10)
                    // Any response, OK or not, shows the camera is answering: a folder among the highest handles
                    // answers NoThumbnailPresent in milliseconds and must not end the run.
                    failuresInARow = 0
                    guard reply.responseCode.isOK else {
                        failures.append("\(handle): \(reply.responseCode)")
                        continue
                    }
                    let ms = (clock.now - start).inSeconds * 1000
                    times.append(ms)
                    bytes += reply.data.count
                    if index < 3 { log.note("  GetThumb \(handle): \(reply.data.count) B in \(fmt(ms)) ms, starts \(reply.data.hexDump(limit: 4))") }
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    failures.append("\(handle): \(describe(error))")
                    failuresInARow += 1
                }
                progressText = "\(index + 1)/\(picks.count)"
            }
            for failure in failures.prefix(5) { log.warn("  GetThumb failed: \(failure)") }
            guard !times.isEmpty else { throw USBSpikeError.nothingToDo("every GetThumb failed: \(failures.prefix(3).joined(separator: "; "))") }
            let avg = times.reduce(0, +) / Double(times.count)
            log.measure("usb.ptp.thumb.avg", avg, "ms",
                        context: "\(times.count) of \(picks.count) from \(source) ok, min \(fmt(times.min() ?? 0)) max \(fmt(times.max() ?? 0)) ms, avg \(bytes / max(times.count, 1) / 1000) KB; \(iccAtStart) [\(lifecycle.stateDescription)]")
            lastResult = "GetThumb: \(fmt(avg)) ms average"
        }
    }

    // MARK: Day 4 · battery

    /// GetDevicePropValue(BatteryLevel 0x5001); ISO 15740 types it UINT8 (0–100).
    private func readBattery() async throws -> Int {
        let reply = try await send(PTPCommand.getDevicePropValue(.batteryLevel, tx: tx.take()))
        try check(reply, "GetDevicePropValue(BatteryLevel 0x5001)")
        var reader = PTPReader(reply.data)
        let value = try reader.u8()
        if reply.data.count != 1 {
            log.warn("BatteryLevel value is \(reply.data.count) bytes, expected one UINT8: \(reply.data.hexDump(limit: 8))")
        }
        return Int(value)
    }

    /// PTP BatteryLevel, or ImageCaptureCore's batteryLevel when the property read fails.
    private func batteryLevel() async throws -> (percent: Int, source: String) {
        do {
            return (try await readBattery(), "PTP 0x5001")
        } catch {
            if removed { throw USBSpikeError.deviceRemoved }
            guard device.batteryLevelAvailable else {
                throw USBSpikeError.nothingToDo("GetDevicePropValue(BatteryLevel) failed (\(describe(error))) and ImageCaptureCore has no battery level")
            }
            log.warn("GetDevicePropValue(BatteryLevel) failed (\(describe(error))); using ImageCaptureCore batteryLevel")
            return (device.batteryLevel, "ImageCaptureCore")
        }
    }

    func batteryPerGB(targetGB: Int) async {
        await perform("Battery per GB") {
            try requireOpen()
            let pool = files.filter { $0.fileSize > 0 }
            guard !pool.isEmpty else { throw USBSpikeError.nothingToDo("no files on the card") }
            let target = Int64(max(targetGB, 1)) * 1_000_000_000
            let largest = pool.map { Int64($0.fileSize) }.max() ?? 0
            try ensureFreeSpace(for: largest)
            let first = try await batteryLevel()
            let before = first.percent
            let iccBefore = device.batteryLevelAvailable ? "\(device.batteryLevel)%" : "not available"
            log.note("Battery before: \(before)% (\(first.source)); ImageCaptureCore batteryLevel \(iccBefore). Downloading at least \(mb(target)), each copy deleted after it lands…")
            let dir = try freshDirectory("Battery")
            defer { try? FileManager.default.removeItem(at: dir) }
            let clock = ContinuousClock()
            let start = clock.now
            var bytes: Int64 = 0
            var count = 0
            while bytes < target {
                if stopRequested { throw USBSpikeError.stopped }
                if !isOpen { throw removed ? USBSpikeError.deviceRemoved : USBSpikeError.sessionClosed }
                let file = pool[count % pool.count]
                let downloaded = try await downloadFile(file, to: dir)
                try? FileManager.default.removeItem(at: downloaded.url)
                bytes += downloaded.bytes
                count += 1
                lifecycle.noteProgress("battery run \(mb(bytes))", link: "usb")
                progressText = "\(mb(bytes)) of \(mb(target))"
                if count % 10 == 0 { log.note("  \(count) files, \(mb(bytes)) [\(lifecycle.stateDescription)]") }
            }
            let seconds = (clock.now - start).inSeconds
            let last = try await batteryLevel()
            let after = last.percent
            if last.source != first.source {
                throw USBSpikeError.nothingToDo("battery read from \(first.source) before and \(last.source) after; not comparable, run it again")
            }
            let iccAfter = device.batteryLevelAvailable ? "\(device.batteryLevel)%" : "not available"
            let gigabytes = Double(bytes) / 1_000_000_000
            let perGB = Double(before - after) / gigabytes
            log.measure("usb.battery.per1GB", perGB, "%/GB",
                        context: "\(before)% → \(after)% (\(first.source)) over \(fmt(gigabytes, 2)) GB (\(count) files, \(fmt(seconds, 0)) s); ImageCaptureCore \(iccBefore) → \(iccAfter); USB Power Supply must be Off")
            if before == after { log.warn("No change at 1 % resolution: repeat with a larger size for a usable figure.") }
            lastResult = "Battery: \(fmt(perGB, 2)) %/GB"
        }
    }

    // MARK: Day 4 · GetPartialObject vs requestReadData vs requestDownload

    func getPartialObjectTest() async {
        await perform("GetPartialObject, newest ARW") {
            try requireOpen()
            guard let file = newest("ARW", 1).first else { throw USBSpikeError.nothingToDo("no ARW on the card") }
            let name = file.name ?? "?"
            let size = UInt64(max(0, file.fileSize))
            guard size > 0 else { throw USBSpikeError.nothingToDo("\(name) reports size 0") }
            let info = try await deviceInfoOrFetch()
            let variant = chooseVariant(size: size, info: info)
            let handle = try await resolveHandle(for: file)
            // The reassembly is kept and the requestDownload reference lands beside it.
            try ensureFreeSpace(for: Int64(size) * 2)
            let dir = try freshDirectory("GetPartialObject")
            let partURL = dir.appendingPathComponent(USBResumePaths.sanitised(name))

            // 1. GetPartialObject, 4 MiB chunks, streamed to disk.
            log.note("1/3 GetPartialObject (\(variant.rawValue), 4 MiB chunks) of \(name), \(mb(size))…")
            let writer = try PartFileWriter(url: partURL, startingAt: 0)
            let gpo = await partialReadLoop(handle: handle, name: name, size: size,
                                            from: 0, variant: variant, chunkSize: PTPPartialRead.defaultChunkSize,
                                            pause: nil, writer: writer, label: "GetPartialObject") { _, _ in }
            writer.close()
            if let interruption = gpo.error as? USBSpikeError {
                switch interruption {
                case .stopped, .deviceRemoved, .sessionClosed, .sessionReplaced:
                    log.warn("GetPartialObject interrupted at \(gpo.offset) of \(size) bytes (\(interruption.description)); usb.getPartialObject.supported not recorded")
                    throw interruption
                case .ptp(_, let code) where code == .invalidTransactionID:
                    // Our transaction numbering versus ImageCaptureCore's, not the camera refusing the operation:
                    // recording "unsupported" here would put a harness problem into the go/no-go table.
                    log.warn("GetPartialObject got InvalidTransactionID at \(gpo.offset) of \(size) bytes; usb.getPartialObject.supported not recorded (a transaction-ID problem in the pass-through, not an answer about the camera)")
                    throw interruption
                default:
                    break
                }
            }
            let complete = gpo.error == nil && gpo.offset == size
            var gpoSHA: String?
            if complete {
                gpoSHA = try sha256(of: partURL)
                log.throughput("usb.getPartialObject.throughput", bytes: Int(gpo.bytesThisRun), seconds: gpo.seconds,
                               context: "\(name), \(variant.rawValue), 4 MiB chunks [\(lifecycle.stateDescription)]")
                log.note("  reassembled file kept at Caches/Spike/GetPartialObject/\(partURL.lastPathComponent)")
            } else {
                log.error("GetPartialObject stopped at \(gpo.offset) of \(size) bytes: \(gpo.error.map { describe($0) } ?? "short read")")
            }
            // "No" only when the camera itself answered the first chunk with a non-OK response, or OK with no bytes
            // (same rule as the Wi-Fi path). Timeouts, pass-through decode failures, local write errors and failures
            // after good chunks are not an answer about the camera.
            var cameraRefused = false
            if gpo.offset == 0, let e = gpo.error as? USBSpikeError {
                switch e {
                case .ptp, .noData: cameraRefused = true
                default: break
                }
            }
            if complete || cameraRefused {
                log.flag("usb.getPartialObject.supported", complete,
                         context: complete ? "\(name) fully reassembled with \(variant.rawValue)"
                                           : "\(variant.rawValue) refused on the first chunk: \(gpo.error.map { describe($0) } ?? "short read")")
            } else {
                log.warn("usb.getPartialObject.supported not recorded: \(variant.rawValue) failed at \(gpo.offset)/\(size) with \(gpo.error.map { describe($0) } ?? "short read"), which is not the camera refusing the operation. Re-run, or try Start resumable read (1 MiB chunks).")
            }
            if removed { throw USBSpikeError.deviceRemoved }
            if linkStalled { throw USBSpikeError.linkStalled }

            // 2. requestReadData, same chunk size.
            log.note("2/3 requestReadData (4 MiB chunks) of \(name)…")
            var readSHA: String?
            do {
                readSHA = try await readDataSHA(file, measure: true).sha
            } catch let interruption as USBSpikeError where interruption.isInterruption {
                // Stop or a cable pull: don't go on to write a .sha256 fixture whose references say "failed".
                throw interruption
            } catch {
                log.error("requestReadData failed: \(describe(error))")
            }

            // 3. requestDownload of the same file: the throughput reference and a second SHA. Skipped straight after
            // a request that got no answer, and bounded (about 1 s for an ARW at 1 Nov's 38 MB/s), because Stop
            // can't end a requestDownload.
            if linkStalled { throw USBSpikeError.linkStalled }
            let skipReference = consecutiveNoAnswers > 0
            if skipReference {
                log.warn("3/3 requestDownload of \(name) skipped: the last request got no answer")
            } else {
                log.note("3/3 requestDownload of \(name)…")
            }
            var downloadSHA: String?
            var downloadMBps: Double?
            if !skipReference {
                do {
                    let referenceDir = dir.appendingPathComponent("reference", isDirectory: true)
                    try FileManager.default.createDirectory(at: referenceDir, withIntermediateDirectories: true)
                    let downloaded = try await downloadFile(file, to: referenceDir, timeout: max(60, Double(size) / 5_000_000))
                    log.throughput("usb.download.file", bytes: Int(downloaded.bytes), seconds: downloaded.seconds,
                                   context: "\(name), reference copy for the GetPartialObject comparison [\(lifecycle.stateDescription)]")
                    if downloaded.seconds > 0 { downloadMBps = Double(downloaded.bytes) / downloaded.seconds / 1_000_000 }
                    downloadSHA = try sha256(of: downloaded.url)
                    try? FileManager.default.removeItem(at: referenceDir)
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    log.error("requestDownload failed: \(describe(error))")
                }
            }

            guard let gpoSHA else {
                log.warn("usb.getPartialObject.sha256Match not recorded: there is no complete GetPartialObject reassembly to compare.")
                lastResult = cameraRefused ? "GetPartialObject: not supported here" : "GetPartialObject: incomplete"
                return
            }
            var references: [(String, String)] = []
            if let readSHA { references.append(("requestReadData", readSHA)) }
            if let downloadSHA { references.append(("requestDownload", downloadSHA)) }
            log.note("  GetPartialObject SHA-256 \(gpoSHA)")
            for (source, sha) in references { log.note("  \(source) SHA-256 \(sha): \(sha == gpoSHA ? "MATCH" : "MISMATCH")") }
            var matched = false
            if references.isEmpty {
                log.warn("usb.getPartialObject.sha256Match not recorded: both reference reads failed.")
            } else {
                matched = references.allSatisfy { $0.1 == gpoSHA }
                log.flag("usb.getPartialObject.sha256Match", matched,
                         context: "\(name): " + references.map { "\($0.0) \($0.1 == gpoSHA ? "MATCH" : "MISMATCH")" }.joined(separator: ", "))
            }
            let fixture = """
            \(gpoSHA)  \(name)
            # \(name), \(size) bytes, captured over USB with GetPartialObject (\(variant.rawValue), 4 MiB chunks)
            # getPartialObject SHA-256 \(gpoSHA)
            # requestReadData  SHA-256 \(readSHA ?? "failed")
            # requestDownload  SHA-256 \(downloadSHA ?? "failed")

            """
            FixtureStore.saveText(fixture, link: .usb, name: "getpartialobject-\(USBResumePaths.sanitised(name)).sha256", log: log)

            if gpo.seconds > 0 {
                let gpoMBps = Double(gpo.bytesThisRun) / gpo.seconds / 1_000_000
                if let downloadMBps, downloadMBps > 0 {
                    let diff = (gpoMBps - downloadMBps) / downloadMBps * 100
                    log.note("GetPartialObject \(fmt(gpoMBps)) MB/s vs requestDownload \(fmt(downloadMBps)) MB/s of the same file: \(String(format: "%+.1f", diff)) % → \(abs(diff) <= 15 ? "PASS" : "FAIL") (criterion: within 15 %)")
                }
                if let serial = lastSerialARWThroughput, serial > 0 {
                    let diff = (gpoMBps - serial) / serial * 100
                    log.note("  vs this session's Day 3 ARW serial batch (\(fmt(serial)) MB/s): \(String(format: "%+.1f", diff)) %")
                }
                lastResult = "GetPartialObject \(fmt(gpoMBps)) MB/s, SHA \(references.isEmpty ? "unchecked" : (matched ? "match" : "MISMATCH"))"
            }
        }
    }

    private func chooseVariant(size: UInt64, info: PTPDeviceInfo) -> PTPPartialRead.Variant {
        if let variant = PTPPartialRead.variant(objectSize: size, device: info) { return variant }
        log.warn("DeviceInfo lists neither GetPartialObject (0x101B) nor GetPartialObject64 (0x95C1); trying 0x101B anyway.")
        return .standard32
    }

    private struct PartialReadResult {
        var offset: UInt64
        var bytesThisRun: UInt64
        /// Request → bytes on disk, summed over chunks: excludes pacing pauses and log lines.
        var seconds: Double
        var error: Error?
    }

    /// GetPartialObject from `start` to the end of the object, appending to `writer`. Returns at the first error,
    /// cable pull or Stop with the offset reached; `onChunk(previous, current)` runs after each chunk is on disk.
    private func partialReadLoop(handle: PTPObjectHandle, name: String, size: UInt64, from start: UInt64,
                                 variant: PTPPartialRead.Variant, chunkSize: UInt32, pause: Duration?,
                                 writer: PartFileWriter, label: String,
                                 onChunk: (_ previous: UInt64, _ current: UInt64) -> Void) async -> PartialReadResult {
        var offset = start
        var seconds = 0.0
        var warnedAboutParameter = false
        let clock = ContinuousClock()
        while let chunk = PTPPartialRead.nextChunk(at: offset, objectSize: size, chunkSize: chunkSize) {
            if stopRequested {
                return PartialReadResult(offset: offset, bytesThisRun: offset - start, seconds: seconds, error: USBSpikeError.stopped)
            }
            if removed {
                return PartialReadResult(offset: offset, bytesThisRun: offset - start, seconds: seconds, error: USBSpikeError.deviceRemoved)
            }
            if !isOpen {
                return PartialReadResult(offset: offset, bytesThisRun: offset - start, seconds: seconds, error: USBSpikeError.sessionClosed)
            }
            if linkStalled {
                return PartialReadResult(offset: offset, bytesThisRun: offset - start, seconds: seconds, error: USBSpikeError.linkStalled)
            }
            let chunkStart = clock.now
            do {
                touchedHandles.insert(handle)
                let command = try PTPPartialRead.command(handle, chunk: chunk, variant: variant, tx: tx.take())
                let reply = try await send(command, timeout: 60)
                try check(reply, "\(label) at \(chunk.offset)")
                var bytes = reply.data
                guard !bytes.isEmpty else { throw USBSpikeError.noData("\(label) at offset \(chunk.offset)") }
                if bytes.count > Int(chunk.length) {
                    log.warn("\(label): \(bytes.count) B for a \(chunk.length)-byte request at \(chunk.offset); keeping \(chunk.length)")
                    bytes = Data(bytes.prefix(Int(chunk.length)))
                }
                if !warnedAboutParameter, let sent = reply.response.parameters.first, Int(sent) != reply.data.count {
                    warnedAboutParameter = true
                    log.warn("\(label): response parameter 1 says \(sent) B, the data phase holds \(reply.data.count) B")
                }
                try writer.append(bytes)
                seconds += (clock.now - chunkStart).inSeconds
                let previous = offset
                offset += UInt64(bytes.count)
                onChunk(previous, offset)
            } catch {
                seconds += (clock.now - chunkStart).inSeconds
                return PartialReadResult(offset: offset, bytesThisRun: offset - start, seconds: seconds, error: error)
            }
            lifecycle.noteProgress("\(label) \(name) \(offset)/\(size)", link: "usb")
            progressText = "\(label): \(percent(offset, size)) %"
            log.note("  \(label) \(name): \(offset)/\(size) B (\(percent(offset, size)) %) [\(lifecycle.stateDescription)]")
            if let pause { try? await Task.sleep(for: pause) }
        }
        return PartialReadResult(offset: offset, bytesThisRun: offset - start, seconds: seconds, error: nil)
    }

    /// requestReadData over the whole file in 4 MiB chunks, hashing as it goes. Records usb.readData.throughput
    /// when `measure` is set (time is the sum of the reads themselves).
    private func readDataSHA(_ file: ICCameraFile, measure: Bool) async throws -> (sha: String, bytes: UInt64, seconds: Double) {
        let name = file.name ?? "?"
        let size = UInt64(max(0, file.fileSize))
        let chunk = UInt64(PTPPartialRead.defaultChunkSize)
        var hasher = SHA256()
        var offset: UInt64 = 0
        var seconds = 0.0
        let clock = ContinuousClock()
        while offset < size {
            if stopRequested { throw USBSpikeError.stopped }
            if !isOpen { throw removed ? USBSpikeError.deviceRemoved : USBSpikeError.sessionClosed }
            if linkStalled { throw USBSpikeError.linkStalled }
            let length = min(chunk, size - offset)
            let readOffset = off_t(offset)
            let readLength = off_t(length)
            let start = clock.now
            var data: Data
            do {
                // Well under ImageCaptureCore's own limit (about 60 s on 1 Nov), so this counted timeout fires
                // first; a healthy 4 MiB chunk takes a fraction of a second.
                data = try await callback("requestReadData", timeout: 30) { done in
                    file.requestReadData(atOffset: readOffset, length: readLength) { bytes, error in
                        if let error { done(.failure(error)) }
                        else if let bytes, !bytes.isEmpty { done(.success(bytes)) }
                        else { done(.failure(USBSpikeError.noData("requestReadData"))) }
                    }
                }
            } catch let error as USBSpikeError {
                if case .timedOut = error { noteNoAnswer("requestReadData") }
                throw error
            }
            consecutiveNoAnswers = 0
            seconds += (clock.now - start).inSeconds
            if UInt64(data.count) > length {
                log.warn("requestReadData returned \(data.count) B for \(length) B at \(offset); keeping \(length)")
                data = Data(data.prefix(Int(length)))
            }
            hasher.update(data: data)
            offset += UInt64(data.count)
            lifecycle.noteProgress("requestReadData \(name) \(offset)/\(size)", link: "usb")
            progressText = "requestReadData: \(percent(offset, size)) %"
            log.note("  requestReadData \(name): \(offset)/\(size) B (\(percent(offset, size)) %) [\(lifecycle.stateDescription)]")
        }
        let sha = hexString(hasher.finalize())
        if measure {
            log.throughput("usb.readData.throughput", bytes: Int(offset), seconds: seconds,
                           context: "\(name), 4 MiB chunks [\(lifecycle.stateDescription)]")
        }
        return (sha, offset, seconds)
    }

    // MARK: Day 4 · events

    /// Day 4 shutter test: watch for a new-object event for `seconds`, then record usb.event.objectAdded either way.
    func watchForObjectAdded(seconds: Int = 60) async {
        await perform("Watch for ObjectAdded") {
            try requireSession()
            // cameraDevice(_:didAdd:) ignores items until the catalogue is complete, so "none" would mean nothing then.
            let iccTracked = catalogComplete
            let started = Date()
            newObjectEventAt = nil
            iccAddedAfterCatalogue = []
            log.note("Press the shutter now (watching \(seconds) s for ObjectAdded 0x4002 or Sony 0xC201).")
            while newObjectEventAt == nil {
                let elapsed = Date().timeIntervalSince(started)
                if elapsed >= Double(seconds) { break }
                if stopRequested { throw USBSpikeError.stopped }
                if removed { throw USBSpikeError.deviceRemoved }
                progressText = "\(Int(Double(seconds) - elapsed)) s left; press the shutter"
                try? await Task.sleep(for: .milliseconds(200))
            }
            let iccNote: String
            if !iccTracked {
                iccNote = "ImageCaptureCore didAdd: not tracked (catalogue incomplete when the watch started)"
                    + (iccAddedAfterCatalogue.isEmpty ? "" : "; added after it completed: \(iccAddedAfterCatalogue.joined(separator: ", "))")
            } else {
                iccNote = iccAddedAfterCatalogue.isEmpty
                    ? "ImageCaptureCore didAdd: none"
                    : "ImageCaptureCore didAdd: \(iccAddedAfterCatalogue.joined(separator: ", "))"
            }
            let sources = eventSourceCounts.isEmpty ? "none" : eventSourceCounts.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
            if let at = newObjectEventAt {
                log.note("New-object event \(fmt(at.timeIntervalSince(started))) s after the watch started. \(iccNote). Events this session by source: \(sources).")
                lastResult = "ObjectAdded received"
            } else if objectAddedFlagged || log.measurements.contains(where: { $0.name == "usb.event.objectAdded" && $0.value == 1 }) {
                // ObjectAdded is a property of the camera mode, not of one session: a timeout after an earlier yes
                // (this session, an earlier session or an earlier launch) must not overwrite it with no.
                log.note("No new-object event in this window (one was recorded earlier). \(iccNote). Events by source: \(sources).")
                lastResult = "No ObjectAdded this time"
            } else {
                log.flag("usb.event.objectAdded", false,
                         context: "no ObjectAdded (0x4002/0xC201) within \(seconds) s of the shutter test; \(iccNote); PTP events by source: \(sources)")
                lastResult = "No ObjectAdded"
            }
        }
    }

    private func receiveEvent(_ data: Data, source: String) {
        let now = Date()
        recentEvents.removeAll { now.timeIntervalSince($0.at) > 2 }
        if let first = recentEvents.first(where: { $0.data == data && $0.source != source }) {
            log.note("PTP event also delivered via \(source) (first via \(first.source)); duplicate ignored")
            return
        }
        recentEvents.append(RecentEvent(data: data, at: now, source: source))
        eventSourceCounts[source, default: 0] += 1

        guard let decoded = try? PTPContainer.decode(data) else {
            log.warn("PTP event via \(source) is not a container: \(data.hexDump())")
            return
        }
        let event = decoded.container
        if event.type != .event { log.warn("PTP event via \(source) has container type \(event.type)") }
        let code = event.eventCode
        log.note("PTP event via \(source): \(code) \(hex16(event.code)), transaction \(event.transactionID), parameters [\(event.parameters.map { hex32($0) }.joined(separator: ", "))] [\(lifecycle.stateDescription)]")
        if code.signalsNewObject {
            newObjectEventAt = now
            if !objectAddedFlagged {
                objectAddedFlagged = true
                FixtureStore.save(data, link: .usb, name: "event-objectadded.bin", log: log)
                log.flag("usb.event.objectAdded", true,
                         context: "\(code) \(hex16(event.code)) via \(source), handle \(event.parameters.first.map { hex32($0) } ?? "none")")
            }
        } else if !savedEventCodes.contains(event.code) {
            savedEventCodes.insert(event.code)
            FixtureStore.save(data, link: .usb, name: String(format: "event-%04x.bin", event.code), log: log)
        }
    }

    // MARK: - Resume over USB (pure half in USBResume.swift)

    /// Paced so there is time to pull the cable: 1 MiB chunks, 0.4 s apart (a 35 MB ARW takes about 15 s).
    func startResumableRead() async {
        await perform("Start resumable read") {
            try requireOpen()
            guard let file = newest("ARW", 1).first else { throw USBSpikeError.nothingToDo("no ARW on the card") }
            let info = try await deviceInfoOrFetch()
            let serial = cameraSerial(info)
            let objectInfo = try await objectInfo(for: file, saveFixture: false, compare: false)
            let handle = try await resolveHandle(for: file)   // cached by objectInfo(for:)
            let identity = objectInfo.identity(cameraSerial: serial)
            guard identity.size > 0, objectInfo.objectCompressedSize != UInt32.max else {
                throw USBSpikeError.nothingToDo("ObjectInfo size \(objectInfo.objectCompressedSize) is not usable for this test")
            }
            if identity.size != UInt64(max(0, file.fileSize)) {
                log.warn("ObjectInfo size \(identity.size) ≠ ICCameraFile size \(file.fileSize)")
            }
            let variant = chooseVariant(size: identity.size, info: info)
            let relative = USBResumePaths.relativePartPath(serial: serial, filename: objectInfo.filename)
            let writer = try PartFileWriter(url: USBResumePaths.url(relative: relative), startingAt: 0)
            // Only one saved read is kept: say so if an unfinished one is replaced, and don't orphan another file's .part.
            if let previous = USBResumeStore.load() {
                if previous.offset < previous.identity.size {
                    log.warn("Replacing the saved read of \(previous.identity.filename) at \(fmt(previous.percent, 0)) % (\(previous.reason)); its resume is discarded")
                }
                if previous.partPath != relative {
                    try? FileManager.default.removeItem(at: USBResumePaths.url(relative: previous.partPath))
                    log.note("Discarded the earlier .part \((previous.partPath as NSString).lastPathComponent)")   // a build-3 path holds the raw serial
                }
            }
            var state = USBResumeState(identity: identity, offset: 0, partPath: relative, savedAt: Date(), reason: "started",
                                       sessionID: sessionID)
            persistResume(state)

            let chunkSize: UInt32 = 1024 * 1024
            let pullAt = identity.size * 2 / 5
            let estimate = Double(identity.size) / Double(chunkSize) * 0.45
            log.note("Resumable read of \(identity) into Caches/\(relative), \(variant.rawValue), 1 MiB chunks 0.4 s apart (about \(Int(estimate)) s). Pull the USB-C cable when the log says PULL NOW.")
            let result = await partialReadLoop(handle: handle, name: identity.filename,
                                               size: identity.size, from: 0, variant: variant, chunkSize: chunkSize,
                                               pause: .milliseconds(400), writer: writer, label: "resumable read") { previous, current in
                if previous < pullAt && current >= pullAt {
                    self.log.warn("PULL NOW: pull the USB-C cable out (offset \(current) of \(identity.size))")
                }
                if PTPPartialRead.crossesCheckpoint(from: previous, to: current) {
                    try? writer.flush()
                    state.offset = current
                    state.reason = "checkpoint"
                    state.savedAt = Date()
                    self.persistResume(state)
                    self.log.note("  checkpoint saved at offset \(current)")
                }
            }
            writer.close()
            state.offset = writer.offset
            state.savedAt = Date()
            if let error = result.error {
                state.reason = "error: \(describe(error))"
                persistResume(state)
                log.warn("Resumable read interrupted at offset \(writer.offset) of \(identity.size) (\(percent(writer.offset, identity.size)) %): \(describe(error)). Saved for resume. Plug the camera back in, Day 2 · Open session, then Resume read.")
                lastResult = "Interrupted at \(percent(writer.offset, identity.size)) %; saved"
            } else {
                state.reason = "complete"
                persistResume(state)
                log.warn("The read finished without an interruption, so there is nothing to resume. Start again and pull the cable at PULL NOW.")
                lastResult = "Finished without interruption"
            }
        }
    }

    func resumeRead() async {
        await perform("Resume read") {
            try requireOpen()
            guard let saved = USBResumeStore.load() else {
                throw USBSpikeError.nothingToDo("no saved read; tap Start resumable read first")
            }
            guard saved.offset < saved.identity.size else {
                throw USBSpikeError.nothingToDo("the saved read of \(saved.identity.filename) completed without an interruption; start a new one and pull the cable at PULL NOW")
            }
            log.note("Saved read: \(saved.identity), offset \(saved.offset) (\(fmt(saved.percent, 0)) %), \(saved.reason), saved \(saved.savedAt.formatted(date: .omitted, time: .standard))")
            let info = try await deviceInfoOrFetch()
            let serial = cameraSerial(info)
            if serial != saved.identity.cameraSerial {
                log.warn("The camera's serial differs from the saved read's: the identity check will restart from zero.")
            }

            // Handles are not stable across sessions: find candidates by name, then confirm the identity (capture date
            // and size, both from GetObjectInfo like the saved one) per candidate. Matching on ICCameraFile.fileSize
            // here would compare ImageCaptureCore's size with ObjectInfo's and could miss the object.
            // When ImageCaptureCore gives handle 0 (MTP mode), each candidate's handle comes from resolveHandle, which
            // does match on name and ImageCaptureCore's size; a candidate it can't place is skipped with a warning
            // (the error names any same-name object of another size), and the identity check below still decides.
            let candidates = files.filter { ($0.name ?? "") == saved.identity.filename }
            guard !candidates.isEmpty else {
                throw USBSpikeError.nothingToDo("\(saved.identity.filename) is not on the card any more; Forget saved read")
            }
            var match: (file: ICCameraFile, handle: PTPObjectHandle, identity: PTPObjectIdentity)?
            var firstSeen: (file: ICCameraFile, handle: PTPObjectHandle, identity: PTPObjectIdentity)?
            for candidate in candidates {
                let handle: PTPObjectHandle
                do {
                    handle = try await resolveHandle(for: candidate)
                } catch let interruption as USBSpikeError where interruption.isInterruption {
                    throw interruption
                } catch {
                    log.warn("  candidate \(candidate.name ?? "?") (\(candidate.fileSize) B): \(describe(error))")
                    continue
                }
                let candidateInfo = try await objectInfo(for: candidate, saveFixture: false, compare: false)
                let identity = candidateInfo.identity(cameraSerial: serial)
                if firstSeen == nil { firstSeen = (candidate, handle, identity) }
                if identity == saved.identity {
                    match = (candidate, handle, identity)
                    break
                }
                log.warn("  handle \(handle) is \(identity), not the saved object")
            }
            guard let target = match ?? firstSeen else {
                throw USBSpikeError.nothingToDo("could not read ObjectInfo for any candidate")
            }
            let chosen = target.file
            let chosenHandle = target.handle
            let currentIdentity = target.identity

            let partURL = USBResumePaths.url(relative: saved.partPath)
            let onDisk = PartFileWriter.sizeOnDisk(partURL) ?? 0
            var offset = PTPPartialRead.resumeOffset(savedOffset: saved.offset, saved: saved.identity, current: currentIdentity)
            if offset == 0 && saved.offset > 0 {
                log.warn("Identity changed (\(currentIdentity) vs \(saved.identity)): restarting from zero, as the resume rule says.")
            }
            if offset > onDisk {
                log.warn(".part holds \(onDisk) B on disk, fewer than the saved offset \(offset); continuing from \(onDisk)")
                offset = onDisk
            }
            log.note("Interrupted at offset \(saved.offset); .part on disk \(onDisk) B; resuming at offset \(offset) (\(percent(offset, currentIdentity.size)) %) with this session's handle \(chosenHandle)")

            let variant = chooseVariant(size: currentIdentity.size, info: info)
            let writer = try PartFileWriter(url: partURL, startingAt: offset)
            var state = USBResumeState(identity: currentIdentity, offset: writer.offset, partPath: saved.partPath, savedAt: Date(), reason: "resumed",
                                       sessionID: sessionID)
            persistResume(state)
            let result = await partialReadLoop(handle: chosenHandle, name: currentIdentity.filename,
                                               size: currentIdentity.size, from: writer.offset, variant: variant,
                                               chunkSize: PTPPartialRead.defaultChunkSize, pause: nil, writer: writer,
                                               label: "resume") { previous, now in
                if PTPPartialRead.crossesCheckpoint(from: previous, to: now) {
                    try? writer.flush()
                    state.offset = now
                    state.reason = "checkpoint"
                    state.savedAt = Date()
                    self.persistResume(state)
                }
            }
            writer.close()
            state.offset = writer.offset
            state.savedAt = Date()
            if let error = result.error {
                state.reason = "error: \(describe(error))"
                persistResume(state)
                log.warn("Resume interrupted again at offset \(writer.offset): \(describe(error)). Reconnect and tap Resume read again.")
                lastResult = "Resume interrupted at \(percent(writer.offset, currentIdentity.size)) %"
                return
            }

            log.note("Verifying the .part against requestReadData of the same file…")
            let partSHA = try sha256(of: partURL)
            let partSize = PartFileWriter.sizeOnDisk(partURL) ?? 0
            let reference = try await readDataSHA(chosen, measure: false)
            let verified = partSHA == reference.sha && partSize == currentIdentity.size
            log.note("  .part SHA-256 \(partSHA) (\(partSize) B)")
            log.note("  reference SHA-256 \(reference.sha) (\(reference.bytes) B): \(verified ? "MATCH" : "MISMATCH")")
            if offset == 0 {
                log.warn("The read restarted from zero, so this was not a resume; usb.resume.verified not recorded.")
            } else if saved.sessionID == sessionID {
                log.warn("The read was cut by \(saved.reason) in this same session (no cable pull, no re-plug), so this was not a link-drop resume; usb.resume.verified not recorded. Start again and pull the cable at PULL NOW.")
            } else {
                log.flag("usb.resume.verified", verified,
                         context: "\(currentIdentity.filename): interrupted at \(saved.offset) (\(saved.reason)), resumed at \(offset) in a new request sequence, \(verified ? "SHA-256 match" : "SHA-256 MISMATCH")")
            }
            if verified {
                USBResumeStore.clear()
                resumeSummary = "none saved"
                try? FileManager.default.removeItem(at: partURL)
            } else {
                state.reason = "verify failed"
                persistResume(state)
                log.warn("  .part kept in Caches/Imports for inspection: \((saved.partPath as NSString).lastPathComponent)")   // a build-3 path holds the raw serial
            }
            lastResult = "Resume \(verified ? "verified" : "MISMATCH")"
        }
    }

    func forgetSavedRead() {
        guard activity == nil else { log.warn("Busy; stop the running operation first"); return }
        if let saved = USBResumeStore.load() {
            try? FileManager.default.removeItem(at: USBResumePaths.url(relative: saved.partPath))
        }
        USBResumeStore.clear()
        resumeSummary = "none saved"
        log.note("Saved resumable read forgotten (.part deleted)")
    }

    private func persistResume(_ state: USBResumeState) {
        do {
            try USBResumeStore.save(state)
            resumeSummary = state.summary
        } catch {
            log.error("Could not save the resume state: \(describe(error))")
        }
    }

    /// The resume identity's camera key: a one-way tag of GetDeviceInfo's serial (CameraSerialTag; the serial itself
    /// must not reach identities and `.part` paths, which are logged), or "uuid-" and a tag of the device UUID if the
    /// camera sends none: ImageCaptureCore's UUID appears to embed the camera's USB serial, so it is tagged too.
    /// ICDevice.serialNumberString is macOS-only.
    private func cameraSerial(_ info: PTPDeviceInfo) -> String {
        let serial = info.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serial.isEmpty { return CameraSerialTag.tag(serial) }
        let uuid = device.uuidString ?? ""
        let fallback = "uuid-" + (uuid.isEmpty ? "unknown" : CameraSerialTag.tag(uuid))
        log.warn("DeviceInfo has an empty serial number; using \(fallback) for the resume identity")
        return fallback
    }

    // MARK: - Day 5 · lifecycle

    func longSerialDownload() async {
        await perform("Long serial download") {
            try requireOpen()
            let selection = files.filter { Self.ext($0) == "ARW" }
            guard !selection.isEmpty else { throw USBSpikeError.nothingToDo("no ARW on the card") }
            let total = selection.reduce(Int64(0)) { $0 + Int64($1.fileSize) }
            log.note("Long serial download: \(selection.count) ARW, \(mb(total)). Lock the phone or switch apps now; each file logs the app state.")
            _ = try await downloadSequence(selection, label: "long serial", report: nil, shouldStop: nil)
        }
    }

    /// Wraps a 20-ARW download in BGContinuedProcessingTask (ContinuedTask). The work starts when the system starts
    /// the task; it reports one unit per file and stops cleanly when the system expires the task.
    func continuedDownload(using continued: ContinuedTask) {
        guard activity == nil else { log.warn("Busy with \(activity ?? ""); wait for it or tap Stop"); return }
        guard isOpen, !removed else { log.error("Open a session first (Day 2 · Open session)"); return }
        guard catalogComplete else { log.error("Continued-task download: \(USBSpikeError.catalogueIncomplete(device.contentCatalogPercentCompleted, device.mediaFiles?.count ?? 0))"); return }
        let selection = newest("ARW", 20)
        guard !selection.isEmpty else { log.warn("No ARW on the card"); return }
        log.note("Submitting a continued task for \(selection.count) ARW; lock the phone once the log says it started.")
        continued.run(title: "Importing from camera (spike)", subtitle: "0 of \(selection.count)", totalUnits: selection.count) { [weak self] report, shouldStop in
            guard let self else { return false }
            var finished = false
            await self.perform("Continued-task download") {
                finished = try await self.downloadSequence(selection, label: "continued task", report: report, shouldStop: shouldStop)
            }
            return finished
        }
    }

    /// Serial downloads with a log line per file carrying the lifecycle state; each copy is deleted once measured.
    private func downloadSequence(_ selection: [ICCameraFile], label: String,
                                  report: ContinuedTask.Report?, shouldStop: ContinuedTask.ShouldStop?) async throws -> Bool {
        let largest = selection.map { Int64($0.fileSize) }.max() ?? 0
        try ensureFreeSpace(for: largest)
        let dir = try freshDirectory("Lifecycle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ContinuousClock()
        let start = clock.now
        var done = 0
        var bytes: Int64 = 0
        var failures = 0
        for file in selection {
            if stopRequested || (shouldStop?() ?? false) {
                log.warn("\(label): stopping cleanly after \(done) of \(selection.count) files [\(lifecycle.stateDescription)]")
                lastResult = "\(label): stopped after \(done)/\(selection.count)"
                return false
            }
            if !isOpen {
                log.warn("\(label): \(removed ? "camera disconnected" : "the camera closed the session") after \(done) of \(selection.count) files; stopping [\(lifecycle.stateDescription)]")
                lastResult = "\(label): session closed after \(done)/\(selection.count)"
                return false
            }
            let name = file.name ?? "?"
            do {
                let downloaded = try await downloadFile(file, to: dir)
                try? FileManager.default.removeItem(at: downloaded.url)
                done += 1
                bytes += downloaded.bytes
                lifecycle.noteProgress("\(label): \(name) (\(done)/\(selection.count))", link: "usb")
                let rate = downloaded.seconds > 0 ? Double(downloaded.bytes) / downloaded.seconds / 1_000_000 : 0
                log.note("  \(label) \(done)/\(selection.count): \(name) \(mb(downloaded.bytes)) in \(fmt(downloaded.seconds, 2)) s = \(fmt(rate)) MB/s [\(lifecycle.stateDescription)]")
                report?(done, "\(done) of \(selection.count)")
                progressText = "\(done)/\(selection.count)"
            } catch {
                failures += 1
                log.error("  \(label): \(name) failed after \(done) files [\(lifecycle.stateDescription)]: \(describe(error))")
                if removed {
                    log.warn("\(label): camera disconnected; stopping")
                    return false
                }
                if failures >= 3 {
                    log.error("\(label): three failures; stopping")
                    return false
                }
            }
        }
        let seconds = (clock.now - start).inSeconds
        log.note("\(label): \(done) of \(selection.count) files, \(mb(bytes)) in \(fmt(seconds)) s [\(lifecycle.stateDescription)]")
        lastResult = "\(label): \(done)/\(selection.count) files"
        return done == selection.count
    }

    // MARK: - Helpers

    /// The newest `count` files with extension `ext` (upper case, no dot).
    func newest(_ ext: String, _ count: Int) -> [ICCameraFile] {
        Array(files.filter { Self.ext($0) == ext }.prefix(count))
    }

    nonisolated static func ext(_ item: ICCameraItem) -> String {
        ((item.name ?? "") as NSString).pathExtension.uppercased()
    }

    nonisolated static func stem(_ item: ICCameraItem) -> String {
        ((item.name ?? "") as NSString).deletingPathExtension
    }

    nonisolated static func isNewer(_ a: ICCameraFile, _ b: ICCameraFile) -> Bool {
        let da = a.creationDate ?? .distantPast
        let db = b.creationDate ?? .distantPast
        if da != db { return da > db }
        return (a.name ?? "") > (b.name ?? "")
    }

    private func logCapabilities(_ when: String) {
        let caps = device.capabilities
        let acceptsPTP = caps.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        log.note("  capabilities \(when) (\(caps.count)): \(caps.joined(separator: ", ")); acceptsPTPCommands=\(acceptsPTP ? "yes" : "no")")
    }

    private func ensureFreeSpace(for bytes: Int64) throws {
        let values = try? USBResumePaths.caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            log.warn("Could not read the phone's free space; continuing")
            return
        }
        let needed = bytes + 1_000_000_000
        if available < needed { throw USBSpikeError.diskSpace(needed: needed, available: available) }
    }

    /// Caches/Spike/<name>, emptied first.
    private func freshDirectory(_ name: String) throws -> URL {
        let dir = USBResumePaths.caches.appendingPathComponent("Spike", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hexString(hasher.finalize())
    }

    private func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? USBSpikeError { return e.description }
        if error is PTPDecodingError || error is PTPPassThrough.Failure || error is PTPPartialRead.PlanError { return "\(error)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
}

// MARK: - Delegate

extension CameraSession: @preconcurrency ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        log.note("didOpenSession error=\(error.map { describe($0) } ?? "nil")")
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        log.note("didCloseSession error=\(error.map { describe($0) } ?? "nil") [\(lifecycle.stateDescription)]")
        isOpen = false
        catalogComplete = false
        files = []
        stopCatalogueMonitor()
        clearPTPCaches()
        if !closingSession { abortPending(.sessionClosed) }
    }

    func didRemove(_ device: ICDevice) {
        removed = true
        isOpen = false
        files = []
        stopCatalogueMonitor()
        clearPTPCaches()
        log.warn("Camera removed (cable pulled?) [\(lifecycle.stateDescription)]. Re-plug, then Day 2 · Open session.")
        abortPending(.deviceRemoved)
    }

    func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        log.warn("device error: \(error.map { describe($0) } ?? "nil") [\(lifecycle.stateDescription)]")
    }

    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {
        log.note("device status: \(status)")
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let now = ContinuousClock.now
        let wasComplete = catalogComplete
        if !wasComplete, let start = openRequestedAt {
            openRequestedAt = nil
            recordCatalogueComplete((now - start).inSeconds, commands: ptpCommandsDuringCatalogue,
                                    context: "open request → complete catalogue, \(device.mediaFiles?.count ?? 0) files"
                                        + (openIsReopen ? "; REOPEN on the same device, the catalogue may be cached (re-plug for a cold figure)" : ""),
                                    note: openIsReopen ? "REOPEN, may be cached" : "")
        } else if !wasComplete && !isOpen {
            // The open failed or timed out, or the session was closed: no session to mark complete. A later open
            // resets the state and waits for its own callback.
            log.note("deviceDidBecomeReady(withCompleteContentCatalog:) with no session open (the open failed or was closed); ignored")
            return
        } else if !wasComplete {
            // The open stopped waiting (Stop during the catalogue with the wait on): no request to time it from.
            log.note("deviceDidBecomeReady(withCompleteContentCatalog:) after the open stopped waiting; not timed. File list loaded; tap Refresh catalogue to record usb.catalog.count")
        } else {
            log.note("deviceDidBecomeReady(withCompleteContentCatalog:) again")
        }
        catalogComplete = true
        // Without this a late callback leaves `files` empty (or another session's) while the buttons say complete.
        if isOpen { refreshCatalogue(record: false) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard catalogComplete else { return }   // the initial catalogue arrives as many didAdd calls
        let names = items.map { $0.name ?? "?" }
        iccAddedAfterCatalogue.append(contentsOf: names)
        log.note("ImageCaptureCore didAdd after the catalogue: \(names.joined(separator: ", ")) [\(lifecycle.stateDescription)]")
        refreshCatalogue(record: false)
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        log.note("ImageCaptureCore didRemove \(items.count) item(s): \(items.prefix(5).map { $0.name ?? "?" }.joined(separator: ", "))")
        if catalogComplete { refreshCatalogue(record: false) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        log.note("ImageCaptureCore didRename \(items.count) item(s)")
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        logCapabilities("changed")
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        receiveEvent(eventData, source: "delegate")
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log.note("access restriction removed")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log.warn("access restriction enabled: unlock the camera and the phone")
    }
}

// MARK: - Supporting types

/// Day 3 batches. Measurement names are the contract with the Log tab's export.
enum USBDownloadPreset: String, CaseIterable, Identifiable {
    case arwSerial, arwParallel2, jpgSerial, mp4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .arwSerial: return "20 newest ARW, serial"
        case .arwParallel2: return "20 newest ARW, 2 in flight"
        case .jpgSerial: return "20 newest JPG, serial"
        case .mp4: return "3 newest MP4"
        }
    }

    var fileExtension: String {
        switch self {
        case .arwSerial, .arwParallel2: return "ARW"
        case .jpgSerial: return "JPG"
        case .mp4: return "MP4"
        }
    }

    var count: Int { self == .mp4 ? 3 : 20 }
    var parallel: Int { self == .arwParallel2 ? 2 : 1 }

    var measurement: String {
        switch self {
        case .arwSerial: return "usb.download.throughput.serial"
        case .arwParallel2: return "usb.download.throughput.parallel2"
        case .jpgSerial: return "usb.download.jpg.throughput"
        case .mp4: return "usb.download.mp4"
        }
    }
}

enum USBSpikeError: Error, CustomStringConvertible {
    case sessionNotOpen
    case deviceRemoved
    case sessionClosed
    case sessionReplaced
    case stopped
    case timedOut(String, Double)
    case noData(String)
    case nothingToDo(String)
    case ptp(String, PTPResponseCode)
    case passThrough(String, String)
    case diskSpace(needed: Int64, available: Int64)
    /// ImageCaptureCore's catalogue is still running (percent, files so far): `files` is not filled yet.
    case catalogueIncomplete(Int, Int)
    /// ImageCaptureCore gave ptpObjectHandle 0 and no PTP object matched (file name, why).
    case noHandle(String, String)
    /// The camera stopped answering on this connection; only a replug recovers it.
    case linkStalled

    /// The link or the operation went away (cable pull, session closed or replaced, Stop): no answer about the camera.
    var isInterruption: Bool {
        switch self {
        case .stopped, .deviceRemoved, .sessionClosed, .sessionReplaced: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .sessionNotOpen: return "no open session (Day 2 · Open session first)"
        case .deviceRemoved: return "the camera was disconnected"
        case .sessionClosed: return "the camera closed the session"
        case .sessionReplaced: return "a new session replaced this one"
        case .stopped: return "stopped"
        case .timedOut(let what, let seconds): return "\(what) did not complete within \(Int(seconds)) s"
        case .noData(let what): return "\(what): no data"
        case .nothingToDo(let why): return why
        case .ptp(let what, let code): return "\(what): \(code) (\(hex16(code.rawValue)))"
        case .passThrough(let what, let detail): return "\(what) pass-through failed: \(detail)"
        case .diskSpace(let needed, let available): return "not enough free space on the phone: need \(needed / 1_000_000) MB, \(available / 1_000_000) MB free"
        case .catalogueIncomplete(let percent, let count): return "ImageCaptureCore's catalogue is not complete yet (\(percent)%, \(count) files so far); wait for usb.catalog.complete in the log"
        case .noHandle(let name, let detail): return "no PTP handle for \(name) (ImageCaptureCore gave 0): \(detail)"
        case .linkStalled: return "the camera stopped answering on this connection: unplug it, plug it back in, then Open session"
        }
    }
}

/// One ImageCaptureCore request whose completion may never come (cable pulled, app suspended). Resumed exactly
/// once: by the completion, by its timeout, or by didRemove.
private final class PendingRequest<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

// MARK: - Formatting and names

private let batteryLevelProperty: UInt16 = PTPDevicePropCode.batteryLevel.rawValue

/// ISO 15740 §13 and MTP device property names, for logging DeviceInfo. Sony's 0xD2xx properties stay hex.
private let devicePropertyNames: [UInt16: String] = [
    0x5001: "BatteryLevel", 0x5002: "FunctionalMode", 0x5003: "ImageSize", 0x5004: "CompressionSetting",
    0x5005: "WhiteBalance", 0x5006: "RGBGain", 0x5007: "FNumber", 0x5008: "FocalLength", 0x5009: "FocusDistance",
    0x500A: "FocusMode", 0x500B: "ExposureMeteringMode", 0x500C: "FlashMode", 0x500D: "ExposureTime",
    0x500E: "ExposureProgramMode", 0x500F: "ExposureIndex", 0x5010: "ExposureBiasCompensation", 0x5011: "DateTime",
    0x5012: "CaptureDelay", 0x5013: "StillCaptureMode", 0x5014: "Contrast", 0x5015: "Sharpness",
    0x5016: "DigitalZoom", 0x5017: "EffectMode", 0x5018: "BurstNumber", 0x5019: "BurstInterval",
    0x501A: "TimelapseNumber", 0x501B: "TimelapseInterval", 0x501C: "FocusMeteringMode", 0x501D: "UploadURL",
    0x501E: "Artist", 0x501F: "CopyrightInfo",
    0xD401: "MTP SynchronizationPartner", 0xD402: "MTP DeviceFriendlyName", 0xD406: "MTP SessionInitiatorVersionInfo",
    0xD407: "MTP PerceivedDeviceType",
]

/// "0x1001 GetDeviceInfo", or just the hex when PTPKit has no name for the code.
private func named(_ code: UInt16, _ name: String) -> String {
    (name.isEmpty || name.contains("0x")) ? hex16(code) : "\(hex16(code)) \(name)"
}

private func hex16(_ value: UInt16) -> String { String(format: "0x%04X", value) }
private func hex32(_ value: UInt32) -> String { String(format: "0x%08X", value) }
private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
/// The camera serial must never reach the public repo, and the log is exported: only whether there is one.
private func redactedSerial(_ serial: String) -> String {
    serial.isEmpty ? "serial (empty)" : "serial present (\(serial.count) characters, redacted)"
}
private func fmt(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
private func mb<T: BinaryInteger>(_ bytes: T) -> String { fmt(Double(bytes) / 1_000_000) + " MB" }
private func gb(_ bytes: UInt64) -> String { fmt(Double(bytes) / 1_000_000_000, 2) + " GB" }

private func percent(_ part: UInt64, _ whole: UInt64) -> String {
    whole == 0 ? "0" : fmt(Double(part) / Double(whole) * 100, 0)
}
