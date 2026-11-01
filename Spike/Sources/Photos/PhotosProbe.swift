import Foundation
import Observation
import Photos
import UIKit

/// Not in the spike plan; added on 1 Nov for a product question: can every import go into an album in Photos, with
/// which access level, and can the app save to Photos while the phone is locked, inside a continued task?
///
/// What Apple's documentation says, as of 1 Nov 2026:
/// - Add-only access (the small prompt the proposal wants): nothing says an add-only app can create an album or find
///   it again. One forum report says both calls bring up the full read/write prompt.
/// - Limited access (read/write, where the user picks "Limit Access"): a WWDC21 session says apps can create, fetch
///   and update their own albums since iOS 15, but Apple's current privacy article still says they can't.
/// - Saving while locked: documented only for Lock Screen camera extensions (WWDC24). A staged file stays readable
///   while locked only with a protection class weaker than "complete", so the locked test saves one file of each.
///
/// Each step logs both access levels before it runs, and again after it if they changed. PhotoKit shows its prompts
/// asynchronously (a fetch returns at once and the prompt comes up afterwards), so a step's line can be written
/// before its prompt appears. PromptWatcher therefore logs when the app goes inactive during or just after a step,
/// and the access once it is active again.
@Observable
@MainActor
final class PhotosProbe {
    static let albumTitle = "SB Spike test album"
    private static let albumIDKey = "photos.testAlbumLocalIdentifier"

    var log: SpikeLog?
    private(set) var addOnly = "not checked"
    private(set) var readWrite = "not checked"
    private(set) var albumID: String?
    private(set) var lastResult = "none yet"
    private(set) var isBusy = false

    init() {
        albumID = UserDefaults.standard.string(forKey: Self.albumIDKey)
    }

