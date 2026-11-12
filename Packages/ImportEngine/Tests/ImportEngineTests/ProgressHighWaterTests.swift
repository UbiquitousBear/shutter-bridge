import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// Progress never goes backwards when a file that reached its commit is put back in the queue (found by the fault
/// matrix's keeper cases; I15): its bytes were all shown while it committed, and it holds that place, as a restarted
/// download does.
@Suite("Progress across a commit that didn't happen", .timeLimit(.minutes(1)))
struct ProgressHighWaterTests {
    /// Photos access read after a refused save, held until the test lets it answer, so the file is seen committing.
    private actor GatedAccess {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var reads = 0

        func read() async -> PhotosAuthorisation {
            reads += 1
            if !isOpen { await withCheckedContinuation { waiting.append($0) } }
            return .denied
        }

        func open() {
            isOpen = true
            for w in waiting { w.resume() }
            waiting = []
        }
    }

    /// A keepers job whose save Photos refuses: the file was shown whole while committing (the link reported no
    /// progress), and the stop for Photos access puts it back without taking its bytes off the bar.
    @Test func aRefusedKeepersSaveKeepsItsBytesShown() async throws {
        let h = Harness()
        let a = h.item("A.JPG", size: 2000)
        let gate = GatedAccess()
        await h.photos.deny(from: 1)
        try await h.start(.items([a]), from: h.link([a]), to: .keepers(h.photos, authorisation: { await gate.read() }))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await gate.reads == 0 {
            try #require(ContinuousClock.now < deadline, "the refused save never read Photos access")
            await Task.yield()
        }
        let committing = await h.engine.currentProgress
        #expect(committing.bytesDone == 2000)
        await gate.open()
        #expect(await h.waitFinished() == .photosAccessNeeded(.denied))
        let after = await h.engine.currentProgress
        #expect(after.bytesDone >= committing.bytesDone)
        #expect(after.filesFailed == 0)
        await h.cleanup()
    }
}
