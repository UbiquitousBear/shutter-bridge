import Foundation
import Observation
import UIKit

/// One file to copy, as the camera listed it.
struct CopyAllItem: Sendable {
    let name: String
    /// Bytes from the listing; 0 when unknown (an object over 4 GB over PTP/IP).
    let size: UInt64
}

/// What the latest *Copy all RAW to Files* run did, for the tabs and the guided run.
struct CopyAllOutcome {
    /// "usb.copyAll", "ptpip.ap.copyAll" or "ptpip.lan.copyAll".
    let prefix: String
    let folderName: String
    /// Where the run folder is, e.g. "On My iPhone › SB Spike › Camera copies" (for the UI only).
    let destination: String
    /// "the default folder" or "a folder chosen in Files": for measurement contexts, which never name the folder.
    let destinationLabel: String
    let total: Int
    let copied: Int
    let failed: Int
    let bytes: UInt64
    let seconds: Double?
    /// Every ARW was copied.
    let finished: Bool
    /// Why it ended early; nil when it went through the whole list.
    let stopReason: String?

    var summary: String {
        var text = "Last copy: \(copied) of \(total) ARW"
        if failed > 0 { text += ", \(failed) failed" }
        text += ", " + CopyAllFormat.gb(bytes)
        if let seconds, seconds > 0 {
            text += String(format: " in %.1f min (%.1f MB/s)", seconds / 60, Double(bytes) / seconds / 1_000_000)
        }
        text += " → \(destination) › \(folderName)"
        if let stopReason { text += "; ended early: \(stopReason)" }
        return text
    }
}

enum CopyAllError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

enum CopyAllFormat {
    static func gb(_ bytes: UInt64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }
    static func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

    /// An error for the log or the UI without its userInfo (a file error's NSFilePath can be the full path of a folder
    /// chosen in Files, which can carry the owner's name).
    static func describe(_ error: Error) -> String {
        if let e = error as? CopyAllError { return e.description }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// *Copy all RAW to Files*: where the copies go, and the run in progress.
///
/// The default is Documents/Camera copies, which the Files app shows under On My iPhone › SB Spike (the app's Info.plist
/// sets UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace). It belongs to the app, so it is deleted with SB
/// Spike, and it is excluded from the phone's backup (a run is 10–25 GB). The tester can pick any folder in Files instead
/// (iCloud Drive, On My iPhone outside SB Spike, an external drive, but not the camera's card or Recently Deleted); a
/// security-scoped bookmark to it is kept in UserDefaults under "copyAll.folderBookmark". Every run writes into a new folder named by its start time ("Copy 2026-11-03 01.23.45"),
/// so nothing that exists is ever overwritten, and every run copies everything (no differential sync). Each file is
/// downloaded into the app's temporary folder, then moved into the run folder with NSFileCoordinator under a name no
/// other file in the run has. Shared by the Wired and Wi-Fi tabs and the guided run.
@Observable
@MainActor
final class FilesDestination {
    static let shared = FilesDestination()
    static let bookmarkKey = "copyAll.folderBookmark"
    /// The picked folder's name, to show without resolving the bookmark.
    static let folderNameKey = "copyAll.folderName"
    static let defaultFolderName = "Camera copies"

    /// The name Files shows for the app's own folder under On My iPhone.
    static var appFolderName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Spike"
    }

    static var defaultDescription: String { "On My iPhone › \(appFolderName) › \(defaultFolderName)" }

    /// Said wherever the default folder is offered: what happens to copies left there.
    static var defaultCaveat: String {
        "The default folder belongs to \(appFolderName): it is deleted with the app and isn't in the phone's backup. For copies you want to keep, choose a folder in iCloud Drive or in On My iPhone outside \(appFolderName), or move the Copy … folder there afterwards."
    }

    /// The picked folder's name; nil while the default is in use.
    private(set) var pickedName: String?
    /// The latest problem with the picked folder (shown under the destination row); nil when there is none.
    private(set) var problem: String?
    /// Bumped whenever the destination changes, so the guided run can wait for a pick.
    private(set) var changes = 0
    /// The run in progress; nil when no copy is running.
    private(set) var run: CopyAllRun?
    private(set) var lastOutcome: CopyAllOutcome?
    /// Runs ended (finished or not) since launch: the guided run waits for this to change.
    private(set) var runsFinished = 0

    @ObservationIgnored private let log: SpikeLog

    init() {
        log = SpikeLog.shared
        if UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil {
            pickedName = UserDefaults.standard.string(forKey: Self.folderNameKey) ?? "chosen folder"
        }
    }

    var isPicked: Bool { pickedName != nil }

    /// "On My iPhone › SB Spike › Camera copies", or the picked folder's name. A picked folder's full path is never
    /// shown or logged: it can carry the owner's name.
    var locationDescription: String {
        if let pickedName { return "\(pickedName) (chosen in Files)" }
        return Self.defaultDescription
    }

    // MARK: Choosing the folder

    /// The .fileImporter's result: keeps a security-scoped bookmark to `url`.
    func usePicked(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        if let refusal = CopyAllFiles.refusal(for: url) {
            let text = "\"\(name)\" \(refusal): choose a folder on the phone, in iCloud Drive or on another drive; the destination is unchanged"
            problem = text
            // Bumped anyway, so the guided run stops waiting and shows the problem.
            changes += 1
            log.warn("Copy all RAW: \(text)")
            return
        }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            UserDefaults.standard.set(name, forKey: Self.folderNameKey)
            pickedName = name
            problem = nil
            changes += 1
            log.note("Copy all RAW: copies now go to the folder \"\(name)\" chosen in Files (bookmark saved; security scope \(scoped ? "granted" : "not needed or refused"))")
        } catch {
            let text = "couldn't keep access to \"\(name)\": \(error.localizedDescription); the destination is unchanged"
            problem = text
            log.error("Copy all RAW: \(text)")
        }
    }