    func refresh() {
        addOnly = Self.describe(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        readWrite = Self.describe(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    // MARK: - Steps (Background tab, in runbook order)

    func request(_ level: PHAccessLevel) {
        run("ask for \(Self.describe(level)) access") {
            let status = await PHPhotoLibrary.requestAuthorization(for: level)
            return "returned \(Self.describe(status))"
        }
    }

    func saveOnly() {
        run("save a test photo, no album") {
            let url = try Self.stageJPEG(label: "no album", protection: .completeFileProtectionUntilFirstUserAuthentication)
            defer { try? FileManager.default.removeItem(at: url) }
            let created = try await Self.save(url, newAlbumTitle: nil, into: nil)
            return "saved \(created.asset ?? "?")"
        }
    }

    func saveIntoNewAlbum() {
        run("save a test photo into a new album, in one change block") {
            let url = try Self.stageJPEG(label: "new album", protection: .completeFileProtectionUntilFirstUserAuthentication)
            defer { try? FileManager.default.removeItem(at: url) }
            let created = try await Self.save(url, newAlbumTitle: Self.albumTitle, into: nil)
            if let album = created.album { self.remember(album) }
            return "saved \(created.asset ?? "?") into new album \(created.album ?? "?")"
        }
    }

    func saveIntoExistingAlbum() {
        run("find the test album and save a test photo into it") {
            let found = self.findAlbum()
            guard let album = found.collection else { return "album not found (\(found.detail)); nothing saved" }
            let url = try Self.stageJPEG(label: "existing album", protection: .completeFileProtectionUntilFirstUserAuthentication)
            defer { try? FileManager.default.removeItem(at: url) }
            // Keep the lookup result even when the save fails: "found but couldn't add" is its own answer.
            do {
                let created = try await Self.save(url, newAlbumTitle: nil, into: album)
                return "album found (\(found.detail)); saved \(created.asset ?? "?")\(created.albumNote)"
            } catch {
                return "album found (\(found.detail)); save into it FAILED: \(Self.describe(error))"
            }
        }
    }

    /// Starts a continued task and waits for the phone to lock, then 15 s more (the keys for "complete" files are
    /// discarded about 10 s after the lock). Then three saves, each changing one thing:
    /// A1: complete-until-first-unlock file, no album; A2: the same class, added to the test album found before the
    /// lock; B: complete file, no album (expected to fail while locked). Then it looks the album up again. Each save
    /// logs whether the phone was locked when it started and when it finished, and whether the task had been stopped
    /// or expired; only a save locked at both ends counts as a locked result.
    func startLockedSave(using task: ContinuedTask) {
        guard !isBusy, !task.isRunning else { log?.warn("photos: locked save test not started: another test is running"); return }
        let before = access()
        let found = findAlbum()
        let fileA1: URL, fileA2: URL, fileB: URL
        do {
            let untilUnlock = Data.WritingOptions.completeFileProtectionUntilFirstUserAuthentication
            fileA1 = try Self.stageJPEG(label: "locked, A1: complete until first unlock, no album", protection: untilUnlock)
            fileA2 = try Self.stageJPEG(label: "locked, A2: complete until first unlock, album", protection: untilUnlock)
            fileB = try Self.stageJPEG(label: "locked, B: complete, no album", protection: .completeFileProtection)
        } catch {
            log?.error("photos: locked save test could not stage its files: \(Self.describe(error))")
            return
        }
        log?.note("photos: locked save test ready; album before the lock: \(found.detail); access \(before). Lock the phone now and leave it locked for a minute.")
        lastResult = "locked save test: waiting for the lock"
        // Progress units: up to 120 one-second waits for the lock, 15 for the keys to go, then 5 for the saves and
        // the lookup. The count moves every second so the system sees progress.
        task.run(title: "Saving to Photos (spike)", subtitle: "Lock the phone now", totalUnits: 140) { [weak self] report, shouldStop in
            defer { for file in [fileA1, fileA2, fileB] { try? FileManager.default.removeItem(at: file) } }
            guard let self else { return false }
            var waited = 0
            while UIApplication.shared.isProtectedDataAvailable {
                if shouldStop() {
                    self.log?.warn("photos: locked save test ended: the task was stopped or expired while waiting for the lock")
                    self.lastResult = "locked save test: stopped or expired"
                    return false
                }
                if waited >= 120 {
                    self.log?.warn("photos: locked save test ended: the phone was not locked within 2 minutes")
                    self.lastResult = "locked save test: the phone was not locked"
                    return false
                }
                try? await Task.sleep(for: .seconds(1))
                waited += 1
                report(waited, nil)
            }
            self.log?.note("photos: phone locked after \(waited) s; waiting 15 s more")
            for second in 1 ... 15 {
                try? await Task.sleep(for: .seconds(1))
                if shouldStop() {
                    self.log?.warn("photos: locked save test ended: the task was stopped or expired \(second) s after the lock, before any save")
                    self.lastResult = "locked save test: stopped or expired"
                    return false
                }
                report(120 + second, second == 1 ? "Locked; saving in 15 s" : nil)
            }
            await self.lockedSave(fileA1, label: "A1 (complete until first unlock, no album)", album: nil, shouldStop: shouldStop)
            report(136, "Saved A1")
            if let album = found.collection {
                await self.lockedSave(fileA2, label: "A2 (complete until first unlock, into the album)", album: album, shouldStop: shouldStop)
            } else {
                self.log?.note("photos: locked save A2 skipped: no test album was found before the lock (\(found.detail))")
            }
            report(137, "Saved A2")
            await self.lockedSave(fileB, label: "B (complete, no album)", album: nil, shouldStop: shouldStop)
            report(138, "Saved B")
            let lookupLockedAtStart = !UIApplication.shared.isProtectedDataAvailable
            let lookupStart = Date()
            let again = self.findAlbum()
            let lookupLockedAtEnd = !UIApplication.shared.isProtectedDataAvailable
            let lookupSeconds = String(format: "%.1f", Date().timeIntervalSince(lookupStart))
            self.log?.note("photos: album lookup while locked: \(again.detail) · \(lookupSeconds) s · locked at start \(lookupLockedAtStart ? "yes" : "NO"), at end \(lookupLockedAtEnd ? "yes" : "NO")")
            report(140, nil)
            self.lastResult = "locked save test finished; see the log"
            return true
        }
    }

    // MARK: - Helpers

    /// Runs one step at a time, logging access before (and after, if it changed), the outcome and the duration, then
    /// waits for any prompt the step brought up to be answered before the next step can start.
    private func run(_ step: String, _ body: @escaping @MainActor () async throws -> String) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            let start = Date()
            let watcher = PromptWatcher(step: step, start: start, log: self.log)
            let before = self.access()
            let outcome: String
            var failed = false
            do { outcome = try await body() } catch { outcome = "FAILED: \(Self.describe(error))"; failed = true }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            let after = self.access()
            var line = "photos: \(step) → \(outcome) · \(seconds) s · access \(before)"
            if after != before { line += " → \(after)" }
            if failed || outcome.contains("FAILED") { self.log?.warn(line) } else { self.log?.note(line) }
            self.lastResult = "\(step): \(outcome)"
            switch await watcher.settle() {
            case .stayedActive, .leftTheApp:
                break
            case .activeAgain:
                self.log?.note("photos: active again after \"\(step)\"; access now \(self.access())")
            case .stillInactive:
                self.log?.warn("photos: still inactive 2 minutes after \"\(step)\"; access not read again")
            }
            watcher.stop()
            self.isBusy = false
        }
    }

    /// One locked save. It is skipped if the phone is no longer locked or the task was stopped or expired before it
    /// starts, so a save that ran unlocked can't be logged as a locked result.
    private func lockedSave(_ url: URL, label: String, album: PHAssetCollection?, shouldStop: ContinuedTask.ShouldStop) async {
        let lockedAtStart = !UIApplication.shared.isProtectedDataAvailable
        let stopped = shouldStop()
        guard lockedAtStart, !stopped else {
            log?.warn("photos: locked save \(label) not run: before it started, phone unlocked \(lockedAtStart ? "no" : "YES"), task stopped or expired \(stopped ? "YES" : "no")")
            return
        }
        let start = Date()
        var outcome: String
        do {
            let created = try await Self.save(url, newAlbumTitle: nil, into: album)
            outcome = "OK → \(created.asset ?? "?")\(created.albumNote)"
        } catch {
            outcome = "FAILED: \(Self.describe(error))"
        }
        let lockedAtEnd = !UIApplication.shared.isProtectedDataAvailable
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        let line = "photos: locked save \(label) \(outcome) · \(seconds) s · locked at start yes, at end \(lockedAtEnd ? "yes" : "NO") · task stopped or expired \(shouldStop() ? "YES" : "no")"
        if outcome.hasPrefix("OK") && lockedAtEnd && !outcome.contains("NOT added") { log?.note(line) } else { log?.warn(line) }
    }

    private func access() -> String {
        refresh()
        return "add-only \(addOnly), read/write \(readWrite)"
    }

    private func remember(_ id: String) {
        albumID = id
        UserDefaults.standard.set(id, forKey: Self.albumIDKey)
    }

    /// Looks the test album up both ways the product could: by the stored local identifier, then by title. Also
    /// reports whether the album accepts new photos (canPerform(.addContent)); adding to one that doesn't raises an
    /// exception, so save() checks it first.
    private func findAlbum() -> (collection: PHAssetCollection?, detail: String) {
        var parts: [String] = []
        var collection: PHAssetCollection?
        if let id = albumID {
            let byID = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            parts.append("by identifier \(byID.count)")
            collection = byID.firstObject
        } else {
            parts.append("no stored identifier")
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", Self.albumTitle)
        let byTitle = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        parts.append("by title \(byTitle.count)")
        if collection == nil { collection = byTitle.firstObject }
        if let collection {
            parts.append(collection.canPerform(.addContent) ? "accepts new photos" : "does NOT accept new photos")
        }
        return (collection, parts.joined(separator: ", "))
    }

    private final class Created: @unchecked Sendable {
        var asset: String?
        var album: String?
        /// For a save into an existing album: whether the photo was added, or why not.
        var albumNote = ""
    }

    /// One change block, saving from a file URL as the product will: the asset, and either a new album holding it or
    /// the asset added to an existing album (only if the album accepts new photos).
    private static func save(_ url: URL, newAlbumTitle: String?, into album: PHAssetCollection?) async throws -> Created {
        let created = Created()
        let accepts = album?.canPerform(.addContent) ?? false
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
            let placeholder = request.placeholderForCreatedAsset
            created.asset = placeholder?.localIdentifier
            if let title = newAlbumTitle {
                let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                if let placeholder { albumRequest.addAssets([placeholder] as NSArray) }
                created.album = albumRequest.placeholderForCreatedAssetCollection.localIdentifier
            }
            if let album, let placeholder {
                if !accepts {
                    created.albumNote = "; NOT added: the album does not accept new photos"
                } else if let change = PHAssetCollectionChangeRequest(for: album) {
                    change.addAssets([placeholder] as NSArray)
                    created.albumNote = ", added to the test album"
                } else {
                    created.albumNote = "; NOT added: no change request for the album"
                }
            }
        }
        return created
    }

    /// A small JPEG with its label and the time drawn on it, written with the given file protection class.
    private static func stageJPEG(label: String, protection: Data.WritingOptions) throws -> URL {
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        let size = CGSize(width: 1200, height: 800)
        let data = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "Shutter Bridge spike test\n\(label)\n\(stamp)" as NSString
            text.draw(in: CGRect(x: 60, y: 60, width: size.width - 120, height: size.height - 120),
                      withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white])
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photos-test", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url, options: [.atomic, protection])
        return url
    }

    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "allowed"
        case .limited: return "limited"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    static func describe(_ level: PHAccessLevel) -> String {
        level == .addOnly ? "add-only" : "read/write"
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
}

/// Notices a system prompt while a Photos step runs or in the 3 s after it: logs when the app goes inactive, and lets
/// the step wait until the app is active again, so the access can be logged after the prompt was answered. A prompt
/// keeps the app in the foreground; Home, Settings or swiping the app away move it to the background, which is logged
/// as "not a prompt". Control Centre, Notification Centre and a glance at the app switcher look like a prompt here,
/// so the runbook says to wait until the step's buttons are enabled again before leaving the app.
@MainActor
private final class PromptWatcher {
    enum Outcome { case stayedActive, activeAgain, stillInactive, leftTheApp }

