import Foundation
import Observation
import UIKit
import UserNotifications

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
    /// Build 14: recoveries the Wi-Fi copy attempted (always 0 over USB).
    let recoveries: Int
    /// Build 14: times iOS paused the copy (its continued task expired) before it was continued.
    let pauses: Int

    var summary: String {
        var text = "Last copy: \(copied) of \(total) ARW"
        if failed > 0 { text += ", \(failed) failed" }
        if recoveries > 0 { text += ", \(recoveries) \(recoveries == 1 ? "recovery" : "recoveries")" }
        if pauses > 0 { text += ", \(pauses) \(pauses == 1 ? "pause" : "pauses")" }
        text += ", " + CopyAllFormat.gb(bytes)
        if let seconds, seconds > 0 {
            text += String(format: " in %.1f min (%.1f MB/s)", seconds / 60, Double(bytes) / seconds / 1_000_000)
        }
        text += " → \(destination) › \(folderName)"
        if let stopReason { text += "; ended early: \(stopReason)" }
        return text
    }
}

/// Build 14: a copy iOS paused (its continued task expired), kept until *Continue copy* or *Discard* as a small JSON
/// file in Application Support (never in UserDefaults: it can hold a security-scoped bookmark). It has what the
/// continuation needs (the link and session, the run folder, the files left) and what the copy's measurements need
/// once it ends, since they cover the whole copy across pauses.
struct CopyPauseRecord: Codable, Sendable {
    struct File: Codable, Sendable {
        /// The name the copy uses (Wi-Fi: "object-N.ARW" for an object without a name).
        let name: String
        /// Bytes from the listing; 0 when unknown.
        let size: UInt64
        /// The PTP object handle, tried first when the card is listed again; nil when unknown (USB in MSC).
        let handle: UInt32?
        /// USB: the name of the DCIM folder holding the file ("100MSDCF"), so two files of the same name and size in
        /// different folders aren't taken for each other; nil over Wi-Fi and in records from before it was kept.
        var folder: String? = nil
    }

    /// The Wi-Fi session to reopen: the network, the camera's address, this app's GUID and the kind of session.
    struct WiFiSession: Codable, Sendable {
        /// "ap" or "lan".
        let net: String
        let host: String
        let guid: String
        /// A SonyContentsMode raw value; nil for a plain session.
        let contentsMode: String?
    }

    /// "usb", "ptpip.ap" or "ptpip.lan".
    let link: String
    /// The kind of session that listed the files (Wi-Fi), as CopyAllRun.session.
    let session: String?
    let wifi: WiFiSession?
    let folderName: String
    /// Where the run folder is, as CopyAllRun.destination (never a full path).
    let destination: String
    /// A bookmark to the folder chosen in Files that holds the run folder; nil for the default folder.
    var bookmark: Data?
    /// Not copied yet, in copy order (the file in flight at the expiry first among them).
    let remaining: [File]
    let total: Int
    let totalBytes: UInt64
    let copied: Int
    let failed: Int
    let bytes: UInt64
    /// The listed sizes of the files counted as failed, so the progress counts them as done.
    let failedBytes: UInt64
    let failures: [String]
    /// Var: a continued segment put back by repause keeps the recoveries it attempted (their rows are in the log).
    var recoveries: Int
    var recoveryCauses: [String]
    /// Active copying seconds up to this pause: each segment from its first request to its pause.
    let activeSeconds: Double
    /// What the copy runs under (Creators' App, Bluetooth recovery, the screen), as CopyAllRun.conditions.
    let conditions: String?
    /// The copy's first start (wall time is measured from it).
    let startedAt: Date
    /// The expiry.
    let pausedAt: Date
    /// Pauses so far, this one included, and the seconds of the earlier ones (each from the expiry to Continue).
    let pauses: Int
    let pauseSeconds: Double
    let wasLocked: Bool
    let lockedSeconds: Double
    let batteryBefore: Float?
    let batteryStateBefore: String
    /// The conditions at the expiry (ContinuedTask.conditions()).
    let expiry: String
    /// The card's other ARW at the pause (copied, failed, or not part of the copy): when Continue copy finds the files
    /// left again, these claim their matches first, so with two ARW of the same name and size (File Number Reset
    /// across DCIM folders) one already copied isn't taken for one left. Nil in records from before it was kept.
    var others: [File]? = nil
    /// The copy's memory peak so far and the footprint when its first segment started (bytes), so one
    /// `<link>.copyAll.memory.peak` covers the whole copy. Nil in records from before they were kept.
    var memoryPeak: UInt64? = nil
    var memoryBaseline: UInt64? = nil
    /// The battery (0–1) the segments before this pause used, each from its start to its pause, so `phoneBattery`
    /// leaves the pauses out. Nil when a level couldn't be read, or in records from before it was kept.
    var batteryUsed: Float? = nil

    var done: Int { copied + failed }
    var doneBytes: UInt64 { bytes + failedBytes }

    /// The Wired or Wi-Fi tab's copy section shows it ("USB-C" or "Wi-Fi").
    func belongs(toLinkName linkName: String) -> Bool {
        linkName == "USB-C" ? link == "usb" : link.hasPrefix("ptpip")
    }

    /// For the copy sections: "Paused at 102 of 267 ARW (4.31 GB) at 14:02, when iOS ended the continued task · into
    /// Copy 2026-11-03 13.51.10". iOS ends it on an expiry and when Stop is tapped in the Live Activity alike.
    var summary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        var text = "Paused at \(done) of \(total) ARW (\(CopyAllFormat.gb(bytes))) at \(formatter.string(from: pausedAt)), when iOS ended the continued task"
        if failed > 0 { text += ", \(failed) failed" }
        if pauses > 1 { text += " (pause \(pauses))" }
        return text + " · into \(destination) › \(folderName)"
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
    /// Build 14: the copy iOS paused (its continued task expired), until Continue copy or Discard; read from its file
    /// at launch, since iOS may end the app while it is paused.
    private(set) var paused: CopyPauseRecord?
    /// Build 14: pause records saved since launch: the guided run looks for this to change when its copy ends.
    private(set) var pausesSaved = 0
    /// Build 14: paused copies discarded since launch (discardPaused records their measurements and sets lastOutcome):
    /// the guided run looks for this to change, since Discard on a tab can be tapped while it asks about a pause.
    private(set) var discards = 0
    /// Build 14: keep the screen on (no Auto-Lock) while a copy runs with the app in front; kept in UserDefaults.
    var keepScreenOn: Bool {
        get { keepScreenOnSetting }
        set {
            keepScreenOnSetting = newValue
            UserDefaults.standard.set(newValue, forKey: Self.keepScreenOnKey)
        }
    }
    static let keepScreenOnKey = "copyAll.keepScreenOn"
    /// Observed storage behind `keepScreenOn`.
    private var keepScreenOnSetting = UserDefaults.standard.bool(forKey: "copyAll.keepScreenOn")

