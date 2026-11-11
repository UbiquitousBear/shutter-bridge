import CameraTransport
import Catalogue
import Foundation
import ImportEngine
import PhotosBridge
import Testing
@testable import AppUI

@MainActor
@Suite("App wiring and launch")
struct AppModelTests {
    func appModel(discovery: FakeDiscovery, catalogue: any CatalogueStore = InMemoryCatalogue()) -> AppModel {
        AppModel(discovery: discovery, services: services(), catalogue: catalogue,
                 engine: ImportEngine(catalogue: catalogue, stagingDirectory: temporaryStaging()),
                 settingsStore: InMemoryDestinationSettingStore(), photos: FakePhotosAccess(),
                 destinations: FakeDestinations(), cameraKey: CameraKeys.fromDescriptor)
    }

    @Test func theModelsAreWiredToEachOther() async {
        let link = FakeLink(items: [item("DSC00001.JPG")])
        let discovery = FakeDiscovery(link: link)
        let app = appModel(discovery: discovery)
        #expect(app.cameras.importModel === app.importer)
        #expect(app.importer.cameraFinder === app.cameras)
        #expect(app.importer.importChoice == .photos)
        #expect(!app.keepsScreenOn)

        await discovery.allow()
        await app.scenePhaseChanged(.active)
        #expect(app.cameras.isLooking)
        await discovery.send(.appeared(link.descriptor))
        #expect(await eventually { app.cameras.cameras == [link.descriptor] })
        // The import finds the camera by its key.
        let key = CameraKeys.key(for: link.descriptor, material: nil)
        #expect(await app.cameras.link(forCameraWith: key) === link)
        #expect(await app.cameras.link(forCameraWith: CameraKey(rawValue: "someone-else")) == nil)
    }

    @Test func browseGetsTheCatalogueAndTheImport() async {
        let link = FakeLink(items: [item("DSC00001.JPG"), item("DSC00002.JPG", at: 5)])
        await link.set(writesListedSize: true)
        let discovery = FakeDiscovery(link: link)
        let catalogue = InMemoryCatalogue()
        let app = appModel(discovery: discovery, catalogue: catalogue)
        let browse = app.browseModel(for: link.descriptor)
        let run = Task { await browse.run() }
        #expect(await eventually { browse.phase == .listed })
        #expect(await eventually {
            await catalogue.lastListing(for: CameraKeys.key(for: link.descriptor, material: nil)) != nil
        })
        browse.selectAllNew()
        await browse.importSelected()
        #expect(browse.importNotice == "Importing 2 files.")
        #expect(app.importer.hasJob)
        // Leaving Browse doesn't close the link while the job holds it.
        run.cancel()
        await run.value
        #expect(await eventually {
            await app.importer.refresh()
            return app.importer.isFinished
        })
        #expect(app.importer.countsLine == "2 files imported.")
        // Back in Browse, both carry the badge.
        let again = app.browseModel(for: link.descriptor)
        let rerun = Task { await again.run() }
        #expect(await eventually { again.phase == .listed && again.imported.count == 2 })
        rerun.cancel()
        await rerun.value
    }

    @Test func launchOpensTheCatalogueOrSaysWhyNot() async {
        struct NoStore: Error {}
        final class Attempts: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let attempts = Attempts()
        let discovery = FakeDiscovery(link: FakeLink(items: []))
        let launcher = AppLauncher(
            openCatalogue: {
                if attempts.next() == 1 { throw NoStore() }
                return InMemoryCatalogue()
            },
            build: { store in self.appModel(discovery: discovery, catalogue: store) }
        )
        guard case .opening = launcher.state else {
            Issue.record("expected opening")
            return
        }
        await launcher.launch()
        guard case .failed = launcher.state else {
            Issue.record("expected the failure state, got \(launcher.state)")
            return
        }
        #expect(launcher.model == nil)
        await launcher.launch()   // Try Again
        #expect(launcher.model != nil)
        let model = launcher.model
        await launcher.launch()   // once ready, it stays as it is
        #expect(launcher.model === model)
    }
}