    func pickFailed(_ error: Error) {
        log.warn("Copy all RAW: choosing a folder failed: \(error.localizedDescription)")
    }

    /// "Use the default folder": forgets the picked folder.
    func useDefault() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.folderNameKey)
        pickedName = nil
        problem = nil
        changes += 1
        log.note("Copy all RAW: copies now go to the default folder, \(Self.defaultDescription)")
    }

    // MARK: Resolving

    /// The folder to copy into. `scoped`: its security scope was started and must be stopped afterwards.
    private struct Resolved {
        let root: URL
        let scoped: Bool
        let description: String
    }

    /// The picked folder if its bookmark resolves (a stale bookmark is re-created), otherwise the default folder
    /// (created if missing). A picked folder that can't be used (the bookmark doesn't resolve, or it now points into
    /// Recently Deleted or onto a camera card) refuses the run rather than falling back to the default, which would put
    /// 10–25 GB somewhere the tester didn't choose; the bookmark is kept, since an external drive may come back.
    private func resolve() throws -> Resolved {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                let text = "the chosen folder \"\(pickedName ?? "?")\" can't be found (\(error.localizedDescription)); nothing is copied until you choose the folder again or tap Use the default folder"
                problem = text
                log.warn("Copy all RAW: \(text)")
                throw CopyAllError.message(text)
            }
            let scoped = url.startAccessingSecurityScopedResource()
            let name = url.lastPathComponent
            // Before a stale bookmark is re-created: a folder deleted in Files resolves into Recently Deleted.
            if let refusal = CopyAllFiles.refusal(for: url) {
                if scoped { url.stopAccessingSecurityScopedResource() }
                let text = "the chosen folder \"\(name)\" \(refusal); nothing is copied until you choose a folder again or tap Use the default folder"
                problem = text
                log.warn("Copy all RAW: \(text)")
                throw CopyAllError.message(text)
            }
            if !scoped {
                log.warn("Copy all RAW: no security scope for the folder \"\(name)\" (startAccessingSecurityScopedResource returned false); trying anyway")
            }
            if stale {
                do {
                    let fresh = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                    log.note("Copy all RAW: the bookmark to \"\(name)\" was stale; re-created it")
                } catch {
                    log.warn("Copy all RAW: the bookmark to \"\(name)\" is stale and couldn't be re-created (\(error.localizedDescription)); using it this time")
                }
            }
            if pickedName != name {
                pickedName = name
                UserDefaults.standard.set(name, forKey: Self.folderNameKey)
            }
            problem = nil
            return Resolved(root: url, scoped: scoped, description: "\(name) (chosen in Files)")
        }
        var root = URL.documentsDirectory.appending(path: Self.defaultFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 10–25 GB a run would otherwise go into the phone's iCloud Backup and can push it over the plan's quota.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try root.setResourceValues(values)
        } catch {
            log.warn("Copy all RAW: couldn't exclude \(Self.defaultFolderName) from the backup: \(error.localizedDescription)")
        }
        return Resolved(root: root, scoped: false, description: Self.defaultDescription)
    }

    /// Resolves the destination and lets it go again, so `problem` is current before the guided run says where the
    /// copies go.
    func checkFolder() {
        guard let resolved = try? resolve() else { return }
        if resolved.scoped { resolved.root.stopAccessingSecurityScopedResource() }
    }

    // MARK: Before a run

    /// Sums the sizes and checks the free space on the destination's volume and on the temporary folder's; throws with
    /// a message when there isn't enough. Logs both figures in GB. Called from the tap, before the continued task.
    func checkSpace(for items: [CopyAllItem], link: String) throws {
        let resolved = try resolve()
        defer { if resolved.scoped { resolved.root.stopAccessingSecurityScopedResource() } }
        let total = items.reduce(UInt64(0)) { $0 + $1.size }
        let largest = items.map(\.size).max() ?? 0
        let margin: UInt64 = 1_000_000_000
        let tmp = FileManager.default.temporaryDirectory
        let destinationFree = CopyAllFiles.freeBytes(at: resolved.root)
        let tmpFree = CopyAllFiles.freeBytes(at: tmp)
        let same = CopyAllFiles.sameVolume(tmp, resolved.root) ?? false
        func free(_ bytes: Int64?) -> String { bytes.map { CopyAllFormat.gb($0) } ?? "unknown" }

        // Same volume: each file is renamed out of tmp, so the volume ends up holding all of them, plus a margin.
        // Another volume: the destination takes all of them, tmp only the one in flight.
        let destinationNeeds = same ? total + margin : total + 100_000_000
        let tmpNeeds = largest + margin
        var line = "Copy all RAW (\(link)): \(items.count) ARW, \(CopyAllFormat.gb(total)) (largest \(CopyAllFormat.gb(largest))) to \(resolved.description); "
            + "destination volume \(free(destinationFree)) free, needs \(CopyAllFormat.gb(destinationNeeds))"
        line += same ? "; the temporary folder is on the same volume" : "; temporary folder \(free(tmpFree)) free, needs \(CopyAllFormat.gb(tmpNeeds))"
        log.note(line)

        if let destinationFree, UInt64(max(0, destinationFree)) < destinationNeeds {
            throw CopyAllError.message("not enough free space at \(resolved.description): \(CopyAllFormat.gb(destinationFree)) free, \(CopyAllFormat.gb(destinationNeeds)) needed for \(items.count) ARW (\(CopyAllFormat.gb(total)))")
        }
        if !same, let tmpFree, UInt64(max(0, tmpFree)) < tmpNeeds {
            throw CopyAllError.message("not enough free space on the phone for the temporary copy: \(CopyAllFormat.gb(tmpFree)) free, \(CopyAllFormat.gb(tmpNeeds)) needed")
        }
        if destinationFree == nil {
            log.warn("Copy all RAW: the destination's free space can't be read (a cloud or external provider?); copying anyway")
        }
        if destinationFree != nil && resolved.description != Self.defaultDescription {
            log.note("Copy all RAW: for iCloud Drive the figure is the phone's own free space, not the iCloud quota")
        }
    }

    // MARK: A run

    /// Starts a run inside the continued task: resolves the destination (starting its security scope), creates the run
    /// folder and an empty temporary folder, and starts watching the lock and the battery.
    /// `session`: what kind of session listed the files when that matters (Wi-Fi), for the ▶ line and `finished`.
    func begin(link: String, items: [CopyAllItem], session: String? = nil) throws -> CopyAllRun {
        guard run == nil else { throw CopyAllError.message("a copy is already running") }
        let resolved = try resolve()
        do {
            let folder = try CopyAllFiles.makeRunFolder(in: resolved.root, startedAt: Date())
            let tmp = FileManager.default.temporaryDirectory.appending(path: "copy-all", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let same = CopyAllFiles.sameVolume(tmp, folder) ?? false
            let started = CopyAllRun(link: link, items: items, root: resolved.root, scoped: resolved.scoped, folder: folder,
                                     temporaryDirectory: tmp, destination: resolved.description, sameVolume: same,
                                     session: session, log: log)
            run = started
            log.note("▶ Copy all RAW to Files (\(link)\(session.map { ", \($0)" } ?? "")): \(items.count) ARW, \(CopyAllFormat.gb(started.totalBytes)), oldest first, into \(resolved.description) › \(started.folderName) (\(same ? "same volume: each file is renamed into place" : "another volume: each file is copied, then the temporary copy deleted"))")
            return started
        } catch {
            if resolved.scoped { resolved.root.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// Ends `run`: records the measurements and the summary line, deletes the temporary folder and stops the security
    /// scope. `stopReason` nil: it went through the whole list (some files may still have failed).
    func finish(_ run: CopyAllRun, stopReason: String?) {
        let p = run.prefix
        run.endWatching()
        let finished = stopReason == nil && run.copied == run.total
        let seconds = run.transferSeconds
        let thermal = CopyAllFormat.thermalState()
        // Measurement contexts go into the pasted table: they say which kind of folder, never its name.
        let label = run.destinationLabel

        log.measure("\(p).files", Double(run.copied), "count", context: "of \(run.total) ARW listed; into \(label)")
        log.measure("\(p).failed", Double(run.failed), "count",
                    context: run.failures.isEmpty ? "none" : run.failures.prefix(5).joined(separator: "; ") + (run.failures.count > 5 ? "; …" : ""))
        log.measure("\(p).size", Double(run.bytes) / 1e6, "MB", context: "\(run.copied) ARW, \(CopyAllFormat.gb(run.bytes))")
        if let seconds {
            log.measure("\(p).seconds", seconds, "s", context: String(format: "first request to last move, %.1f min", seconds / 60))
            log.throughput("\(p).throughput", bytes: Int(run.bytes), seconds: seconds,
                           context: String(format: "%ld ARW, %@ in %.1f s (first request to last move, moves included)%@",
                                           run.copied, CopyAllFormat.gb(run.bytes), seconds, run.failed > 0 ? ", \(run.failed) failed" : ""))
        } else {
            log.note("Copy all RAW (\(run.link)): nothing was copied, so no time or throughput")
        }
        let ending: String
        if let stopReason {
            ending = "ended early: \(stopReason)"
        } else {
            ending = run.failed > 0 ? "\(run.failed) failed" : "every ARW copied"
        }
        let session = run.session.map { "; listed by \($0)" } ?? ""
        log.flag("\(p).finished", finished, context: "\(run.copied) of \(run.total) copied; \(ending)\(session); thermal state \(thermal)")
        log.flag("\(p).underLock", run.wasLocked,
                 context: String(format: "locked for about %.0f s of %.0f s (protected-data notifications and checks after each file; a phone without a passcode never reports a lock)",
                                 run.lockedSeconds, Date().timeIntervalSince(run.startedAt)))
        if let before = run.batteryBefore, let after = run.batteryAfter {
            log.measure("\(p).phoneBattery", Double(before - after) * 100, "points",
                        context: String(format: "%.0f %% → %.0f %% over %@ (%@ at the start, %@ at the end)",
                                        Double(before) * 100, Double(after) * 100, CopyAllFormat.gb(run.bytes),
                                        run.batteryStateBefore, run.batteryStateAfter))
        } else {
            log.note("Copy all RAW (\(run.link)): the phone's battery level couldn't be read; \(p).phoneBattery not recorded")
        }

        let gigabytes = Double(run.bytes) / 1e9
        let minutes = (seconds ?? 0) / 60
        let rate = (seconds ?? 0) > 0 ? Double(run.bytes) / (seconds ?? 1) / 1e6 : 0
        log.note(String(format: "◼ Copy all RAW to Files (%@): %ld of %ld ARW copied, %ld failed, %.2f GB in %.1f min = %.1f MB/s, into %@ › %@; %@; thermal state %@",
                        run.link, run.copied, run.total, run.failed, gigabytes, minutes, rate, run.destination, run.folderName,
                        ending, thermal))

        try? FileManager.default.removeItem(at: run.temporaryDirectory)
        if run.scoped { run.root.stopAccessingSecurityScopedResource() }
        lastOutcome = CopyAllOutcome(prefix: p, folderName: run.folderName, destination: run.destination,
                                     destinationLabel: label, total: run.total,
                                     copied: run.copied, failed: run.failed, bytes: run.bytes, seconds: seconds,
                                     finished: finished, stopReason: stopReason)
        runsFinished += 1
        if self.run === run { self.run = nil }
    }
}

/// One copy run's state: the run folder, names used, counts, timing, the lock and the battery.
@Observable
@MainActor
final class CopyAllRun {
    /// "usb", "ptpip.ap" or "ptpip.lan".
    let link: String
    let total: Int
    let totalBytes: UInt64
    let root: URL
    let scoped: Bool
    let folder: URL
    let folderName: String
    let temporaryDirectory: URL
    /// Where the run folder is, for the UI and the log (never a full path).
    let destination: String
    let sameVolume: Bool
    /// The kind of session that listed the files (Wi-Fi), nil over USB.
    let session: String?
    let startedAt = Date()
    let batteryBefore: Float?
    let batteryStateBefore: String

    private(set) var copied = 0
    private(set) var failed = 0
    private(set) var bytes: UInt64 = 0
    /// The file being fetched.
    private(set) var current = ""
    private(set) var failures: [String] = []
    private(set) var wasLocked = false
    private(set) var lockedSeconds: Double = 0
    private(set) var batteryAfter: Float?
    private(set) var batteryStateAfter = "unknown"

    @ObservationIgnored private let log: SpikeLog
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var firstRequest: ContinuousClock.Instant?
    @ObservationIgnored private var firstRequestDate: Date?
    @ObservationIgnored private var lastMove: ContinuousClock.Instant?
    /// Names already given in this run, lower-cased (APFS and most providers are case-insensitive).
    @ObservationIgnored private var usedNames: Set<String> = []
    @ObservationIgnored private var lockedSince: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let batteryMonitoringWasEnabled: Bool

    init(link: String, items: [CopyAllItem], root: URL, scoped: Bool, folder: URL, temporaryDirectory: URL,
         destination: String, sameVolume: Bool, session: String?, log: SpikeLog) {
        self.link = link
        self.total = items.count
        self.totalBytes = items.reduce(UInt64(0)) { $0 + $1.size }
        self.root = root
        self.scoped = scoped
        self.folder = folder
        self.folderName = folder.lastPathComponent
        self.temporaryDirectory = temporaryDirectory
        self.destination = destination
        self.sameVolume = sameVolume
        self.session = session
        self.log = log
        let device = UIDevice.current
        batteryMonitoringWasEnabled = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        batteryBefore = device.batteryLevel >= 0 ? device.batteryLevel : nil
        batteryStateBefore = Self.describe(device.batteryState)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockStarted() }
        })
        observers.append(nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockEnded() }
        })
        if !UIApplication.shared.isProtectedDataAvailable { lockStarted() }
    }

    /// "usb.copyAll", "ptpip.ap.copyAll", "ptpip.lan.copyAll": the link first, like every other per-link name.
    var prefix: String { "\(link).copyAll" }

    /// For measurement contexts: which kind of folder, never its name.
    var destinationLabel: String {
        destination == FilesDestination.defaultDescription ? "the default folder" : "a folder chosen in Files"
    }

    /// The continued task's subtitle: "12 of 400 · 1.9 GB".
    var subtitle: String {
        String(format: "%ld of %ld · %.1f GB", copied + failed, total, Double(bytes) / 1e9)
    }

    /// For the tabs: "12 of 400 · 1.90 of 19.84 GB · 14.2 MB/s".
    var progressLine: String {
        var text = String(format: "%ld of %ld · %.2f of %.2f GB", copied + failed, total, Double(bytes) / 1e9, Double(totalBytes) / 1e9)
        if let firstRequestDate {
            let seconds = Date().timeIntervalSince(firstRequestDate)
            if seconds > 0, bytes > 0 { text += String(format: " · %.1f MB/s", Double(bytes) / seconds / 1e6) }
        }
        if failed > 0 { text += " · \(failed) failed" }
        return text
    }

    /// Wall time from the first request to the last move; nil until a file has been moved into place.
    var transferSeconds: Double? {
        guard let firstRequest, let lastMove else { return nil }
        return (lastMove - firstRequest).inSeconds
    }

    /// Call right before each file's download request.
    func willRequest(_ name: String) {
        current = name
        if firstRequest == nil {
            firstRequest = clock.now
            firstRequestDate = Date()
        }
    }

    /// A temporary file for a download in progress (inside the run's temporary folder).
    func temporaryURL(_ name: String) -> URL {
        temporaryDirectory.appending(path: CopyAllFiles.safeName(name), directoryHint: .notDirectory)
    }

    /// Moves a complete download into the run folder under the card's name, or "NAME (2).ARW" and so on when the run
    /// already has a file of that name (two DCIM folders can each hold a DSC00001.ARW). Off the main actor, since a move
    /// to another volume (iCloud Drive, an external drive) is a copy. Returns the name used. The caller has already
    /// checked the size: a short file is failed and deleted, never placed.
    @discardableResult
    func place(_ downloaded: URL, cardName: String, bytes received: UInt64, seconds: Double,
               detail: String = "", state: String) async throws -> String {
        let name = freeName(for: cardName)
        let target = folder.appending(path: name, directoryHint: .notDirectory)
        let same = sameVolume
        let moveStarted = clock.now
        do {
            try await Task.detached(priority: .userInitiated) {
                try CopyAllFiles.moveIntoPlace(downloaded, to: target, sameVolume: same)
            }.value
        } catch {
            usedNames.remove(name.lowercased())
            throw error
        }
        let moveSeconds = (clock.now - moveStarted).inSeconds
        lastMove = clock.now
        copied += 1
        bytes += received
        current = ""
        if !UIApplication.shared.isProtectedDataAvailable { wasLocked = true }
        let rate = seconds > 0 ? Double(received) / seconds / 1e6 : 0
        log.note(String(format: "  copy %ld/%ld: %@%@, %.1f MB in %.2f s = %.1f MB/s, move %.2f s%@ [%@]",
                        copied + failed, total, cardName, name == cardName ? "" : " → \(name)", Double(received) / 1e6,
                        seconds, rate, moveSeconds, detail.isEmpty ? "" : ", \(detail)", state))
        return name
    }

    /// A file that didn't download (or couldn't be moved): counted, logged, and the run goes on unless the caller ends it.
    func fileFailed(_ name: String, _ why: String) {
        failed += 1
        current = ""
        failures.append("\(name): \(why)")
        log.warn("  copy \(copied + failed)/\(total): \(name) failed: \(why)")
    }

    /// Stops watching the lock, reads the battery, and puts battery monitoring back as it was.
    func endWatching() {
        lockEnded()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let device = UIDevice.current
        batteryAfter = device.batteryLevel >= 0 ? device.batteryLevel : nil
        batteryStateAfter = Self.describe(device.batteryState)
        device.isBatteryMonitoringEnabled = batteryMonitoringWasEnabled
    }

    private func freeName(for cardName: String) -> String {
        let safe = CopyAllFiles.safeName(cardName)
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        var candidate = safe
        var n = 1
        while usedNames.contains(candidate.lowercased())
                || FileManager.default.fileExists(atPath: folder.appending(path: candidate, directoryHint: .notDirectory).path(percentEncoded: false)) {
            n += 1
            candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private func lockStarted() {
        wasLocked = true
        if lockedSince == nil { lockedSince = Date() }
    }

    private func lockEnded() {
        if let since = lockedSince { lockedSeconds += Date().timeIntervalSince(since) }
        lockedSince = nil
    }

    private static func describe(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

/// The file-system half, not tied to the main actor (the moves run on a detached task).
enum CopyAllFiles {
    /// Free space for important data on `url`'s volume, or nil if it can't be read (some file providers).
    static func freeBytes(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Whether `a` and `b` are on the same volume; nil when either volume can't be read.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool? {
        guard let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
              let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier else { return nil }
        return va.isEqual(vb)
    }

    /// Why a folder can't take the copies, as "is …"; nil when it can. Call it inside the folder's security scope.
    /// Refused: Recently Deleted (a folder deleted in Files resolves there, and iOS empties it after 30 days), and a
    /// camera card (in Image Transfer (MSC) the card mounts in Files as "Untitled" › DCIM): the run promises not to
    /// change the card, and writing back over the same USB 2 link would halve the throughput it measures.
    static func refusal(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        if components.contains(".Trash") { return "is in Recently Deleted" }
        if components.contains(where: { $0.uppercased() == "DCIM" }) { return "is on a camera card (inside its DCIM folder)" }
        // A drive other than the phone's own with a DCIM folder at its root is a camera card (or another card in a reader).
        if sameVolume(url, URL.documentsDirectory) != true,
           let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume {
            let dcim = volume.appending(path: "DCIM", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dcim.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue {
                return "is on a camera card (its drive has a DCIM folder)"
            }
        }
        return nil
    }

    /// A file name without "/" or ":" and not hidden.
    static func safeName(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "unnamed" : out
    }

    /// "Copy 2026-11-03 01.23.45" in `root` (no ":" in names), with " (2)" and so on if that exists already.
    static func makeRunFolder(in root: URL, startedAt: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Copy " + formatter.string(from: startedAt)
        let fm = FileManager.default
        var name = base
        var n = 1
        while fm.fileExists(atPath: root.appending(path: name, directoryHint: .isDirectory).path(percentEncoded: false)) {
            n += 1
            name = "\(base) (\(n))"
        }
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        var coordinationError: NSError?
        var createError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: folder, options: [], error: &coordinationError) { url in
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                createError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let createError { throw createError }
        return folder
    }

    /// Moves `source` (in the app's temporary folder) to `target`, which must not exist, under file coordination. On the
    /// same volume it is a rename. On another (iCloud Drive's provider, an external drive) the file is copied to a hidden
    /// ".NAME.partial" next to the target and renamed once complete, so it only appears under its final name whole; the
    /// temporary file is then deleted. Never overwrites: a move onto an existing name fails.
    static func moveIntoPlace(_ source: URL, to target: URL, sameVolume: Bool) throws {
        let fm = FileManager.default
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        if sameVolume {
            coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
                do {
                    try fm.moveItem(at: source, to: url)
                } catch {
                    operationError = error
                }
            }
        } else {
            let staging = target.deletingLastPathComponent()
                .appending(path: ".\(target.lastPathComponent).partial", directoryHint: .notDirectory)
            coordinator.coordinate(writingItemAt: staging, options: .forReplacing,
                                   writingItemAt: target, options: .forReplacing,
                                   error: &coordinationError) { stagingURL, targetURL in
                do {
                    try fm.copyItem(at: source, to: stagingURL)
                } catch {
                    // Only the incomplete copy this call just wrote.
                    try? fm.removeItem(at: stagingURL)
                    operationError = error
                    return
                }
                do {
                    coordinator.item(at: stagingURL, willMoveTo: targetURL)
                    try fm.moveItem(at: stagingURL, to: targetURL)
                    coordinator.item(at: stagingURL, didMoveTo: targetURL)
                } catch {
                    try? fm.removeItem(at: stagingURL)
                    operationError = error
                }
            }
            if coordinationError == nil && operationError == nil { try? fm.removeItem(at: source) }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}
