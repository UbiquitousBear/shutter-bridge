#if DEBUG
import Catalogue
import Foundation
import PTPKit

/// The seeded app the UI tests drive (I18; decision D14 (c)): with `launchArgument` on its command line, a Debug build
/// composes the app over an `InMemoryCatalogue` seeded here instead of the SwiftData store (`LiveLaunch`), so History,
/// Settings and the Staging tab's cull screen can be tested in the Simulator with no camera, and nothing the person has
/// is read or written. No `PTPSimulator`: nothing here talks to a camera. Debug builds only (`#if DEBUG`), so a Release
/// build, and so every TestFlight build, has none of it.
///
/// What is seeded, all under one camera ("ILCE-7CM2", a made-up key):
///
/// - three job records for History: an import to Photos that finished, a stage job that finished, and an import that
///   stopped with two failed files (so its row offers *Re-run Failed Files*, which says to connect the camera);
/// - four staged JPEGs of one capture day, written under `documents` (`Staging/ILCE-7CM2/2026-11-08/`) from the images
///   the caller makes, each with a staged row whose size is the file's, so the cull screen shows them all;
/// - marks: the first kept, the second rejected, the last two unmarked, so the day reads "4 staged, 1 kept, 1 rejected"
///   and the loupe opens at the third ("3 of 4").
///
/// The folders are under the temporary directory and emptied each time the fixture is seeded, so every launch starts
/// from the same state. Plain Foundation, tested on Linux (`UITestFixtureTests`); the app's half (the generated images
/// and the composition) is `UITestFixture+Live.swift`.
public enum UITestFixture {
    /// The launch argument that asks for the fixture.
    public static let launchArgument = "-UITestFixture"

    /// Whether `arguments` (the process's, by default) ask for the fixture.
    public static func isRequested(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(launchArgument)
    }

