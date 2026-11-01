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
/// Each step logs both access levels before it runs and again after it if they changed. A step that shows a prompt
/// also takes as long as the prompt stays up, so the duration gives it away.
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
            let created = try await Self.save(url, newAlbumTitle: nil, into: album)
            return "album found (\(found.detail)); saved \(created.asset ?? "?") into it"
        }
    }

    /// Starts a continued task and waits for the phone to lock, then 15 s more (the keys for "complete" files are
    /// discarded about 10 s after the lock). Then it saves photo A, staged complete-until-first-unlock and added to
    /// the test album found before the lock, and photo B, staged complete. Finally it looks the album up again
    /// while the phone is still locked.
    func startLockedSave(using task: ContinuedTask) {
        guard !isBusy, !task.isRunning else { log?.warn("photos: locked save test not started: another test is running"); return }
        let before = access()
        let found = findAlbum()
        let fileA: URL, fileB: URL
        do {
            fileA = try Self.stageJPEG(label: "locked, A: complete until first unlock",
                                       protection: .completeFileProtectionUntilFirstUserAuthentication)
            fileB = try Self.stageJPEG(label: "locked, B: complete", protection: .completeFileProtection)
        } catch {
            log?.error("photos: locked save test could not stage its files: \(Self.describe(error))")
            return
        }
        log?.note("photos: locked save test ready; album before the lock: \(found.detail); \(before). Lock the phone now and leave it locked for a minute.")
        lastResult = "locked save test: waiting for the lock"
        // Progress units: up to 120 one-second waits for the lock, 15 for the key to go, then 5 for the saves. The
        // count moves every second so the system sees progress.
        task.run(title: "Saving to Photos (spike)", subtitle: "Lock the phone now", totalUnits: 140) { [weak self] report, shouldStop in
            defer {
                try? FileManager.default.removeItem(at: fileA)
                try? FileManager.default.removeItem(at: fileB)
            }
            guard let self else { return false }
            var waited = 0
            while UIApplication.shared.isProtectedDataAvailable {
                if shouldStop() || waited >= 120 {
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
                report(120 + second, second == 1 ? "Locked; saving in 15 s" : nil)
            }
            let state = UIApplication.shared.isProtectedDataAvailable
                ? "protected data AVAILABLE: the phone was unlocked again, so this run proves nothing"
                : "protected data unavailable"
            await self.lockedSave(fileA, label: "A (complete until first unlock)", album: found.collection, state: state)
            report(137, "Saved A")
            await self.lockedSave(fileB, label: "B (complete)", album: nil, state: state)
            report(139, "Saved B")
            let again = self.findAlbum()
            let lockedNow = UIApplication.shared.isProtectedDataAvailable ? "unlocked by now" : "still locked"
            self.log?.note("photos: album lookup while locked: \(again.detail) (\(lockedNow))")
            report(140, nil)
            self.lastResult = "locked save test finished; see the log"
            return true
        }
    }

    // MARK: - Helpers

    /// Runs one step at a time, logging access before (and after, if it changed), the outcome and the duration.
    private func run(_ step: String, _ body: @escaping @MainActor () async throws -> String) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            let before = self.access()
            let start = Date()
            let outcome: String
            var failed = false
            do { outcome = try await body() } catch { outcome = "FAILED: \(Self.describe(error))"; failed = true }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            let after = self.access()
            var line = "photos: \(step) → \(outcome) · \(seconds) s · access \(before)"
            if after != before { line += " → \(after)" }
            if failed { self.log?.warn(line) } else { self.log?.note(line) }
            self.lastResult = "\(step): \(outcome)"
            self.isBusy = false
        }
    }

    private func lockedSave(_ url: URL, label: String, album: PHAssetCollection?, state: String) async {
        let start = Date()
        do {
            let created = try await Self.save(url, newAlbumTitle: nil, into: album)
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            let into = album == nil ? "" : ", added to the test album"
            log?.note("photos: locked save \(label) OK\(into) → \(created.asset ?? "?") · \(seconds) s · \(state)")
        } catch {
            let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
            log?.warn("photos: locked save \(label) FAILED: \(Self.describe(error)) · \(seconds) s · \(state)")
        }
    }

    private func access() -> String {
        refresh()
        return "add-only \(addOnly), read/write \(readWrite)"
    }

    private func remember(_ id: String) {
        albumID = id
        UserDefaults.standard.set(id, forKey: Self.albumIDKey)
    }

    /// Looks the test album up both ways the product could: by the stored local identifier, then by title.
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
        return (collection, parts.joined(separator: ", "))
    }

    private final class Created: @unchecked Sendable {
        var asset: String?
        var album: String?
    }

    /// One change block, saving from a file URL as the product will: the asset, and either a new album holding it or
    /// the asset added to an existing album.
    private static func save(_ url: URL, newAlbumTitle: String?, into album: PHAssetCollection?) async throws -> Created {
        let created = Created()
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
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
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
                      withAttributes: [.font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.white])
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
