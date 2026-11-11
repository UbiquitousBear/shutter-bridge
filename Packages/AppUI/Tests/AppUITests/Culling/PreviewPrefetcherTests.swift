import Foundation
import Testing
@testable import AppUI

/// `DSC00001.JPG` for index 0.
private func name(_ index: Int, _ ext: String = "JPG") -> String { String(format: "DSC%05d.", index + 1) + ext }

@MainActor
private struct Rig {
    let loader = FakeLoader()
    let clock = WiFiTestClock()
    let files: FakeAvailability
    let units: [CullUnit]
    let prefetcher: PreviewPrefetcher<String>

    init(_ count: Int, ext: String = "JPG", evicted: Bool = false, policy: PrefetchPolicy = PrefetchPolicy(),
         autoRelease: Bool = false) {
        let units = cullUnits(count, ext: ext)
        self.units = units
        files = FakeAvailability(evicted: evicted ? Set(units.compactMap { $0.previewSource.file?.identity.filename }) : [])
        loader.autoRelease = autoRelease
        prefetcher = PreviewPrefetcher(loader: loader, files: files, clock: clock, policy: policy, maxPixelSize: 2_800)
    }

    func has(_ index: Int) -> Bool { prefetcher.preview(for: units[index]) != nil }
    /// Waits until the settle timer is sleeping, then lets it run out.
    func settle() async {
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: PrefetchPolicy().settleDelay)
    }
}

@Suite("Preview window")
struct PrefetchPolicyTests {
    @Test func decodesTheNextThreeAndThePreviousOneClippedToTheList() {
        let policy = PrefetchPolicy()
        #expect(policy.decodeIndices(focus: 3, count: 10) == [3, 4, 5, 6, 2])
        #expect(policy.decodeIndices(focus: 0, count: 10) == [0, 1, 2, 3])
        #expect(policy.decodeIndices(focus: 9, count: 10) == [9, 8])
        #expect(policy.decodeIndices(focus: 0, count: 2) == [0, 1])
        #expect(policy.decodeIndices(focus: 0, count: 0).isEmpty)
        #expect(policy.decodeIndices(focus: 5, count: 3).isEmpty)
    }

    @Test func downloadsTenAheadStartingWithTheDecodedOnes() {
        let policy = PrefetchPolicy()
        #expect(policy.downloadIndices(focus: 3, count: 30) == [3, 4, 5, 6, 2, 7, 8, 9, 10, 11, 12, 13])
        #expect(policy.downloadIndices(focus: 0, count: 5) == [0, 1, 2, 3, 4])
        #expect(policy.downloadIndices(focus: 4, count: 5) == [4, 3])
    }

    @Test func theDefaultsAreTheBacklogsNumbers() {
        let policy = PrefetchPolicy()
        #expect(policy.decodeAhead == 3 && policy.decodeBehind == 1 && policy.downloadAhead == 10)
        #expect(policy.maxDecoded == 5)
        #expect(policy.decodedByteBudget <= 150_000_000)
    }
}