    /// The fixture's folder, emptied each time it is seeded.
    public static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UITestFixture", isDirectory: true)
    }

    /// The Documents folder the fixture's app reads Staging from (On My iPhone's staging root).
    public static var documents: URL { folder.appendingPathComponent("Documents", isDirectory: true) }

    /// The engine's work folder in the fixture's app.
    public static var workFolder: URL { folder.appendingPathComponent("Work", isDirectory: true) }

    /// The one camera, by its display name (D11): its row's friendly name and its Staging folder.
    public static let cameraName = "ILCE-7CM2"
    public static let cameraKey = CameraKey(rawValue: "ui-test-camera")

    /// The staged files, in shooting order, and the day they were taken (the camera's wall clock).
    public static let stagedNames = ["DSC00001.JPG", "DSC00002.JPG", "DSC00003.JPG", "DSC00004.JPG"]
    static let stagedDay = "20261108"
    static let cardFolder = "100MSDCF"

    /// The files the stopped job failed on: not on the phone, so *Re-run Failed Files* offers both.
    static let failedNames = ["DSC00101.ARW", "DSC00102.ARW"]

    /// The job records' identifiers, newest first as History lists them.
    public static let stoppedJob = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    public static let stageJob = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    public static let finishedJob = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    /// A fresh catalogue holding the fixture, with the staged files written under `documents` (emptied first).
    ///
    /// - Parameters:
    ///   - now: When History's jobs are dated from: the stopped job an hour before, the finished import three hours
    ///     before, and the stage job a day before.
    ///   - image: The bytes of the staged file at each index of `stagedNames`: a JPEG in the app, anything in tests.
    public static func makeCatalogue(documents: URL, now: Date,
                                     image: (Int) -> Data) async throws -> InMemoryCatalogue {
        let catalogue = InMemoryCatalogue()
        try await seed(catalogue, documents: documents, now: now, image: image)
        return catalogue
    }

    /// Seeds `catalogue` with the fixture (see the type's comment) and writes the staged files under `documents`, which
    /// is emptied first.
    public static func seed(_ catalogue: any CatalogueStore, documents: URL, now: Date,
                            image: (Int) -> Data) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: documents)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)

        try await catalogue.upsertCamera(CameraRecord(key: cameraKey, model: cameraName, friendlyName: cameraName,
                                                      lastSeen: now.addingTimeInterval(-3_600)))

        var staged: [ObjectIdentity] = []
        for (index, name) in stagedNames.enumerated() {
            let data = image(index)
            let location = StagedLocation(root: .onThisIPhone, relativePath: stagedPath(name),
                                          stagedAt: now.addingTimeInterval(-86_400))
            guard let url = location.fileURL(in: documents) else { throw FixtureFailure.unresolvablePath }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let identity = ObjectIdentity(camera: cameraKey, folder: cardFolder, filename: name,
                                          captureDate: captureDate(second: index), size: UInt64(data.count))
            try await catalogue.markStaged(identity, format: .jpeg, at: location)
            staged.append(identity)
        }
        try await catalogue.setMark(.keep, rating: 0, for: [staged[0].contentKey], at: now)
        try await catalogue.setMark(.reject, rating: 0, for: [staged[1].contentKey], at: now)

        for job in jobs(now: now) {
            try await catalogue.recordJob(job)
        }
    }

    /// The three job records History lists (see the type's comment).
    static func jobs(now: Date) -> [JobRecord] {
        let failed = failedNames.enumerated().map { index, name in
            ObjectIdentity.ContentKey(filename: name, captureDate: captureDate(second: 30 + index),
                                      size: 25_000_000 + UInt64(index))
        }
        let stopped = JobRecord(
            id: stoppedJob, camera: cameraKey, purpose: .import, destination: .photos, carrier: .usb,
            selection: .allNew, startedAt: now.addingTimeInterval(-3_600), finishedAt: now.addingTimeInterval(-3_000),
            outcome: .stopped(reason: "disconnected"), filesTotal: 12, filesImported: 10, filesFailed: 2,
            bytesTotal: 300_000_000, bytesDone: 250_000_000, failedFiles: failed)
        let finished = JobRecord(
            id: finishedJob, camera: cameraKey, purpose: .import, destination: .photos, carrier: .usb,
            albumIdentifier: "ui-test-album", selection: .allNew, startedAt: now.addingTimeInterval(-10_800),
            finishedAt: now.addingTimeInterval(-9_000), outcome: .completed, filesTotal: 50, filesImported: 48,
            filesSkipped: 2, bytesTotal: 1_240_000_000, bytesDone: 1_240_000_000)
        let stage = JobRecord(
            id: stageJob, camera: cameraKey, purpose: .stage, destination: .staging, carrier: .usb,
            selection: .allNew, startedAt: now.addingTimeInterval(-86_400), finishedAt: now.addingTimeInterval(-86_340),
            outcome: .completed, filesTotal: 4, filesStaged: 4, bytesTotal: 2_000_000, bytesDone: 2_000_000)
        return [stopped, finished, stage]
    }

    /// "Staging/ILCE-7CM2/2026-11-08/<name>", as `StagingFolderDestination` names a staged copy.
    static func stagedPath(_ name: String) -> String {
        let day = String(stagedDay.prefix(4)) + "-" + String(stagedDay.dropFirst(4).prefix(2)) + "-"
            + String(stagedDay.suffix(2))
        return [StagedLocation.stagingFolderName, cameraName, day, name].joined(separator: "/")
    }

    /// 09:30 on the staged day, plus `second` seconds (under a minute).
    static func captureDate(second: Int) -> CaptureDate {
        let clamped = min(max(second, 0), 59)
        let seconds = clamped < 10 ? "0\(clamped)" : "\(clamped)"
        return CaptureDate(rawValue: stagedDay + "T0930" + seconds)!
    }

    enum FixtureFailure: Error {
        case unresolvablePath
    }
}
#endif
