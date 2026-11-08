import CameraTransport
import Catalogue
import Foundation
@testable import ImportEngine
import PhotosBridge
import Testing

/// The per-file snapshot the Import screen's rows are drawn from (backlog section 6, *Import*).
@Suite("Per-file status for the Import screen")
struct FileStatusTests {
    @Test func noJobNoFiles() async {
        let h = Harness()
        #expect(await h.engine.currentFiles.isEmpty)
        #expect(await h.engine.currentSnapshot == ImportSnapshot(progress: h.engine.currentProgress, files: []))
        await h.cleanup()
    }

    @Test func filesShowTheirStateInQueueOrder() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"], sizes: [3000, 2000])
        let video = h.item("C0001.MP4", size: 9000)
        let undated = h.item("X.JPG", size: 500, date: nil)
        let link = h.link(card + [video, undated])
        await link.script("A.JPG", .hold)
        await h.photos.fail(attempt: 2, with: .rejected(detail: "test"))
        try await h.start(.items([card[0], card[1], video, undated]), from: link)

        let a = await link.nextHeldCall("A.JPG")
        a.progress(1200)
        let during = await h.engine.currentFiles
        #expect(during.map(\.item.name) == ["A.JPG", "B.JPG", "C0001.MP4", "X.JPG"])
        #expect(during[0].id == .file(h.identity(of: card[0])))
        #expect(during[0].phase == .downloading)
        #expect(during[0].bytesDone == 1200)
        #expect(during[0].attempts == 1)
        #expect(during[0].fractionCompleted == 0.4)
        #expect(during[1].phase == .queued)
        #expect(during[1].bytesDone == 0)
        #expect(during[2].phase == .skipped(.notAStill))
        #expect(during[3].id == .undated(0))
        #expect(during[3].phase == .skipped(.noCaptureDate))

        a.release()
        #expect(await h.waitFinished() == .completed)
        let snapshot = await h.engine.currentSnapshot
        #expect(snapshot.progress == (await h.engine.currentProgress))
        let after = snapshot.files
        #expect(after.map(\.item.name) == ["A.JPG", "B.JPG", "C0001.MP4", "X.JPG"])
        #expect(after[0].phase == .imported(.photosAsset(localIdentifier: "asset-1")))
        #expect(after[1].phase == .failed(.destination(.rejected(detail: "test"))))
        #expect(after.allSatisfy { $0.phase.isResolved && $0.fractionCompleted == 1 })
        #expect(after.map(\.bytesDone) == after.map(\.item.size))
        // The rows agree with the totals.
        #expect(snapshot.progress.filesDone == after.count)
        #expect(snapshot.progress.filesSkipped == after.filter { if case .skipped = $0.phase { true } else { false } }.count)
        #expect(snapshot.progress.filesFailed == 1)
        await h.cleanup()
    }

    @Test func filesGoingToFilesSayWhereTheyWent() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        try await h.start(.items(card), from: link, to: h.filesRoute)
        #expect(await h.waitFinished() == .completed)
        let files = await h.engine.currentFiles
        guard case let .imported(.file(relativePath)?) = files.first?.phase else {
            Issue.record("expected a Files location, got \(String(describing: files.first?.phase))")
            await h.cleanup()
            return
        }
        #expect(relativePath.hasSuffix("A.JPG"))
        await h.cleanup()
    }

    @Test func appendedFilesComeLast() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG", "C.JPG"])
        let link = h.link(card)
        await link.script("C.JPG", .hold)
        try await h.start(.items([card[2]]), from: link)
        let c = await link.nextHeldCall("C.JPG")
        // A and B are added while C is copied.
        #expect(try await h.engine.append([card[0]]) == 1)
        #expect(try await h.engine.append([card[1]]) == 1)
        let during = await h.engine.currentFiles
        #expect(during.map(\.item.name) == ["C.JPG", "A.JPG", "B.JPG"])
        #expect(during.map(\.phase) == [.downloading, .queued, .queued])
        c.release()
        #expect(await h.waitFinished() == .completed)
        #expect(await h.engine.currentFiles.map(\.item.name) == ["C.JPG", "A.JPG", "B.JPG"])
        await h.cleanup()
    }

    @Test func aFileBeingCommittedShowsItsFullSize() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"], sizes: [4000])
        let link = h.link(card)
        let holding = HoldingDestination()
        try await h.start(.items(card), from: link, to: h.photosRoute(to: holding))
        await holding.waitArrived()
        let files = await h.engine.currentFiles
        #expect(files.first?.phase == .committing)
        #expect(files.first?.bytesDone == 4000)
        #expect(files.first?.fractionCompleted == 1)
        await holding.release()
        #expect(await h.waitFinished() == .completed)
        await h.cleanup()
    }

    /// Cancel while A is being saved: B, never copied, reads `.notImported` at once; A's commit finishes on the ended
    /// job, so its row reads imported and the counts include it.
    @Test func aCommitThatFinishesAfterACancelIsCounted() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG", "B.JPG"])
        let link = h.link(card)
        let holding = HoldingDestination()
        try await h.start(.items(card), from: link, to: h.photosRoute(to: holding))
        await holding.waitArrived()
        let mark = h.trace.count
        await h.engine.cancel()
        let ended = await h.engine.currentFiles
        #expect(ended.map(\.phase) == [.committing, .notImported])
        #expect(ended[1].fractionCompleted == 0)
        #expect(ended[1].phase.isResolved)

        await holding.release()
        _ = await h.trace.wait(from: mark) { $0 == .imported("A.JPG", .photos) }
        let after = await h.engine.currentSnapshot
        #expect(after.files.map(\.phase) == [.imported(.photosAsset(localIdentifier: "held-1")), .notImported])
        #expect(after.progress.filesDone == 1)
        #expect(after.progress.state == .finished(.cancelled))
        #expect(await holding.commits == ["A.JPG"])
        await h.cleanup()
    }

    @Test func theProgressSaysWhenAStallWaitsForThePerson() async throws {
        let h = Harness()
        let card = h.singles(["A.JPG"])
        let link = h.link(card)
        await link.setDefaultStep(.hold)
        try await h.start(.items(card), from: link)
        for n in 1 ... 3 {
            await h.trace.next(.started("A.JPG", attempt: n))
            _ = await link.nextHeldCall("A.JPG")
            await h.advance(by: .seconds(30))
            await h.trace.next(.stalled("A.JPG", count: n))
            // An automatic retry is coming: nothing for the person to do.
            #expect(await !h.engine.currentProgress.stallWaitsForPerson)
            await h.advance(by: .seconds(5))
            await h.trace.next(.resumed)
        }
        await h.trace.next(.started("A.JPG", attempt: 4))
        _ = await link.nextHeldCall("A.JPG")
        await h.advance(by: .seconds(30))
        await h.trace.next(.stalled("A.JPG", count: 4))
        let waiting = await h.engine.currentProgress
        #expect(waiting.state == .paused(.stalled))
        #expect(waiting.stallWaitsForPerson)
        #expect(await h.engine.currentFiles.first?.phase == .queued)
        #expect(await h.engine.currentFiles.first?.attempts == 4)

        try await h.engine.resume()
        #expect(await !h.engine.currentProgress.stallWaitsForPerson)
        await link.nextHeldCall("A.JPG").release()
        #expect(await h.waitFinished() == .completed)
        #expect(await !h.engine.currentProgress.stallWaitsForPerson)
        await h.cleanup()
    }
}