@MainActor
@Suite("Preview prefetcher")
struct PreviewPrefetcherTests {
    @Test func theCurrentUnitLoadsAtOnceAndTheOnesAroundItOnlyAfterTheSettleDelay() async {
        let r = Rig(14)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.loader.started == [name(0)] })
        #expect(await waitUntil { r.clock.sleeperCount == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.loader.started == [name(0)])           // nothing ahead before the delay
        r.loader.release(name(0))
        #expect(await waitUntilOnMain { r.has(0) })

        r.clock.advance(by: PrefetchPolicy().settleDelay)
        // Two decodes at a time: the next two, then the third once one finishes. (Loads start on their own tasks, so
        // the order they are recorded in isn't the order they were asked for.)
        #expect(await waitUntilOnMain { Set(r.loader.started) == [name(0), name(1), name(2)] })
        r.loader.release(name(1))
        #expect(await waitUntilOnMain { Set(r.loader.started) == [name(0), name(1), name(2), name(3)] })
        #expect(r.has(1) && !r.has(2))
    }

    @Test func movingOnDropsWhatLeftTheWindowAtOnceAndCancelsItsWork() async {
        let r = Rig(14)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.loader.started == [name(0)] })
        r.loader.release(name(0))
        #expect(await waitUntilOnMain { r.has(0) })
        await r.settle()
        #expect(await waitUntilOnMain { r.loader.started.count == 3 })     // 1 and 2 are in flight

        r.prefetcher.focus(on: 8)
        #expect(r.prefetcher.heldCount == 0)                                 // 0 left the window
        #expect(await waitUntil { Set(r.loader.cancelled) == [name(1), name(2)] })
        #expect(await waitUntilOnMain { r.loader.started.last == name(8) })
        r.loader.release(name(8))
        #expect(await waitUntilOnMain { r.has(8) })
        #expect(r.prefetcher.heldCount == 1)
    }

    @Test func aFastSwipeLoadsOnlyTheUnitItStopsOn() async {
        let r = Rig(14)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.loader.started == [name(0)] })
        for i in 1 ... 3 {
            r.prefetcher.focus(on: i)
            #expect(await waitUntilOnMain { r.loader.started.last == name(i) })
        }
        #expect(await waitUntil { r.clock.sleeperCount == 1 })             // one timer, restarted each swipe
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.loader.started == [name(0), name(1), name(2), name(3)])

        r.loader.autoRelease = true
        for i in 0 ... 3 { r.loader.release(name(i)) }
        await r.settle()
        #expect(await waitUntilOnMain {
            Set(r.prefetcher.previews.keys) == Set(r.units[2 ... 6].map(\.id))      // 3, the next three and one back
        })
    }

    @Test func atMostFiveImagesAreHeldHoweverFarAheadThePolicyReaches() async {
        var policy = PrefetchPolicy()
        policy.decodeAhead = 8
        policy.maxConcurrentDecodes = 8
        let r = Rig(20, policy: policy, autoRelease: true)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.has(0) })
        await r.settle()
        #expect(await waitUntilOnMain { r.prefetcher.heldCount == 5 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.prefetcher.heldCount == 5 && r.loader.started.count == 5)

        for i in 1 ... 8 {
            r.prefetcher.focus(on: i)
            #expect(await waitUntilOnMain { r.has(i) })
            #expect(r.prefetcher.heldCount <= 5)
            await r.settle()
            #expect(await waitUntilOnMain { r.prefetcher.heldCount == 5 })
        }
        #expect(r.prefetcher.peakHeldCount == 5)
    }

    @Test func theByteBudgetReleasesTheFarthestImagesAndDoesNotFetchThemAgainUntilTheFocusMoves() async {
        var policy = PrefetchPolicy()
        policy.decodedByteBudget = 100
        let r = Rig(10, policy: policy, autoRelease: true)
        r.loader.byteCost = 40
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.has(0) })
        await r.settle()
        #expect(await waitUntilOnMain { r.loader.started.count == 4 && r.prefetcher.heldCount == 2 })
        #expect(r.has(0) && r.has(1) && !r.has(2) && !r.has(3))             // the farthest went
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.loader.started.count == 4)                                // no fetch-and-evict loop
        #expect(r.prefetcher.heldBytes == 80 && r.prefetcher.peakHeldBytes <= 100)

        r.prefetcher.focus(on: 2)
        #expect(await waitUntilOnMain { r.has(2) })
        #expect(r.prefetcher.heldBytes <= 100)
    }

    @Test func theCurrentImageIsKeptEvenWhenItAloneIsOverTheBudget() async {
        var policy = PrefetchPolicy()
        policy.decodedByteBudget = 10
        let r = Rig(3, policy: policy, autoRelease: true)
        r.loader.byteCost = 40
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.has(0) })
        await r.settle()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.has(0) && r.prefetcher.heldCount == 1)
    }

    @Test func aRawShowsItsStandInThenTheRender() async {
        let r = Rig(1, ext: "ARW")
        r.loader.loadMode = .standInThenFinal
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.prefetcher.preview(for: r.units[0])?.quality == .standIn })
        r.loader.release(name(0, "ARW"))
        #expect(await waitUntilOnMain { r.prefetcher.preview(for: r.units[0])?.quality == .final })
        #expect(r.prefetcher.heldCount == 1)
    }

    @Test func aFailedLoadIsNotRetriedUntilAskedTo() async {
        let r = Rig(3, autoRelease: true)
        r.loader.fail(name(0))
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.prefetcher.hasFailed(r.units[0]) })
        await r.settle()
        #expect(await waitUntilOnMain { r.has(1) && r.has(2) })              // the others carry on
        #expect(r.loader.started.filter { $0 == name(0) }.count == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.loader.started.filter { $0 == name(0) }.count == 1)

        r.loader.stopFailing(name(0))
        r.prefetcher.retry(r.units[0])
        #expect(await waitUntilOnMain { r.has(0) })
        #expect(!r.prefetcher.hasFailed(r.units[0]))
    }

    @Test func aLoadThatIgnoresCancellationCantPutAnImageBackAfterItsUnitLeft() async {
        let r = Rig(14)
        r.loader.ignoresCancellation = true
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.loader.started == [name(0)] })
        r.prefetcher.focus(on: 9)
        #expect(await waitUntil { r.loader.cancelled.contains(name(0)) })
        #expect(await waitUntil { r.loader.delivered.contains(name(0)) })    // it delivered anyway…
        #expect(!r.has(0))                                                    // …and nobody took it
    }

    @Test func aUnitWithNothingToShowStartsNoLoad() async {
        let r = Rig(2, ext: "MP4", autoRelease: true)
        r.prefetcher.show(r.units, focusing: 0)
        await r.settle()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.loader.started.isEmpty && r.prefetcher.heldCount == 0 && r.prefetcher.failed.isEmpty)
    }

    @Test func stoppingReleasesEverythingAndCancelsTheWork() async {
        let r = Rig(5)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.loader.started == [name(0)] })
        r.loader.release(name(0))
        #expect(await waitUntilOnMain { r.has(0) })
        await r.settle()
        #expect(await waitUntilOnMain { r.loader.started.count == 3 })
        r.prefetcher.stop()
        #expect(r.prefetcher.heldCount == 0)
        #expect(await waitUntil { Set(r.loader.cancelled) == [name(1), name(2)] })
        #expect(await waitUntil { r.clock.sleeperCount == 0 })
    }
}