    @ObservationIgnored private let log: SpikeLog
    /// Build 14: isIdleTimerDisabled from before the running copy set it (nil: the copy didn't set it).
    @ObservationIgnored private var idleTimerWas: Bool?

    init() {
        log = SpikeLog.shared
        if UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil {
            pickedName = UserDefaults.standard.string(forKey: Self.folderNameKey) ?? "chosen folder"
        }
        paused = Self.loadPauseRecord(log: log)
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
        try spaceCheck(items: items, root: resolved.root, description: resolved.description, link: link, continuing: false)
    }

    /// checkSpace's arithmetic, log line and refusals for the folder `root` (inside its security scope). Build 14:
    /// `continuing`, Continue copy's check (FilesDestination.resume) for the files left of a paused copy, since a pause
    /// can last hours and anything saved meanwhile comes out of the margin the start check left.
    private func spaceCheck(items: [CopyAllItem], root: URL, description: String, link: String, continuing: Bool) throws {
        let total = items.reduce(UInt64(0)) { $0 + $1.size }
        let largest = items.map(\.size).max() ?? 0
        let margin: UInt64 = 1_000_000_000
        let tmp = FileManager.default.temporaryDirectory
        let destinationFree = CopyAllFiles.freeBytes(at: root)
        let tmpFree = CopyAllFiles.freeBytes(at: tmp)
        let same = CopyAllFiles.sameVolume(tmp, root) ?? false
        func free(_ bytes: Int64?) -> String { bytes.map { CopyAllFormat.gb($0) } ?? "unknown" }

        // Same volume: each file is renamed out of tmp, so the volume ends up holding all of them, plus a margin.
        // Another volume: the destination takes all of them, tmp only the one in flight.
        let destinationNeeds = same ? total + margin : total + 100_000_000
        let tmpNeeds = largest + margin
        let what = continuing ? "Continue copy's check: \(items.count) ARW left" : "\(items.count) ARW"
        var line = "Copy all RAW (\(link)): \(what), \(CopyAllFormat.gb(total)) (largest \(CopyAllFormat.gb(largest))) to \(description); "
            + "destination volume \(free(destinationFree)) free, needs \(CopyAllFormat.gb(destinationNeeds))"
        line += same ? "; the temporary folder is on the same volume" : "; temporary folder \(free(tmpFree)) free, needs \(CopyAllFormat.gb(tmpNeeds))"
        log.note(line)

        let again = continuing ? "; free some space and tap Continue copy again (the copy is still paused)" : ""
        if let destinationFree, UInt64(max(0, destinationFree)) < destinationNeeds {
            throw CopyAllError.message("not enough free space at \(description): \(CopyAllFormat.gb(destinationFree)) free, \(CopyAllFormat.gb(destinationNeeds)) needed for \(items.count) ARW (\(CopyAllFormat.gb(total)))\(again)")
        }
        if !same, let tmpFree, UInt64(max(0, tmpFree)) < tmpNeeds {
            throw CopyAllError.message("not enough free space on the phone for the temporary copy: \(CopyAllFormat.gb(tmpFree)) free, \(CopyAllFormat.gb(tmpNeeds)) needed\(again)")
        }
        if destinationFree == nil {
            log.warn("Copy all RAW: the destination's free space can't be read (a cloud or external provider?); copying anyway")
        }
        if destinationFree != nil && description != Self.defaultDescription {
            log.note("Copy all RAW: for iCloud Drive the figure is the phone's own free space, not the iCloud quota")
        }
    }

    // MARK: A run

    /// Starts a run inside the continued task: resolves the destination (starting its security scope), creates the run
    /// folder and an empty temporary folder, and starts watching the lock and the battery.
    /// `session`: what kind of session listed the files when that matters (Wi-Fi), for the ▶ line and `finished`.
    /// `conditions` (build 14, Wi-Fi): what the run was copied under (Creators' App, Bluetooth recovery), added to the
    /// context of every copy measurement.
    /// Build 14: whether the screen is kept on, for every copy measurement's context (via the run's conditions).
    var screenCondition: String {
        keepScreenOn ? "screen kept on during the copy" : "screen not kept on (Auto-Lock as set)"
    }

