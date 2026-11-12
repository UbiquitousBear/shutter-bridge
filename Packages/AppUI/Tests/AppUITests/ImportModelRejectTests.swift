import Catalogue
import Foundation
import ImportEngine
import Testing
@testable import AppUI

// The Import screen's rejects line (D3, I21): how many rejected files the job left out, once there are counts to show.
extension ImportModelTests {
    /// A *Select All New* pick added to the running job leaves out a rejected file; the outcome says so once the job
    /// ends, and not while nothing is done yet.
    @Test func theOutcomeSaysHowManyRejectedFilesTheJobLeftOut() async throws {
        let catalogue = InMemoryCatalogue()
        let h = await harness(hangs: true, catalogue: catalogue)
        let rejected = try #require(card[2].identity(camera: h.camera.key, timeZone: .autoupdatingCurrent))
        try await catalogue.setMark(.reject, rating: 0, for: [rejected.contentKey],
                                    at: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(await h.importAll([card[0]]) == .started(1))
        #expect(await eventually { await h.link.bytesStarted == 1 })
        #expect(await h.model.importItems([card[2]], from: h.camera, link: h.link, as: .photos, newOnly: true)
            == .nothingNew(staging: false))
        await h.model.refresh()
        #expect(h.model.progress.rejectsLeftOut == 1)
        #expect(h.model.rejectsLeftOutLine == nil)
        await h.model.cancel()
        #expect(await h.finished())
        #expect(h.model.rejectsLeftOutLine == "1 rejected file left out. Pick it in Browse to import it anyway.")
    }

    /// A job that left no reject out has no rejects line.
    @Test func noRejectsLineWhenNoneWereLeftOut() async {
        let h = await harness()
        #expect(await h.importAll(card) == .started(3))
        #expect(await h.finished())
        #expect(h.model.countsLine == "3 files imported.")
        #expect(h.model.rejectsLeftOutLine == nil)
    }
}
