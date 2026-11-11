import CameraTransport
import Catalogue
import Foundation
import Testing
@testable import ImportEngine

/// Wraps the plain reader and runs `beforeCopy` on the staged file just before each copy, so a test can change
/// Staging in the middle of a job, as the Files app or iCloud would.
private struct TamperingReader: StagedFileReading {
    let beforeCopy: @Sendable (URL) -> Void
    private let plain = PlainStagedFileReader()

    func presence(of source: URL, expectedSize: UInt64) -> StagedPresence {
        plain.presence(of: source, expectedSize: expectedSize)
    }

    func copy(
        _ source: URL, expectedSize: UInt64, to destination: URL, progress: @escaping @Sendable (UInt64) -> Void
    ) async throws(CameraLinkFailure) {
        beforeCopy(source)
        try await plain.copy(source, expectedSize: expectedSize, to: destination, progress: progress)
    }
}

/// The engine importing from a `StagingFolderLink`, as *Import keepers* will (backlog Iteration 2, section 7.2): the
/// camera key is the one the job is started with, not the link's descriptor, and each row carries the file's original
/// identity from the card.
@Suite("StagingFolderLink: the engine importing from Staging", .timeLimit(.minutes(1)))
struct StagingFolderLinkImportTests {
    /// A link descriptor that is not the job's camera, so a row under the descriptor's key would show.
    private let descriptor = CameraDescriptor(
        id: .init(rawValue: "staging-link-descriptor"), name: "Staging", mode: .wifi(.otherNetwork))

    private struct Staged {
        let folder: String
        let name: String
        let bytes: Data
        let date: Date
        var url: URL!
    }

    private func staged(_ h: Harness) throws -> (entries: [StagedEntry], files: [Staged], folder: URL) {
        let folder = h.root.appendingPathComponent("Keepers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files = [
            Staged(folder: "DCIM/100MSDCF", name: "DSC00001.ARW", bytes: FakeCameraLink.payload(count: 4000),
                   date: Harness.t0.addingTimeInterval(1)),
            Staged(folder: "DCIM/100MSDCF", name: "DSC00001.JPG", bytes: FakeCameraLink.payload(count: 2000),
                   date: Harness.t0.addingTimeInterval(1)),
            Staged(folder: "DCIM/101MSDCF", name: "DSC00002.ARW", bytes: FakeCameraLink.payload(count: 4100),
                   date: Harness.t0.addingTimeInterval(2)),
        ]
        var entries: [StagedEntry] = []
        for i in files.indices {
            let url = folder.appendingPathComponent("keeper-\(i)")   // the staged name is not the camera's
            try files[i].bytes.write(to: url)
            files[i].url = url
            entries.append(StagedEntry(
                folder: files[i].folder, name: files[i].name, captureDate: files[i].date,
                size: UInt64(files[i].bytes.count), url: url))
        }
        return (entries, files, folder)
    }

    @Test func importsIntoTheFakeLibraryUnderTheJobsCameraKeyWithEachFilesOriginalIdentity() async throws {
        let h = Harness()
        let (entries, files, _) = try staged(h)
        let link = StagingFolderLink(descriptor: descriptor, entries: entries, reader: PlainStagedFileReader())
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)

        #expect(Set(await h.photos.committedNames) == ["DSC00001.ARW", "DSC00001.JPG", "DSC00002.ARW"])
        let sizes = await h.photos.sizes
        let rows = await h.records()
        #expect(rows.count == 3)
        for file in files {
            // The row is under the camera key the job was started with, never the link descriptor's.
            let row = try #require(rows.first { $0.identity.filename == file.name && $0.identity.folder == file.folder })
            #expect(row.identity.camera == h.camera)
            #expect(row.identity.camera.rawValue != descriptor.id.rawValue)
            #expect(row.identity.size == UInt64(file.bytes.count))
            #expect(row.identity == ObjectIdentity(
                camera: h.camera, folder: file.folder, filename: file.name,
                captureDate: row.identity.captureDate, size: UInt64(file.bytes.count)))
            #expect(row.state == .imported)
            #expect(row.format == CameraItem.format(ofFilename: file.name))
            // What reached the library is the staged file's bytes under the camera's name.
            #expect(sizes[file.name] == UInt64(file.bytes.count))
        }
        // The identity matches what the card's own listing would have given the file.
        let listed = try await link.list()
        for item in listed {
            let row = try await #require(h.record(for: item))
            #expect(row.identity == h.identity(of: item))
        }

        // Copy, never move: Staging still holds every file, unchanged.
        for file in files { #expect(try Data(contentsOf: file.url) == file.bytes) }
        // The engine's own work folder is emptied after the commits.
        #expect(h.stagedFiles == 0)
        let p = await h.engine.currentProgress
        #expect(p.filesDone == 3 && p.filesFailed == 0 && p.filesSkipped == 0)
        await h.cleanup()
    }

    @Test func aFileDeletedFromStagingMidJobIsSkippedAndTheRestAreImported() async throws {
        let h = Harness()
        let (entries, files, _) = try staged(h)
        let doomed = files[1]
        let reader = TamperingReader { url in
            if url == doomed.url { try? FileManager.default.removeItem(at: url) }
        }
        let link = StagingFolderLink(descriptor: descriptor, entries: entries, reader: reader)
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)

        #expect(Set(await h.photos.committedNames) == ["DSC00001.ARW", "DSC00002.ARW"])
        let skipped = try await #require(link.list().first { $0.name == doomed.name })
        #expect(await h.outcome(of: skipped) == .skipped(.link(.itemNotFound)))
        #expect(await h.record(for: skipped) == nil)
        let p = await h.engine.currentProgress
        #expect(p.filesSkipped == 1 && p.filesFailed == 0 && p.filesDone == 3)
        // The others are still in Staging.
        for file in files where file.name != doomed.name { #expect(try Data(contentsOf: file.url) == file.bytes) }
        await h.cleanup()
    }

    @Test func aFileWhoseSizeChangedMidJobIsSkippedAndLeftInStaging() async throws {
        let h = Harness()
        let (entries, files, _) = try staged(h)
        let changed = files[0]
        let reader = TamperingReader { url in
            if url == changed.url, let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data([1, 2, 3]))
                try? handle.close()
            }
        }
        let link = StagingFolderLink(descriptor: descriptor, entries: entries, reader: reader)
        try await h.start(.allNew, from: link)
        #expect(await h.waitFinished() == .completed)

        #expect(Set(await h.photos.committedNames) == ["DSC00001.JPG", "DSC00002.ARW"])
        let skipped = try await #require(link.list().first { $0.name == changed.name })
        #expect(await h.outcome(of: skipped) == .skipped(.link(.itemNotFound)))
        #expect(await h.record(for: skipped) == nil)
        // The engine never writes to Staging: the file is as the other process left it.
        #expect(try Data(contentsOf: changed.url).count == changed.bytes.count + 3)
        await h.cleanup()
    }
}