@MainActor
@Suite("Preview prefetcher: evicted iCloud files")
struct PreviewDownloadTests {
    @Test func anEvictedCurrentFileIsDownloadedFirstWithProgressThenDecoded() async {
        let r = Rig(14, evicted: true, autoRelease: true)
        r.files.reportOnStart(0.5)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntil { r.files.started == [name(0)] })
        #expect(await waitUntilOnMain { r.prefetcher.downloadProgress(for: r.units[0])?.fraction == 0.5 })
        #expect(r.loader.started.isEmpty)                                    // nothing to decode yet

        r.files.finish(name(0))
        #expect(await waitUntilOnMain { r.has(0) })
        #expect(r.prefetcher.downloadProgress(for: r.units[0]) == nil)
        #expect(r.loader.started == [name(0)])
    }

    @Test func downloadsRunTwoAtATimeTenUnitsAheadAndDecodeOnlyTheWindow() async {
        let r = Rig(14, evicted: true, autoRelease: true)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntil { r.files.started == [name(0)] })
        r.files.finish(name(0))
        #expect(await waitUntilOnMain { r.has(0) })
        await r.settle()
        #expect(await waitUntil { Set(r.files.started) == [name(0), name(1), name(2)] })   // two in flight
        #expect(r.prefetcher.downloadProgress(for: r.units[1]) != nil)
        #expect(!r.has(1))                                                    // decoded only once downloaded

        r.files.autoFinish = true
        r.files.finish(name(1))
        r.files.finish(name(2))
        #expect(await waitUntil { r.files.started.count == 11 })
        #expect(await waitUntilOnMain { r.has(1) && r.has(2) && r.has(3) })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(Set(r.files.started) == Set((0 ... 10).map { name($0) }))   // index 11 and beyond: too far
        #expect(Set(r.loader.started) == Set((0 ... 3).map { name($0) }))   // downloaded further ahead, not decoded
        #expect(await waitUntilOnMain { r.prefetcher.downloads.isEmpty })
    }

    @Test func aDownloadThatFailsMarksTheUnitAndIsNotRetriedUntilAskedTo() async {
        let r = Rig(3, evicted: true, autoRelease: true)
        r.files.autoFinish = true
        r.files.fail(name(0))
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntilOnMain { r.prefetcher.hasFailed(r.units[0]) })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(r.files.started == [name(0)] && r.loader.started.isEmpty)
        #expect(r.prefetcher.downloads.isEmpty)

        r.prefetcher.retry(r.units[0])
        #expect(await waitUntil { r.files.started.count == 2 })
    }

    @Test func movingAwayCancelsADownloadNobodyWaitsForAnymore() async {
        let r = Rig(30, evicted: true)
        r.prefetcher.show(r.units, focusing: 0)
        #expect(await waitUntil { r.files.started == [name(0)] })
        r.prefetcher.focus(on: 20)
        #expect(await waitUntilOnMain { r.prefetcher.downloadProgress(for: r.units[0]) == nil })
        #expect(await waitUntil { r.files.started.last == name(20) })
        #expect(r.prefetcher.downloads.keys.contains(r.units[20].id))
    }
}
