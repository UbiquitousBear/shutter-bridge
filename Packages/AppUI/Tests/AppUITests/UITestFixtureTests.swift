#if DEBUG
import Catalogue
import Foundation
import PhotosBridge
import Testing
@testable import AppUI

/// The UI tests' seeded app (I18): the fixture holds what the UI tests in App/ShutterBridgeUITests look for, and the
/// Staging and History models show it as those tests expect. The app's half (the generated JPEGs and the composition)
/// is compiled by CI's Xcode job only.
@MainActor
@Suite("UI test fixture: the seeded catalogue and Staging folder")
struct UITestFixtureTests {
    private let documents = FileManager.default.temporaryDirectory
        .appendingPathComponent("UITestFixtureTests-\(UUID().uuidString)", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 1_794_400_000)

    /// Different sizes per file, so a staged row whose size wasn't taken from its own file would read as gone.
    private nonisolated static func bytes(_ index: Int) -> Data { Data(repeating: UInt8(index), count: 100 + index * 7) }

    @Test func onlyTheLaunchArgumentAsksForTheFixture() {
        #expect(UITestFixture.isRequested(in: ["ShutterBridge", UITestFixture.launchArgument]))
        #expect(!UITestFixture.isRequested(in: ["ShutterBridge"]))
        #expect(!UITestFixture.isRequested(in: ["ShutterBridge", "-UITestFixtureX", "UITestFixture"]))
    }

    @Test func seedsThreeJobsForHistoryNewestFirst() async throws {
        let catalogue = try await UITestFixture.makeCatalogue(documents: documents, now: now, image: Self.bytes)
        defer { try? FileManager.default.removeItem(at: documents) }
        let jobs = await catalogue.jobs(camera: nil)
        #expect(jobs.map(\.id) == [UITestFixture.stoppedJob, UITestFixture.finishedJob, UITestFixture.stageJob])
        #expect(jobs.map(\.outcome) == [.stopped(reason: "disconnected"), .completed, .completed])
        #expect(jobs[0].failedFiles.count == 2)
        #expect(jobs[2].purpose == .stage && jobs[2].destination == .staging)
        #expect(await catalogue.camera(UITestFixture.cameraKey)?.friendlyName == UITestFixture.cameraName)
    }

    @Test func writesEachStagedFileWithTheSizeItsRowRecords() async throws {
        let catalogue = try await UITestFixture.makeCatalogue(documents: documents, now: now, image: Self.bytes)
        defer { try? FileManager.default.removeItem(at: documents) }
        let staged = await catalogue.stagedRecords(camera: nil)
        #expect(staged.map(\.identity.filename) == UITestFixture.stagedNames)
        for (index, record) in staged.enumerated() {
            let location = try #require(record.staged)
            #expect(location.root == .onThisIPhone)
            #expect(location.relativePath == "Staging/ILCE-7CM2/2026-11-08/\(UITestFixture.stagedNames[index])")
            let url = try #require(location.fileURL(in: documents))
            #expect(try Data(contentsOf: url) == Self.bytes(index))
            #expect(record.identity.size == UInt64(Self.bytes(index).count))
        }
    }

    @Test func seedingAgainStartsFromTheSameState() async throws {
        defer { try? FileManager.default.removeItem(at: documents) }
        _ = try await UITestFixture.makeCatalogue(documents: documents, now: now, image: Self.bytes)
        let leftover = documents.appendingPathComponent("Staging/ILCE-7CM2/2026-11-08/LEFTOVER.JPG")
        try Data([1]).write(to: leftover)
        let catalogue = try await UITestFixture.makeCatalogue(documents: documents, now: now, image: Self.bytes)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(await catalogue.stagedRecords(camera: nil).count == UITestFixture.stagedNames.count)
    }

    @Test func theCullScreenShowsOneDayOfFourWithOneKeptOneRejectedAndOpensAtTheThird() async throws {
        let catalogue = try await UITestFixture.makeCatalogue(documents: documents, now: now, image: Self.bytes)
        defer { try? FileManager.default.removeItem(at: documents) }
        let loader = FakeLoader()
        loader.autoRelease = true
        let model = CullModel(catalogue: catalogue, onThisIPhone: documents,
                              locator: FakeStagingLocator(.unavailable(.iCloudDriveOff)), loader: loader)
        await model.load()
        #expect(model.sections.map(\.name) == [UITestFixture.cameraName])
        #expect(model.unavailable.total == 0)
        let row = try #require(model.rows.first)
        #expect(model.rows.count == 1)
        // What the UI test finds the day's row by.
        #expect(CullWording.countsLine(model.counts(of: row)) == "4 staged, 1 kept, 1 rejected")
        model.openLoupe(row.id)
        #expect(model.loupe?.position == "3 of 4")
        await model.closeLoupe()
    }

    @Test func historyListsTheThreeJobsAndOffersReRunOnTheStoppedOne() async throws {
        let now = self.now
        let catalogue = try await UITestFixture.makeCatalogue(documents: documents, now: now, image: Self.bytes)
        defer { try? FileManager.default.removeItem(at: documents) }
        let model = HistoryModel(catalogue: catalogue, importer: nil, finder: nil, leases: LinkLeases(),
                                 onThisIPhone: documents, locator: FakeStagingLocator(.unavailable(.iCloudDriveOff)),
                                 now: { now })
        await model.load()
        let rows = model.sections.flatMap(\.rows)
        #expect(rows.map(\.title) == ["Import from ILCE-7CM2", "Import from ILCE-7CM2", "Stage from ILCE-7CM2"])
        #expect(rows.map(\.counts) == ["10 imported, 2 failed", "48 imported, 2 skipped", "4 staged"])
        #expect(rows[0].action == .rerun(failedLeft: 2))
        #expect(rows[0].actionLine == "2 failed files not imported yet")
        #expect(rows[1].action == nil && rows[1].outcome == "Finished")
        #expect(rows[2].place == "Staging" && rows[2].opensStagingFolder)
    }
}
#endif