    func begin(link: String, items: [CopyAllItem], session: String? = nil, conditions: String? = nil) throws -> CopyAllRun {
        guard run == nil else { throw CopyAllError.message("a copy is already running") }
        let resolved = try resolve()
        // Build 14: the screen setting goes with every copy measurement, over USB too.
        let allConditions = [conditions, screenCondition].compactMap { $0 }.joined(separator: "; ")
        do {
            let folder = try CopyAllFiles.makeRunFolder(in: resolved.root, startedAt: Date())
            let tmp = FileManager.default.temporaryDirectory.appending(path: "copy-all", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let same = CopyAllFiles.sameVolume(tmp, folder) ?? false
            let started = CopyAllRun(link: link, items: items, root: resolved.root, scoped: resolved.scoped, folder: folder,
                                     temporaryDirectory: tmp, destination: resolved.description, sameVolume: same,
                                     session: session, conditions: allConditions, log: log)
            run = started
            holdScreen()
            log.note("▶ Copy all RAW to Files (\(link)\(session.map { ", \($0)" } ?? ""); \(allConditions)): \(items.count) ARW, \(CopyAllFormat.gb(started.totalBytes)), oldest first, into \(resolved.description) › \(started.folderName) (\(same ? "same volume: each file is renamed into place" : "another volume: each file is copied, then the temporary copy deleted"))")
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
        // The pause this segment continued from, if not recorded yet (no file copied in this segment).
        run.flushPauseSeconds()
        let finished = stopReason == nil && run.copied == run.total
        let seconds = run.transferSeconds
        let thermal = CopyAllFormat.thermalState()
        // Measurement contexts go into the pasted table: they say which kind of folder, never its name.
        let label = run.destinationLabel
        // Build 14: what the run was copied under (Creators' App, Bluetooth recovery), on every copy measurement.
        let conditions = run.conditions.map { "; \($0)" } ?? ""

        log.measure("\(p).files", Double(run.copied), "count", context: "of \(run.total) ARW listed; into \(label)\(conditions)")
        log.measure("\(p).failed", Double(run.failed), "count",
                    context: (run.failures.isEmpty ? "none" : run.failures.prefix(5).joined(separator: "; ") + (run.failures.count > 5 ? "; …" : "")) + conditions)
        log.measure("\(p).size", Double(run.bytes) / 1e6, "MB", context: "\(run.copied) ARW, \(CopyAllFormat.gb(run.bytes))\(conditions)")
        if run.link.hasPrefix("ptpip") {
            log.measure("\(p).recoveries", Double(run.recoveries), "count",
                        context: (run.recoveryCauses.isEmpty ? "none" : run.recoveryCauses.joined(separator: "; ")) + conditions)
        }
        // Build 14: a copy iOS paused and the tester continued is measured as one copy: files, size and failed across
        // the pauses, seconds and throughput from the active copying time (each segment from its first request to its
        // pause, the last to its last move), the wall time from the first start in the context.
        let wallSeconds = Date().timeIntervalSince(run.startedAt)
        let pausedText = run.pauses > 0
            ? String(format: "; %ld pause(s) by iOS, %.0f s paused in all (expiry to Continue), wall time %.1f min from the first start",
                     run.pauses, run.pauseSeconds, wallSeconds / 60)
            : ""
        log.measure("\(p).pauses", Double(run.pauses), "count",
                    context: (run.pauses > 0 ? String(format: "iOS ended the continued task %ld time(s) (an expiry, or Stop in the Live Activity) and the copy was continued; %.0f s paused in all, wall time %.1f min", run.pauses, run.pauseSeconds, wallSeconds / 60) : "none") + conditions)
        if let seconds {
            let span = run.pauses > 0 ? "active copying time across \(run.pauses + 1) segments (each first request to its pause or last move)" : "first request to last move"
            log.measure("\(p).seconds", seconds, "s", context: String(format: "%@, %.1f min", span, seconds / 60) + pausedText + conditions)
            log.throughput("\(p).throughput", bytes: Int(run.bytes), seconds: seconds,
                           context: String(format: "%ld ARW, %@ in %.1f s (%@, moves included)%@",
                                           run.copied, CopyAllFormat.gb(run.bytes), seconds, span, run.failed > 0 ? ", \(run.failed) failed" : "")
                            + (run.recoveries > 0 ? ", recovery time included (\(run.recoveries))" : "") + pausedText + conditions)
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
        let recovered = run.recoveries > 0 ? "; \(run.recoveries) recover\(run.recoveries == 1 ? "y" : "ies")" : ""
        log.flag("\(p).finished", finished, context: "\(run.copied) of \(run.total) copied; \(ending)\(recovered)\(session); thermal state \(thermal)\(pausedText)\(conditions)")
        // Build 14: the lock is watched only while a segment runs, so a paused copy's denominator leaves the pauses out.
        let watchedText = run.pauses > 0
            ? String(format: "%.0f s of copying (wall time less the %.0f s paused)", max(0, wallSeconds - run.pauseSeconds), run.pauseSeconds)
            : String(format: "%.0f s", wallSeconds)
        log.flag("\(p).underLock", run.wasLocked,
                 context: String(format: "locked for about %.0f s of %@ (protected-data notifications and checks after each file; a phone without a passcode never reports a lock)",
                                 run.lockedSeconds, watchedText) + conditions)
        if run.pauses == 0, let before = run.batteryBefore, let after = run.batteryAfter {
            log.measure("\(p).phoneBattery", Double(before - after) * 100, "points",
                        context: String(format: "%.0f %% → %.0f %% over %@ (%@ at the start, %@ at the end)",
                                        Double(before) * 100, Double(after) * 100, CopyAllFormat.gb(run.bytes),
                                        run.batteryStateBefore, run.batteryStateAfter) + conditions)
        } else if run.pauses > 0, let used = run.batteryUsed {
            // Build 14: each segment from its start to its pause or end, summed: the pauses (idle, other use or charging) left out.
            log.measure("\(p).phoneBattery", Double(used) * 100, "points",
                        context: String(format: "%.0f %% used over %@ while copying, summed over %ld segments (each from its start to its pause or end; the pauses left out); %@ at the first start, %@ at the end",
                                        Double(used) * 100, CopyAllFormat.gb(run.bytes), run.pauses + 1,
                                        run.batteryStateBefore, run.batteryStateAfter) + pausedText + conditions)
        } else if run.pauses > 0 {
            log.note("Copy all RAW (\(run.link)): a segment's battery level couldn't be read; \(p).phoneBattery not recorded (the battery after a pause says nothing about the copy)")
        } else {
            log.note("Copy all RAW (\(run.link)): the phone's battery level couldn't be read; \(p).phoneBattery not recorded")
        }
        if run.memoryPeak > 0 {
            // Build 14: one value per copy, the highest over its segments (each segment is sampled, nothing recorded).
            let segments = run.pauses > 0 ? "; the highest over \(run.pauses + 1) segments" : ""
            log.measure("\(p).memory.peak", Double(run.memoryPeak) / 1_000_000, "MB",
                        context: "baseline \(run.memoryBaseline / 1_000_000) MB, \(run.total) ARW to Files over \(run.link == "usb" ? "USB" : "PTP/IP")\(segments)\(conditions)")
        }

        let gigabytes = Double(run.bytes) / 1e9
        let minutes = (seconds ?? 0) / 60
        let rate = (seconds ?? 0) > 0 ? Double(run.bytes) / (seconds ?? 1) / 1e6 : 0
        log.note(String(format: "◼ Copy all RAW to Files (%@): %ld of %ld ARW copied, %ld failed, %.2f GB in %.1f min = %.1f MB/s, into %@ › %@; %@; thermal state %@",
                        run.link, run.copied, run.total, run.failed, gigabytes, minutes, rate, run.destination, run.folderName,
                        ending, thermal) + recovered + pausedText + conditions)

        try? FileManager.default.removeItem(at: run.temporaryDirectory)
        if run.scoped { run.root.stopAccessingSecurityScopedResource() }
        releaseScreen()
        lastOutcome = CopyAllOutcome(prefix: p, folderName: run.folderName, destination: run.destination,
                                     destinationLabel: label, total: run.total,
                                     copied: run.copied, failed: run.failed, bytes: run.bytes, seconds: seconds,
                                     finished: finished, stopReason: stopReason, recoveries: run.recoveries,
                                     pauses: run.pauses)
        runsFinished += 1
        if self.run === run { self.run = nil }
    }

    // MARK: Pause and continue (build 14)

    /// The pause record's file: Application Support, never UserDefaults (it can hold a security-scoped bookmark).
    static var pauseRecordURL: URL {
        URL.applicationSupportDirectory.appending(path: "copy-pause.json", directoryHint: .notDirectory)
    }

    /// The pause record, if there is one. One that doesn't decode (a later build changed its fields, or the file is
    /// damaged) is logged, without paths, and moved aside as copy-pause.unreadable.json, so it doesn't vanish unexplained
    /// and isn't tried again at every launch. One that can't be read at all (a launch before the phone's first unlock)
    /// is logged and kept.
    private static func loadPauseRecord(log: SpikeLog) -> CopyPauseRecord? {
        let url = pauseRecordURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.warn("Copy all RAW: a paused copy's record is there but couldn't be read now (\(CopyAllFormat.describe(error))); it is kept and read again at the next launch")
            return nil
        }
        do {
            return try JSONDecoder().decode(CopyPauseRecord.self, from: data)
        } catch {
            // A DecodingError names the field, never a path.
            let why = String(describing: error)
            let aside = url.deletingLastPathComponent().appending(path: "copy-pause.unreadable.json", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: aside)
            let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
            if !moved { try? FileManager.default.removeItem(at: url) }
            log.warn("Copy all RAW: a paused copy's record couldn't be read (\(why)); it can't be continued: start a new copy (the files it copied stay in its folder). The record was \(moved ? "moved aside as copy-pause.unreadable.json" : "deleted")")
            return nil
        }
    }

    private static func savePauseRecord(_ record: CopyPauseRecord) throws {
        let url = pauseRecordURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    private static func deletePauseRecord() {
        try? FileManager.default.removeItem(at: pauseRecordURL)
    }

    /// iOS ended the copy's continued task (an expiry, or Stop in the Live Activity: both reach the expiration handler
    /// and iOS gives no reason): the copy has finished nothing more (the caller has cut the file in flight off). Saves
    /// the pause record first (the app may be suspended soon after), then records `<link>.copyAll.expired` with the
    /// conditions at the expiry, logs it, and ends the run without its measurements, which come when the continued
    /// copy ends (or at Discard): watching stops, the temporary folder (with any partial download) is deleted, the
    /// security scope is stopped and the screen released. Last, it posts a notification if notifications are allowed
    /// (never asking for permission), waiting at most about 2 s for it, so the caller's work (and with it the task)
    /// ends only once it is posted. `remaining`: the files not copied, in order; `others`: the card's other ARW (see
    /// CopyPauseRecord.others). The active seconds run to `expiredAt`, not to now, so time spent winding down (or
    /// suspended) after the expiry isn't counted. Throws when the record can't be saved; the caller then finishes the
    /// run instead (nothing paused).
    func pause(_ run: CopyAllRun, remaining: [CopyPauseRecord.File], others: [CopyPauseRecord.File] = [],
               wifi: CopyPauseRecord.WiFiSession?, expiredAt: Date, expiry: String) async throws {
        // The pause this segment continued from, if not recorded yet (no file copied in this segment).
        run.flushPauseSeconds()
        var bookmark: Data?
        if run.destination != Self.defaultDescription {
            // A fresh bookmark to the folder the run is writing into, while its security scope is still on.
            do {
                bookmark = try run.root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey)
                log.warn("Copy all RAW: couldn't make a bookmark to the chosen folder for the pause record (\(error.localizedDescription)); keeping the chosen folder's saved bookmark")
            }
        }
        let active = run.activeSeconds(until: expiredAt)
        run.endWatching()
        let record = CopyPauseRecord(link: run.link, session: run.session, wifi: wifi, folderName: run.folderName,
                                     destination: run.destination, bookmark: bookmark, remaining: remaining,
                                     total: run.total, totalBytes: run.totalBytes, copied: run.copied, failed: run.failed,
                                     bytes: run.bytes, failedBytes: run.failedBytes, failures: run.failures,
                                     recoveries: run.recoveries, recoveryCauses: run.recoveryCauses, activeSeconds: active,
                                     conditions: run.conditions, startedAt: run.startedAt, pausedAt: expiredAt,
                                     pauses: run.pauses + 1, pauseSeconds: run.pauseSeconds, wasLocked: run.wasLocked,
                                     lockedSeconds: run.lockedSeconds, batteryBefore: run.batteryBefore,
                                     batteryStateBefore: run.batteryStateBefore, expiry: expiry, others: others,
                                     memoryPeak: run.memoryPeak > 0 ? run.memoryPeak : nil,
                                     memoryBaseline: run.memoryPeak > 0 ? run.memoryBaseline : nil,
                                     batteryUsed: run.batteryUsed)
        try Self.savePauseRecord(record)
        paused = record
        pausesSaved += 1
        let conditions = run.conditions.map { "; \($0)" } ?? ""
        let tab = run.link == "usb" ? "Wired" : "Wi-Fi"
        log.flag("\(run.prefix).expired", true,
                 context: String(format: "iOS ended the continued task (an expiry, or Stop in the Live Activity; no reason given) at %ld of %ld ARW, %@ copied, after %.0f s of active copying; ",
                                 record.done, record.total, CopyAllFormat.gb(record.bytes), active)
                    + "\(expiry); the copy is paused (pause \(record.pauses)), \(remaining.count) ARW left\(conditions)")
        log.warn("⏸ Copy all RAW to Files (\(run.link)) paused at \(record.done) of \(record.total) ARW (\(CopyAllFormat.gb(record.bytes))): iOS ended the continued task (an expiry, or Stop in the Live Activity); \(remaining.count) left; the pause record is saved; Continue copy (or Discard) on the \(tab) tab once the app is in front again; conditions then: \(expiry)")
        try? FileManager.default.removeItem(at: run.temporaryDirectory)
        if run.scoped { run.root.stopAccessingSecurityScopedResource() }
        releaseScreen()
        if self.run === run { self.run = nil }
        await notifyPaused(record)
    }

    static let pauseNotificationID = "spike.copyAll.paused"
    /// Pause notifications being posted (notifyPaused waits for this to drop back).
    @ObservationIgnored private var pauseNotificationsPending = 0

    /// "Copy paused at N of M (X GB). Open SB Spike to continue.", only when notifications are allowed: this never asks.
    /// Waits about 2 s at most for the two round trips (settings, add): the caller's continued task completes once its
    /// work returns, and the app may be suspended straight after, which would hold the notification back until the
    /// app is next opened.
    private func notifyPaused(_ record: CopyPauseRecord) async {
        let body = "Copy paused at \(record.done) of \(record.total) (\(CopyAllFormat.gb(record.bytes))). Open \(Self.appFolderName) to continue."
        pauseNotificationsPending += 1
        Task { @MainActor in
            defer { self.pauseNotificationsPending -= 1 }
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else {
                self.log.note("Copy all RAW: no notification for the pause: notifications aren't allowed for the app (the copy doesn't ask)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Copy paused"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: Self.pauseNotificationID, content: content, trigger: nil)
            do {
                try await center.add(request)
                self.log.note("Copy all RAW: notification posted: \(body)")
            } catch {
                self.log.warn("Copy all RAW: the pause notification wasn't posted: \(error.localizedDescription)")
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        while pauseNotificationsPending > 0 && (clock.now - started).inSeconds < 2 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if pauseNotificationsPending > 0 {
            log.note("Copy all RAW: the pause notification wasn't confirmed within 2 s; the copy's work ends anyway")
        }
    }

    /// The pause notification, once it is no longer needed (Continue copy or Discard).
    private func removePauseNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pauseNotificationID])
    }

    /// Continue copy: resolves the folder the paused copy was writing into again (the record's bookmark, with stale
    /// handling as `resolve`, or the default folder), starts its security scope, finds the run folder by name, and
    /// starts a run that carries on the paused copy's counts, bytes, active time, pauses and conditions, into the same
    /// run folder. Holds `<link>.copyAll.pause.seconds` (from the expiry to `tappedAt`, the Continue tap) on the run,
    /// which records it once the segment copies a file, pauses again or ends, and deletes the pause record. Throws,
    /// keeping the record, when the folder can't be used, when there isn't enough free space for the files left (the start's check, again: a pause can last hours), or when the paused copy was discarded or
    /// replaced after the tap. The caller has already got the session back and listed the card. `change` (Wi-Fi): what
    /// this segment may do differently from the start, e.g. "Bluetooth recovery off", added to the conditions.
    func resume(_ record: CopyPauseRecord, tappedAt: Date, change: String? = nil) throws -> CopyAllRun {
        guard run == nil else { throw CopyAllError.message("a copy is already running") }
        // The record captured at the tap must still be the paused copy (Discard can be tapped while the session opens).
        guard let current = paused, current.pausedAt == record.pausedAt, current.folderName == record.folderName else {
            throw CopyAllError.message("the paused copy was discarded (or replaced) after Continue copy was tapped; nothing was continued")
        }
        let resolved = try resolveForContinuation(record)
        do {
            let folder = resolved.root.appending(path: record.folderName, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CopyAllError.message("the run folder \(record.folderName) isn't in \(resolved.description) any more; Discard the paused copy and copy again")
            }
            let tmp = FileManager.default.temporaryDirectory.appending(path: "copy-all", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let same = CopyAllFiles.sameVolume(tmp, folder) ?? false
            // Inside this do block, so a refusal stops the folder's security scope, and before the record is deleted.
            try spaceCheck(items: record.remaining.map { CopyAllItem(name: $0.name, size: $0.size) }, root: folder,
                           description: resolved.description, link: record.link, continuing: true)
            let pauseSeconds = max(0, tappedAt.timeIntervalSince(record.pausedAt))
            // The conditions the copy started under; the screen setting at Continue only when it changed.
            var conditions = record.conditions ?? ""
            if !conditions.contains(screenCondition) {
                conditions += (conditions.isEmpty ? "" : "; ") + "after pause \(record.pauses): \(screenCondition)"
            }
            if let change, !conditions.contains("after pause \(record.pauses): \(change)") {
                conditions += (conditions.isEmpty ? "" : "; ") + "after pause \(record.pauses): \(change)"
            }
            let started = CopyAllRun(link: record.link, items: record.remaining.map { CopyAllItem(name: $0.name, size: $0.size) },
                                     root: resolved.root, scoped: resolved.scoped, folder: folder, temporaryDirectory: tmp,
                                     destination: resolved.description, sameVolume: same, session: record.session,
                                     conditions: conditions.isEmpty ? nil : conditions, log: log,
                                     restoring: record, pauseSeconds: pauseSeconds)
            run = started
            // Recorded once this segment copies a file, pauses again or ends (CopyAllRun.flushPauseSeconds); not if it
            // loses its session first and the record is put back (repause), so each pause has one value.
            started.holdPauseSeconds(pauseSeconds,
                                     context: String(format: "pause %ld: from iOS expiring the continued task at %ld of %ld ARW to Continue; conditions at the expiry: %@",
                                                     record.pauses, record.done, record.total, record.expiry)
                                        + (started.conditions.map { "; \($0)" } ?? ""))
            Self.deletePauseRecord()
            paused = nil
            removePauseNotification()
            holdScreen()
            log.note("▶ Copy all RAW to Files continues (\(record.link)\(record.session.map { ", \($0)" } ?? ""); pause \(record.pauses) ended after \(String(format: "%.0f", pauseSeconds)) s): \(record.remaining.count) ARW left of \(record.total), \(CopyAllFormat.gb(record.doneBytes)) of \(CopyAllFormat.gb(record.totalBytes)) done, into the same folder, \(resolved.description) › \(record.folderName)")
            return started
        } catch {
            if resolved.scoped { resolved.root.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// The folder holding the paused copy's run folder: the record's bookmark resolved (a stale one re-created and
    /// kept in the record, as `resolve` keeps the chosen folder's; one now in Recently Deleted or on a camera card
    /// refused), or the default folder when the record has none.
    private func resolveForContinuation(_ record: CopyPauseRecord) throws -> Resolved {
        guard let data = record.bookmark else {
            let root = URL.documentsDirectory.appending(path: Self.defaultFolderName, directoryHint: .isDirectory)
            return Resolved(root: root, scoped: false, description: Self.defaultDescription)
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw CopyAllError.message("the folder the paused copy was writing into can't be found (\(error.localizedDescription)); Discard the paused copy and copy again")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        if let refusal = CopyAllFiles.refusal(for: url) {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw CopyAllError.message("the folder \"\(name)\" the paused copy was writing into \(refusal); Discard the paused copy")
        }
        if !scoped {
            log.warn("Copy all RAW: no security scope for the folder \"\(name)\" the paused copy was writing into (startAccessingSecurityScopedResource returned false); trying anyway")
        }
        if stale {
            do {
                var updated = record
                updated.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                try Self.savePauseRecord(updated)
                if paused != nil { paused = updated }
                log.note("Copy all RAW: the paused copy's bookmark to \"\(name)\" was stale; re-created it")
            } catch {
                log.warn("Copy all RAW: the paused copy's bookmark to \"\(name)\" is stale and couldn't be re-created (\(error.localizedDescription)); using it this time")
            }
        }
        return Resolved(root: url, scoped: scoped, description: "\(name) (chosen in Files)")
    }

    /// Discard: deletes the pause record only. The files already copied stay in the run folder. The copy's standard
    /// measurements are recorded from the record, as a copy that ended early ("discarded after pause N"): files,
    /// failed, size, seconds and throughput from the active copying time, recoveries (Wi-Fi), pauses, underLock,
    /// memory.peak (the highest over the segments) and finished (no). phoneBattery isn't: the battery now, after a
    /// pause of any length, says nothing about the copy.
    func discardPaused() {
        guard let record = paused else { return }
        Self.deletePauseRecord()
        paused = nil
        removePauseNotification()
        let p = "\(record.link).copyAll"
        let ended = "discarded after pause \(record.pauses), \(record.remaining.count) ARW not copied"
        let label = record.destination == Self.defaultDescription ? "the default folder" : "a folder chosen in Files"
        let conditions = record.conditions.map { "; \($0)" } ?? ""
        let wallSeconds = record.pausedAt.timeIntervalSince(record.startedAt)
        let pausedText = String(format: "; %ld pause(s), %.0f s paused before the last one (expiry to Continue), wall time %.1f min from the first start to the last pause",
                                record.pauses, record.pauseSeconds, wallSeconds / 60)
        log.measure("\(p).files", Double(record.copied), "count", context: "of \(record.total) ARW listed; into \(label); \(ended)\(conditions)")
        let failuresText: String
        if record.failures.isEmpty {
            failuresText = "none"
        } else {
            failuresText = record.failures.prefix(5).joined(separator: "; ") + (record.failures.count > 5 ? "; …" : "")
        }
        log.measure("\(p).failed", Double(record.failed), "count", context: "\(failuresText); \(ended)\(conditions)")
        log.measure("\(p).size", Double(record.bytes) / 1e6, "MB", context: "\(record.copied) ARW, \(CopyAllFormat.gb(record.bytes)); \(ended)\(conditions)")
        if record.link.hasPrefix("ptpip") {
            let causes = record.recoveryCauses.isEmpty ? "none" : record.recoveryCauses.joined(separator: "; ")
            log.measure("\(p).recoveries", Double(record.recoveries), "count", context: "\(causes); \(ended)\(conditions)")
        }
        log.measure("\(p).pauses", Double(record.pauses), "count",
                    context: "iOS ended the continued task \(record.pauses) time(s); \(ended)\(pausedText)\(conditions)")
        if record.activeSeconds > 0 && record.copied > 0 {
            let span = "active copying time across \(record.pauses) segment(s) (each first request to its pause)"
            let minutes = String(format: "%.1f min", record.activeSeconds / 60)
            log.measure("\(p).seconds", record.activeSeconds, "s", context: "\(span), \(minutes); \(ended)\(pausedText)\(conditions)")
            let head = String(format: "%ld ARW, %@ in %.1f s", record.copied, CopyAllFormat.gb(record.bytes), record.activeSeconds)
            let failedText = record.failed > 0 ? ", \(record.failed) failed" : ""
            let recoveredText = record.recoveries > 0 ? ", recovery time included (\(record.recoveries))" : ""
            log.throughput("\(p).throughput", bytes: Int(clamping: record.bytes), seconds: record.activeSeconds,
                           context: "\(head) (\(span), moves included)\(failedText)\(recoveredText); \(ended)\(pausedText)\(conditions)")
        } else {
            log.note("Copy all RAW (\(record.link)): the discarded copy copied nothing, so no time or throughput")
        }
        let listedBy = record.session.map { "; listed by \($0)" } ?? ""
        log.flag("\(p).finished", false,
                 context: "\(record.copied) of \(record.total) copied; ended early: \(ended)\(listedBy)\(pausedText)\(conditions)")
        let lockedText = String(format: "locked for about %.0f s up to the last pause (protected-data notifications and checks after each file; a phone without a passcode never reports a lock)",
                                record.lockedSeconds)
        log.flag("\(p).underLock", record.wasLocked, context: "\(lockedText); \(ended)\(conditions)")
        if let peak = record.memoryPeak, peak > 0 {
            let baseline = (record.memoryBaseline ?? 0) / 1_000_000
            log.measure("\(p).memory.peak", Double(peak) / 1_000_000, "MB",
                        context: "baseline \(baseline) MB, \(record.total) ARW to Files over \(record.link == "usb" ? "USB" : "PTP/IP"); the highest over \(record.pauses) segment(s); \(ended)\(conditions)")
        }
        log.note("Copy all RAW (\(record.link)): the paused copy was discarded (only its pause record was deleted): \(record.done) of \(record.total) ARW done, \(CopyAllFormat.gb(record.bytes)) copied, stay in \(record.destination) › \(record.folderName); \(record.remaining.count) not copied; its measurements were recorded as a copy that ended early (no phoneBattery: the battery after the pause says nothing about the copy)")
        lastOutcome = CopyAllOutcome(prefix: p, folderName: record.folderName, destination: record.destination,
                                     destinationLabel: label, total: record.total, copied: record.copied, failed: record.failed,
                                     bytes: record.bytes, seconds: record.activeSeconds > 0 ? record.activeSeconds : nil,
                                     finished: false, stopReason: ended, recoveries: record.recoveries, pauses: record.pauses)
        discards += 1
    }

    /// Build 14: a continued segment that lost its session (USB: the camera removed, the session closed or the link
    /// stalled; Wi-Fi: the recovery failed or the recovery limit) before it copied a file. Rather than ending the copy
    /// for good, ends `run` without measurements and puts the paused copy's record back as it was at the tap: the files
    /// this segment counted as failed go back among the files left, so Continue copy can try again once the camera is
    /// back. Doesn't bump `pausesSaved` (iOS didn't pause it). The pause's `pause.seconds`, held on the run, isn't
    /// recorded: the next Continue records it once, from the same expiry, and this segment's time, lock and battery
    /// count as part of the pause. Kept from this segment: its recoveries (their `recovery.seconds` rows are in the
    /// log, so `recoveries` matches them) and its memory peak. False when the record can't be saved: the caller then
    /// finishes the run as before.
    func repause(_ run: CopyAllRun, record: CopyPauseRecord, why: String) -> Bool {
        var kept = record
        kept.recoveries = run.recoveries
        kept.recoveryCauses = run.recoveryCauses
        if run.memoryPeak > 0 {
            kept.memoryPeak = max(record.memoryPeak ?? 0, run.memoryPeak)
            kept.memoryBaseline = record.memoryBaseline ?? run.memoryBaseline
        }
        do {
            try Self.savePauseRecord(kept)
        } catch {
            log.error("Copy all RAW: the continued copy lost its session before copying a file, but the pause record couldn't be saved again (\(CopyAllFormat.describe(error))); the copy ends here")
            return false
        }
        run.dropPauseSeconds()
        run.endWatching()
        paused = kept
        let tab = record.link == "usb" ? "Wired" : "Wi-Fi"
        log.warn("⏸ Copy all RAW to Files (\(record.link)): the continued copy lost its session before copying a file (\(why)); the copy is still paused at \(record.done) of \(record.total) ARW with \(record.remaining.count) left (the failures of this attempt are dropped): Continue copy (or Discard) on the \(tab) tab once the camera is back")
        try? FileManager.default.removeItem(at: run.temporaryDirectory)
        if run.scoped { run.root.stopAccessingSecurityScopedResource() }
        releaseScreen()
        if self.run === run { self.run = nil }
        return true
    }

    /// Keep the screen on: isIdleTimerDisabled while the copy runs (it only matters with the app in front).
    private func holdScreen() {
        guard keepScreenOn, idleTimerWas == nil else { return }
        idleTimerWas = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        log.note("Copy all RAW: the screen stays on while the copy runs with the app in front (Auto-Lock off until it ends)")
    }

    private func releaseScreen() {
        guard let was = idleTimerWas else { return }
        UIApplication.shared.isIdleTimerDisabled = was
        idleTimerWas = nil
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
    /// Build 14: what the run was copied under ("Creators' App open in the background; Bluetooth recovery allowed" over
    /// Wi-Fi, and on both links whether the screen was kept on), for every copy measurement's context.
    let conditions: String?
    /// The copy's first start: this run's, or (a continued copy) the paused copy's.
    let startedAt: Date
    let batteryBefore: Float?
    let batteryStateBefore: String
    /// Build 14, a continued copy: the active copying seconds, pauses and paused seconds (expiry to Continue) before
    /// this run; 0 for a copy that hasn't been paused.
    let activeSecondsBefore: Double
    let pauses: Int
    let pauseSeconds: Double

    /// Build 14: recoveries the Wi-Fi copy attempted, and the cause of each.
    private(set) var recoveries = 0
    private(set) var recoveryCauses: [String] = []
    private(set) var copied = 0
    private(set) var failed = 0
    private(set) var bytes: UInt64 = 0
    /// Build 14: the listed sizes of the files counted as failed, so the byte progress counts them as done.
    private(set) var failedBytes: UInt64 = 0
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
    /// Build 14: listed size by lower-cased name, so a failed file's bytes count as done in the progress.
    @ObservationIgnored private let sizes: [String: UInt64]
    /// Build 14: `bytes` when this run started (a continued copy starts with the paused copy's), for the MB/s shown.
    @ObservationIgnored private var bytesAtStart: UInt64 = 0
    /// Build 14: the battery level when this segment started (the copy's start, or Continue), and the battery the
    /// earlier segments used (nil: unknown), so `phoneBattery` leaves the pauses out.
    @ObservationIgnored private let segmentBatteryBefore: Float?
    @ObservationIgnored private let batteryUsedBefore: Float?
    /// Build 14: a continued copy's `pause.seconds`, held until this segment copies a file, pauses again or ends.
    @ObservationIgnored private var pendingPauseSeconds: (seconds: Double, context: String)?
    /// Build 14: the copy's memory peak across its segments and the footprint at its first segment's start (bytes);
    /// 0 until a segment has been measured.
    @ObservationIgnored private(set) var memoryPeak: UInt64 = 0
    @ObservationIgnored private(set) var memoryBaseline: UInt64 = 0

    /// `restoring` (build 14): a continued copy, which takes the paused copy's totals, counts, bytes, failures,
    /// recoveries, active time, pauses, lock time and battery at the start from the record; `items` are then the files
    /// left, and `pauseSeconds` the pause that just ended (expiry to Continue).
    init(link: String, items: [CopyAllItem], root: URL, scoped: Bool, folder: URL, temporaryDirectory: URL,
         destination: String, sameVolume: Bool, session: String?, conditions: String? = nil, log: SpikeLog,
         restoring record: CopyPauseRecord? = nil, pauseSeconds: Double = 0) {
        self.link = link
        self.conditions = conditions
        self.sizes = Dictionary(items.map { ($0.name.lowercased(), $0.size) }, uniquingKeysWith: { first, _ in first })
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
        if let record {
            self.total = record.total
            self.totalBytes = record.totalBytes
            self.startedAt = record.startedAt
            self.activeSecondsBefore = record.activeSeconds
            self.pauses = record.pauses
            self.pauseSeconds = record.pauseSeconds + pauseSeconds
            batteryBefore = record.batteryBefore
            batteryStateBefore = record.batteryStateBefore
            segmentBatteryBefore = device.batteryLevel >= 0 ? device.batteryLevel : nil
            batteryUsedBefore = record.batteryUsed
        } else {
            self.total = items.count
            self.totalBytes = items.reduce(UInt64(0)) { $0 + $1.size }
            self.startedAt = Date()
            self.activeSecondsBefore = 0
            self.pauses = 0
            self.pauseSeconds = 0
            batteryBefore = device.batteryLevel >= 0 ? device.batteryLevel : nil
            batteryStateBefore = CopyAllRun.describe(device.batteryState)
            segmentBatteryBefore = batteryBefore
            batteryUsedBefore = 0
        }
        if let record {
            copied = record.copied
            failed = record.failed
            bytes = record.bytes
            failedBytes = record.failedBytes
            failures = record.failures
            recoveries = record.recoveries
            recoveryCauses = record.recoveryCauses
            wasLocked = record.wasLocked
            lockedSeconds = record.lockedSeconds
            bytesAtStart = record.bytes
            memoryPeak = record.memoryPeak ?? 0
            memoryBaseline = record.memoryBaseline ?? 0
        }

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
        // This run's own rate: a continued copy starts with the paused copy's bytes.
        if let firstRequestDate {
            let seconds = Date().timeIntervalSince(firstRequestDate)
            if seconds > 0, bytes > bytesAtStart { text += String(format: " · %.1f MB/s", Double(bytes - bytesAtStart) / seconds / 1e6) }
        }
        if failed > 0 { text += " · \(failed) failed" }
        return text
    }

    /// Wall time from the first request to the last move; nil until a file has been moved into place. Build 14: for a
    /// continued copy, plus the active copying time before the pauses (each earlier segment from its first request to
    /// its pause), so it is the whole copy's active time.
    var transferSeconds: Double? {
        guard let firstRequest, let lastMove else { return activeSecondsBefore > 0 ? activeSecondsBefore : nil }
        return activeSecondsBefore + (lastMove - firstRequest).inSeconds
    }

    /// Build 14: the active copying time up to `until` (the expiry, at a pause): earlier segments, then this one from its
    /// first request. Wall time, so the seconds between the expiry and the pause being saved (the copy winding down,
    /// or the app suspended meanwhile) aren't counted.
    func activeSeconds(until: Date) -> Double {
        activeSecondsBefore + max(0, until.timeIntervalSince(firstRequestDate ?? until))
    }

    /// Build 14: bytes of the files done, copied or counted as failed (listed size), for the byte progress.
    var doneBytes: UInt64 { bytes + failedBytes }

    /// Build 14: the battery (0–1) the copy used while copying: the earlier segments' (pause record) plus this one's,
    /// from its start to endWatching. The pauses are left out. Nil when a level couldn't be read.
    var batteryUsed: Float? {
        guard let used = batteryUsedBefore, let start = segmentBatteryBefore, let end = batteryAfter else { return nil }
        return used + (start - end)
    }

    /// Build 14: one segment's memory peak and its starting footprint (bytes); the copy keeps the highest peak and the
    /// first segment's baseline.
    func noteMemory(peak: UInt64, baseline: UInt64) {
        memoryPeak = max(memoryPeak, peak)
        if memoryBaseline == 0 { memoryBaseline = baseline }
    }

    /// Build 14: a continued copy's `pause.seconds`, recorded by flushPauseSeconds.
    func holdPauseSeconds(_ seconds: Double, context: String) {
        pendingPauseSeconds = (seconds, context)
    }

    /// Records the held `pause.seconds`, once: the first file this segment copies, a new pause, or the end.
    func flushPauseSeconds() {
        guard let pending = pendingPauseSeconds else { return }
        pendingPauseSeconds = nil
        log.measure("\(prefix).pause.seconds", pending.seconds, "s", context: pending.context)
    }

    /// The segment lost its session before copying a file and the record was put back (repause): the next Continue
    /// records the pause.
    func dropPauseSeconds() {
        pendingPauseSeconds = nil
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
        flushPauseSeconds()
        if !UIApplication.shared.isProtectedDataAvailable { wasLocked = true }
        let rate = seconds > 0 ? Double(received) / seconds / 1e6 : 0
        log.note(String(format: "  copy %ld/%ld: %@%@, %.1f MB in %.2f s = %.1f MB/s, move %.2f s%@ [%@]",
                        copied + failed, total, cardName, name == cardName ? "" : " → \(name)", Double(received) / 1e6,
                        seconds, rate, moveSeconds, detail.isEmpty ? "" : ", \(detail)", state))
        return name
    }

    /// Build 14: the Wi-Fi copy stopped for a recovery (`cause` names why); counted for `<link>.copyAll.recoveries`.
    func recoveryStarted(_ cause: String) {
        recoveries += 1
        recoveryCauses.append(cause)
        current = ""
    }

    /// A file that didn't download (or couldn't be moved): counted, logged, and the run goes on unless the caller ends it.
    func fileFailed(_ name: String, _ why: String) {
        failed += 1
        failedBytes += sizes[name.lowercased()] ?? 0
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