    private var tokens: [NSObjectProtocol] = []
    private var inactive = false
    private var wentInactive = false
    private var leftTheApp = false

    init(step: String, start: Date, log: SpikeLog?) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.leftTheApp else { return }
                self.inactive = true
                self.wentInactive = true
                log?.note("photos: app went inactive during \"\(step)\" at +\(String(format: "%.1f", Date().timeIntervalSince(start))) s: a system prompt, or Control Centre or the app switcher")
            }
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.leftTheApp else { return }
                self.leftTheApp = true
                self.inactive = false
                log?.note("photos: app left the foreground during or just after \"\(step)\" at +\(String(format: "%.1f", Date().timeIntervalSince(start))) s (Home, Settings or swiped away): not a prompt")
            }
        })
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inactive = false }
        })
    }

    /// Waits up to 3 s for a prompt that comes up after the step finished, then, if one came up, until the app is
    /// active again (2 minutes at most).
    func settle() async -> Outcome {
        for _ in 0 ..< 12 where !inactive && !leftTheApp {
            try? await Task.sleep(for: .milliseconds(250))
        }
        var waited = 0
        while inactive && !leftTheApp && waited < 480 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        if leftTheApp { return .leftTheApp }
        if inactive { return .stillInactive }
        return wentInactive ? .activeAgain : .stayedActive
    }

    func stop() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
    }
}
