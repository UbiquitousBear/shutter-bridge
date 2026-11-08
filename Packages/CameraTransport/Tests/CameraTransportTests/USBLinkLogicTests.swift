import Foundation
import Testing
@testable import CameraTransport

// The pure parts of USBLink (backlog section 2), tested on Linux. The ImageCaptureCore adapter itself is compiled
// by CI's Xcode 27 build and checked on the bench iPhone in week 1.

@Suite("USB mode from the transport type")
struct USBModeClassifierTests {
    @Test func transportTypeDecidesTheProvisionalMode() {
        #expect(USBModeClassifier.provisionalMode(transportType: "ICTransportTypeMassStorage") == .massStorage)
        #expect(USBModeClassifier.provisionalMode(transportType: "ICTransportTypeUSB") == .mtp)
        #expect(USBModeClassifier.provisionalMode(transportType: "ICTransportTypeTCPIP") == nil)
        #expect(USBModeClassifier.provisionalMode(transportType: nil) == nil)
    }

    @Test func aCatalogueThatCompletesAtOnceWithNoFilesIsRemoteShoot() {
        let pcRemote = USBModeClassifier.CatalogueEvidence(fileCount: 0, secondsToComplete: 0.03)
        #expect(USBModeClassifier.mode(after: pcRemote, provisional: .mtp) == .remoteShoot)
    }

    @Test func filesOrASlowCatalogueMeanMTP() {
        let cold = USBModeClassifier.CatalogueEvidence(fileCount: 391, secondsToComplete: 64.96)
        let kept = USBModeClassifier.CatalogueEvidence(fileCount: 391, secondsToComplete: 0.09)
        let slowEmpty = USBModeClassifier.CatalogueEvidence(fileCount: 0, secondsToComplete: 5)
        #expect(USBModeClassifier.mode(after: cold, provisional: .mtp) == .mtp)
        #expect(USBModeClassifier.mode(after: kept, provisional: .mtp) == .mtp)
        #expect(USBModeClassifier.mode(after: slowEmpty, provisional: .mtp) == .mtp)
    }

    @Test func massStorageStaysMassStorageEvenWhenEmpty() {
        let empty = USBModeClassifier.CatalogueEvidence(fileCount: 0, secondsToComplete: 0.01)
        #expect(USBModeClassifier.mode(after: empty, provisional: .massStorage) == .massStorage)
    }

    @Test func theDeviceInfoSeamWinsWhenFilledIn() {
        var evidence = USBModeClassifier.CatalogueEvidence(fileCount: 0, secondsToComplete: 0.03)
        evidence.deviceInfoOperationCount = 24
        #expect(USBModeClassifier.mode(after: evidence, provisional: .mtp) == .mtp)
        evidence.deviceInfoOperationCount = 81
        evidence.fileCount = 12
        #expect(USBModeClassifier.mode(after: evidence, provisional: .mtp) == .remoteShoot)
    }

    @Test func onlyDeniedAndRestrictedStopBrowsing() {
        #expect(USBContentsAccess.authorised.allowsBrowsing)
        #expect(USBContentsAccess.notDetermined.allowsBrowsing)
        #expect(!USBContentsAccess.denied.allowsBrowsing)
        #expect(!USBContentsAccess.restricted.allowsBrowsing)
    }

    @Test func cameraKeyMaterialIsMTPOnlyAndNeverPrinted() {
        let uuid = "00000000-0000-0000-0000-ABCDEF123456"
        let key = USBCameraKeyMaterial.material(mode: .mtp, deviceUUID: uuid)
        #expect(key?.rawValue == uuid)
        #expect(!String(describing: key!).contains("ABCDEF"))
        #expect(USBCameraKeyMaterial.material(mode: .massStorage, deviceUUID: uuid) == nil)
        #expect(USBCameraKeyMaterial.material(mode: .remoteShoot, deviceUUID: uuid) == nil)
        #expect(USBCameraKeyMaterial.material(mode: .mtp, deviceUUID: "") == nil)
        #expect(USBCameraKeyMaterial.material(mode: .mtp, deviceUUID: nil) == nil)
    }
}

@Suite("ImageCaptureCore failures are classified")
struct USBFailureMappingTests {
    let icc = "com.apple.ImageCaptureCore"

    @Test func aRemovalIsRetryOnReconnectWhateverTheCode() {
        for operation in USBFailureMapping.Operation.allCases {
            for code in [-9934, -9923, -9943, 12345] {
                let failure = USBFailureMapping.failure(domain: icc, code: code, operation: operation, deviceRemoved: true)
                #expect(failure.kind == .disconnected)
                #expect(failure.outcome == .retryOnReconnect)
            }
        }
    }

    @Test func theSpikesMinus9934() {
        let pulled = USBFailureMapping.failure(domain: icc, code: -9934, operation: .download, deviceRemoved: true)
        #expect(pulled.outcome == .retryOnReconnect)
        #expect(pulled.detail == "download: ImageCaptureCore -9934")
        let attached = USBFailureMapping.failure(domain: icc, code: -9934, operation: .download, deviceRemoved: false)
        #expect(attached.outcome == .retryNow)
    }

    @Test func aFullPhoneStopsTheJob() {
        let cocoa = USBFailureMapping.failure(domain: NSCocoaErrorDomain, code: 640, operation: .download, deviceRemoved: false)
        let posix = USBFailureMapping.failure(domain: NSPOSIXErrorDomain, code: 28, operation: .download, deviceRemoved: false)
        #expect(cocoa.kind == .phoneStorageFull)
        #expect(posix.kind == .phoneStorageFull)
        #expect(cocoa.outcome == .stopJob)
        // The same numbers in ImageCaptureCore's domain mean nothing special.
        #expect(USBFailureMapping.failure(domain: icc, code: 640, operation: .download, deviceRemoved: false).kind == .busy)
    }

    @Test func theCodeTable() {
        func kind(_ code: Int, _ operation: USBFailureMapping.Operation = .download) -> CameraLinkFailure.Kind {
            USBFailureMapping.failure(domain: icc, code: code, operation: operation, deviceRemoved: false).kind
        }
        #expect(kind(-9923) == .noAnswer)
        #expect(kind(-9936) == .noAnswer)
        #expect(kind(-9958) == .disconnected)
        #expect(kind(-21351) == .disconnected)
        #expect(kind(-21352) == .disconnected)
        #expect(kind(-9943) == .notAuthorised)
        #expect(kind(-9927, .open) == .busy)
        #expect(kind(-9937) == .busy)
        #expect(kind(-9954, .list) == .busy)
        #expect(kind(-9955) == .busy)
        #expect(kind(-9956) == .busy)
        #expect(kind(-9957) == .busy)
    }

    @Test func unknownCodesFallBackPerOperation() {
        func kind(_ operation: USBFailureMapping.Operation) -> CameraLinkFailure.Kind {
            USBFailureMapping.failure(domain: icc, code: -1, operation: operation, deviceRemoved: false).kind
        }
        #expect(kind(.thumbnail) == .unreadableItem)
        #expect(kind(.download) == .busy)
        #expect(kind(.open) == .busy)
        #expect(kind(.list) == .busy)
    }

    @Test func timeoutsCancelsAndTheLogDetail() {
        let late = USBFailureMapping.timedOut(.thumbnail, after: USBFailureMapping.thumbnailTimeout)
        #expect(late.kind == .noAnswer)
        #expect(late.detail == "thumbnail: no answer in 10 s")
        #expect(USBFailureMapping.timedOut(.open, after: USBFailureMapping.openTimeout).detail == "open: no answer in 60 s")
        let cancelled = USBFailureMapping.cancelled(.download)
        #expect(cancelled.outcome == .retryNow)
        #expect(cancelled.detail == "download: cancelled")
        #expect(USBFailureMapping.shortDomain("com.apple.ImageCaptureCore") == "ImageCaptureCore")
        #expect(USBFailureMapping.shortDomain(NSPOSIXErrorDomain) == NSPOSIXErrorDomain)
    }

    @Test func pullsAreGivenTimeToArriveButDownloadsNeverTimeOut() {
        // A pull reported a moment after the failed file still counts as a pull; the grace stays short of the
        // thumbnail limit so it never holds a request longer than a slow one would.
        #expect(USBFailureMapping.removalGrace > .zero)
        #expect(USBFailureMapping.removalGrace < USBFailureMapping.thumbnailTimeout)
        #expect(USBFailureMapping.openTimeout <= .seconds(60))
    }
}

@Suite("Thumbnails: two in flight, newest first")
struct ThumbnailQueueTests {
    @Test func twoStartAtOnceAndTheRestWait() {
        var queue = ThumbnailQueue()
        do { let r = queue.arrive(ticket: 1, rank: 10); #expect(r) }
        do { let r = queue.arrive(ticket: 2, rank: 11); #expect(r) }
        do { let r = queue.arrive(ticket: 3, rank: 12); #expect(!r) }
        #expect(queue.inFlight == 2)
        #expect(queue.waitingCount == 1)
    }

    @Test func aFreedSlotGoesToTheNewestWaitingThenFirstComeFirstServed() {
        var queue = ThumbnailQueue()
        _ = queue.arrive(ticket: 1, rank: 0)
        _ = queue.arrive(ticket: 2, rank: 1)
        _ = queue.arrive(ticket: 3, rank: 40)
        _ = queue.arrive(ticket: 4, rank: 7)
        _ = queue.arrive(ticket: 5, rank: .max)
        _ = queue.arrive(ticket: 6, rank: 7)
        var order: [UInt64] = []
        while let next = queue.finish() { order.append(next) }
        #expect(order == [4, 6, 3, 5])
        #expect(queue.inFlight == 1)   // the last finish() found no one waiting and freed one slot
        do { let r = queue.finish(); #expect(r == nil) }
        #expect(queue.inFlight == 0)
    }

    @Test func aNewArrivalDoesNotJumpTheQueueWhileOthersWait() {
        var queue = ThumbnailQueue()
        _ = queue.arrive(ticket: 1, rank: 5)
        _ = queue.arrive(ticket: 2, rank: 5)
        _ = queue.arrive(ticket: 3, rank: 9)
        do { let r = queue.finish(); #expect(r == 3) }
        // Two in flight again (2 and 3); a newer file arriving now waits for a slot like the rest.
        do { let r = queue.arrive(ticket: 4, rank: 0); #expect(!r) }
    }

    @Test func aWithdrawnRequestLeavesTheQueue() {
        var queue = ThumbnailQueue(limit: 1)
        _ = queue.arrive(ticket: 1, rank: 0)
        _ = queue.arrive(ticket: 2, rank: 1)
        _ = queue.arrive(ticket: 3, rank: 2)
        do { let r = queue.withdraw(ticket: 2); #expect(r) }
        do { let r = queue.withdraw(ticket: 2); #expect(!r) }
        do { let r = queue.withdraw(ticket: 1); #expect(!r) }   // in flight, not waiting
        do { let r = queue.finish(); #expect(r == 3) }
    }
}

/// Records the order the gate lets waiters through.
actor Admissions {
    private(set) var ranks: [Int] = []
    func record(_ rank: Int) { ranks.append(rank) }
}

@Suite("The thumbnail gate")
struct ThumbnailGateTests {
    /// Polls until `condition` holds, yielding between tries.
    func eventually(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }

    @Test func waitersGoThroughNewestFirstAndNeverMoreThanTwo() async throws {
        let gate = ThumbnailGate(limit: 2)
        try await gate.enter(rank: 100)
        try await gate.enter(rank: 101)
        let admissions = Admissions()
        var waiters: [Task<Void, Never>] = []
        for rank in [5, 1, 3] {
            waiters.append(Task {
                do {
                    try await gate.enter(rank: rank)
                    await admissions.record(rank)
                } catch {
                    Issue.record("unexpected \(error)")
                }
            })
            await eventually { await gate.waitingCount == waiters.count }
        }
        #expect(await gate.inFlight == 2)
        for expected in 1...3 {
            await gate.leave()
            await eventually { await admissions.ranks.count == expected }
            #expect(await gate.inFlight == 2)
        }
        for waiter in waiters { await waiter.value }
        #expect(await admissions.ranks == [1, 3, 5])
    }

    @Test func aCancelledWaiterLeavesWithTheCancelledFailure() async throws {
        let gate = ThumbnailGate(limit: 1)
        try await gate.enter(rank: 0)
        let waiter = Task { () -> CameraLinkFailure? in
            do throws(CameraLinkFailure) {
                try await gate.enter(rank: 1)
                return nil
            } catch {
                return error
            }
        }
        await eventually { await gate.waitingCount == 1 }
        waiter.cancel()
        let failure = await waiter.value
        #expect(failure == USBFailureMapping.cancelled(.thumbnail))
        #expect(await gate.waitingCount == 0)
        await gate.leave()
        #expect(await gate.inFlight == 0)
    }
}

@Suite("Pending ImageCaptureCore calls")
struct PendingCallsTests {
    actor Box {
        var calls = PendingCalls<Int>()
        func wait() async -> Int {
            let id = calls.reserve()
            return await withCheckedContinuation { calls.park(id, $0) }
        }
        func finish(_ id: UInt64, _ value: Int) -> Bool { calls.finish(id, with: value) }
        func finishAll(_ value: Int) -> Int { calls.finishAll(with: value) }
        var count: Int { calls.count }
    }

    @Test func eachCallFinishesExactlyOnce() async {
        let box = Box()
        let first = Task { await box.wait() }
        while await box.count < 1 { await Task.yield() }
        #expect(await box.finish(1, 7))
        #expect(await !box.finish(1, 8))     // the late completion is dropped
        #expect(await !box.finish(99, 0))    // never parked
        #expect(await first.value == 7)
    }

    @Test func aRemovalFinishesEveryWaitingCall() async {
        let box = Box()
        let a = Task { await box.wait() }
        let b = Task { await box.wait() }
        while await box.count < 2 { await Task.yield() }
        #expect(await box.finishAll(-1) == 2)
        #expect(await a.value == -1)
        #expect(await b.value == -1)
        #expect(await box.finishAll(-1) == 0)
    }
}

@Suite("Listing from ImageCaptureCore's items")
struct USBListingTests {
    func entry(_ id: String, _ name: String?, size: Int64 = 1, date: Date? = nil,
               ancestors: [String] = ["100MSDCF", "DCIM"]) -> USBCatalogueEntry {
        USBCatalogueEntry(id: .init(rawValue: id), ancestorsNearestFirst: ancestors, name: name, fileSize: size,
                          creationDate: date)
    }

    @Test func folderPathRunsFromTheTop() {
        #expect(USBListing.folderPath(ancestorsNearestFirst: ["100MSDCF", "DCIM"]) == "DCIM/100MSDCF")
        #expect(USBListing.folderPath(ancestorsNearestFirst: ["100MSDCF", "", "DCIM"]) == "DCIM/100MSDCF")
        #expect(USBListing.folderPath(ancestorsNearestFirst: []) == "")
        let deep = Array(repeating: "x", count: 40)
        #expect(USBListing.folderPath(ancestorsNearestFirst: deep).split(separator: "/").count
                == USBListing.maximumFolderDepth)
    }

    @Test func anItemCarriesNameFolderSizeDateAndFormat() throws {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let item = try #require(USBListing.item(from: entry("usb-1", "DSC04512.ARW", size: 44_000_000, date: date)))
        #expect(item.id.rawValue == "usb-1")
        #expect(item.folder == "DCIM/100MSDCF")
        #expect(item.name == "DSC04512.ARW")
        #expect(item.size == 44_000_000)
        #expect(item.captureDate == date)
        #expect(item.format == .raw)
    }

    @Test func namelessFilesAreLeftOutAndNegativeSizesAreZero() {
        #expect(USBListing.item(from: entry("a", nil)) == nil)
        #expect(USBListing.item(from: entry("b", "")) == nil)
        #expect(USBListing.item(from: entry("c", "DSC00001.JPG", size: -1))?.size == 0)
    }

    @Test func theListingIsNewestFirstWithRanksForTheThumbnailQueue() {
        let t = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let (items, ranks) = USBListing.listing(from: [
            entry("old", "DSC00001.ARW", date: t),
            entry("none", "DSC00002.ARW"),
            entry("new", "DSC00003.ARW", date: t.addingTimeInterval(1)),
            entry("noname", nil, date: t.addingTimeInterval(2)),
        ])
        #expect(items.map(\.id.rawValue) == ["new", "old", "none"])
        #expect(ranks == [.init(rawValue: "new"): 0, .init(rawValue: "old"): 1, .init(rawValue: "none"): 2])
    }

    @Test func whereADownloadLanded() {
        let dir = URL(fileURLWithPath: "/tmp/import", isDirectory: true)
        #expect(USBListing.downloadedURL(completionName: "DSC00001.ARW", fileName: "x", directory: dir).path
                == "/tmp/import/DSC00001.ARW")
        #expect(USBListing.downloadedURL(completionName: "/var/other/DSC00001.ARW", fileName: "x", directory: dir).path
                == "/var/other/DSC00001.ARW")
        #expect(USBListing.downloadedURL(completionName: nil, fileName: "DSC00009.JPG", directory: dir).path
                == "/tmp/import/DSC00009.JPG")
        #expect(USBListing.downloadedURL(completionName: "", fileName: "DSC00009.JPG", directory: dir).path
                == "/tmp/import/DSC00009.JPG")
    }

    @Test func bytesFromAProgressFraction() {
        #expect(USBListing.bytesWritten(fraction: 0, size: 1000) == 0)
        #expect(USBListing.bytesWritten(fraction: -0.5, size: 1000) == 0)
        #expect(USBListing.bytesWritten(fraction: .nan, size: 1000) == 0)
        #expect(USBListing.bytesWritten(fraction: 0.4567, size: 1000) == 456)
        #expect(USBListing.bytesWritten(fraction: 1, size: 1000) == 1000)
        #expect(USBListing.bytesWritten(fraction: 3, size: 1000) == 1000)
    }

    @Test func catalogueTimingStartsEmpty() {
        let timing = USBCatalogueTiming()
        #expect(timing.secondsToComplete == nil)
        #expect(timing.itemsAnnouncedBeforeComplete == 0)
        #expect(!timing.completedWithoutCallback)
    }
}

@Suite("USB discovery events")
struct USBDiscoveryEventTests {
    @Test func appearedCarriesTheDescriptorAndItsMode() {
        let d = CameraDescriptor(id: .init(rawValue: "u"), name: "Untitled", mode: .usb(.massStorage))
        let events: [USBDiscoveryEvent] = [.appeared(d), .disappeared(d.id)]
        #expect(events.first == .appeared(d))
        #expect(events.last == .disappeared(.init(rawValue: "u")))
    }
}

// MARK: - Review fixes (8 Nov)

/// Mirrors how `USBLink` asks for a classification: from its actor, with a closure that reads its own state.
actor RemovalStandIn {
    private var removed = false
    func remove() { removed = true }

    func classify(_ domain: String, _ code: Int, _ operation: USBFailureMapping.Operation,
                  outOfSpace: Bool = false) async -> CameraLinkFailure {
        await USBFailureMapping.classify(domain: domain, code: code, outOfSpace: outOfSpace, operation: operation) {
            [self] in await self.removed
        }
    }
}

/// Mirrors `USBLink.thumbnail` and `request` with a stand-in for ImageCaptureCore: the gate, the re-check after it,
/// the refusal before sending, and `close()` finishing the calls in flight.
actor ThumbnailStandIn {
    private let gate = ThumbnailGate(limit: 2)
    private var calls = PendingCalls<Int>()
    private var closed = false
    private(set) var sentAfterClose = 0
    private(set) var sent = 0

    var inFlight: Int { calls.count }

    func thumbnail(rank: Int) async throws(CameraLinkFailure) {
        try await gate.enter(rank: rank)
        if closed {   // the re-check after the gate (`requireOpen`)
            await gate.leave()
            throw CameraLinkFailure(.disconnected, detail: "thumbnail: the link isn't open")
        }
        let outcome = await request()
        await gate.leave()
        if let outcome { throw outcome }
    }

    /// nil: the device answered (the stand-in never does; close() finishes it).
    private func request() async -> CameraLinkFailure? {
        if let refusal = USBFailureMapping.refusal(.thumbnail, removed: false, closed: closed) { return refusal }
        if closed { sentAfterClose += 1 }
        sent += 1
        let id = calls.reserve()
        let code = await withCheckedContinuation { calls.park(id, $0) }
        return code == 0 ? nil : CameraLinkFailure(.disconnected, detail: "the link was closed")
    }

    func close() {
        closed = true
        calls.finishAll(with: -1)
    }
}

@Suite("Review fixes: closing, removals, the catalogue, duplicates, a full phone, progress")
struct USBReviewFixTests {
    let icc = "com.apple.ImageCaptureCore"

    @Test func aClosedLinkSendsNothingButItsOwnClose() {
        for operation in USBFailureMapping.Operation.allCases where operation != .close {
            let refusal = USBFailureMapping.refusal(operation, removed: false, closed: true)
            #expect(refusal?.kind == .disconnected)
            #expect(refusal?.outcome == .retryOnReconnect)
            #expect(refusal?.detail == "\(operation.rawValue): the link is closed")
            #expect(USBFailureMapping.refusal(operation, removed: false, closed: false) == nil)
        }
        #expect(USBFailureMapping.refusal(.close, removed: false, closed: true) == nil)
        #expect(USBFailureMapping.refusal(.close, removed: true, closed: true)?.kind == .disconnected)
        #expect(USBFailureMapping.refusal(.download, removed: true, closed: false)?.detail == "download: the camera has gone")
    }

    @Test func thumbnailsWaitingForASlotWhenTheLinkClosesNeverReachTheCamera() async {
        let link = ThumbnailStandIn()
        var tasks: [Task<CameraLinkFailure?, Never>] = []
        for rank in 0..<6 {
            tasks.append(Task {
                do throws(CameraLinkFailure) { try await link.thumbnail(rank: rank); return nil } catch { return error }
            })
        }
        while await link.inFlight < 2 { await Task.yield() }
        // Let the other four reach the gate before the close.
        for _ in 0..<200 { await Task.yield() }
        await link.close()
        var failures: [CameraLinkFailure?] = []
        for task in tasks { failures.append(await task.value) }
        #expect(failures.allSatisfy { $0?.kind == .disconnected })
        #expect(await link.sent == 2)
        #expect(await link.sentAfterClose == 0)
    }

    @Test func everyCallButTheCloseWaitsForARemovalAndThumbnailsBriefly() {
        #expect(USBFailureMapping.removalGrace(for: .download) == USBFailureMapping.removalGrace)
        #expect(USBFailureMapping.removalGrace(for: .thumbnail) == USBFailureMapping.shortRemovalGrace)
        #expect(USBFailureMapping.removalGrace(for: .open) == USBFailureMapping.shortRemovalGrace)
        #expect(USBFailureMapping.removalGrace(for: .close) == nil)
        // Well above MTP's 30 ms between a failed read and didRemove, and short of the thumbnail limit.
        #expect(USBFailureMapping.shortRemovalGrace >= .milliseconds(500))
        #expect(USBFailureMapping.shortRemovalGrace < USBFailureMapping.removalGrace)
        #expect(USBFailureMapping.removalGrace < USBFailureMapping.thumbnailTimeout)
    }

    @Test(arguments: [USBFailureMapping.Operation.thumbnail, .open, .download])
    func aRemovalJustAfterTheErrorMakesItDisconnected(_ operation: USBFailureMapping.Operation) async {
        let link = RemovalStandIn()
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            await link.remove()
        }
        let failure = await link.classify(icc, -21000, operation)
        #expect(failure.kind == .disconnected)
        #expect(failure.outcome == .retryOnReconnect)
        #expect(failure.detail == "\(operation.rawValue): ImageCaptureCore -21000")
    }

    @Test func withNoRemovalAThumbnailIsClassifiedAfterTheShortGrace() async {
        let link = RemovalStandIn()
        let clock = ContinuousClock()
        let start = clock.now
        let failure = await link.classify(icc, -21000, .thumbnail)
        let waited = clock.now - start
        #expect(failure.kind == .unreadableItem)
        #expect(waited >= USBFailureMapping.shortRemovalGrace)
        #expect(waited < USBFailureMapping.shortRemovalGrace + .seconds(2))
    }

    @Test func theCloseNeverWaits() async {
        let link = RemovalStandIn()
        let clock = ContinuousClock()
        let start = clock.now
        _ = await link.classify(icc, -1, .close)
        #expect(clock.now - start < .milliseconds(500))
    }

    @Test func anAdoptedCatalogueAt100WithNoFilesGetsTheSameAnswerWhenListComesLate() {
        let opened = ContinuousClock.now
        let atOpen = opened + .milliseconds(30)   // the open completes; the percentage already reads 100
        func evidence(listAfter delay: Duration) -> (USBMode, Duration) {
            var watch = USBCatalogueWatch()
            #expect(watch.read(percent: 100, at: atOpen) == nil)
            var now = atOpen + delay
            while true {
                if let since = watch.read(percent: 100, at: now) {
                    let seconds = Double((since - opened).components.seconds)
                        + Double((since - opened).components.attoseconds) / 1e18
                    let mode = USBModeClassifier.mode(
                        after: .init(fileCount: 0, secondsToComplete: seconds), provisional: .mtp)
                    return (mode, now - atOpen)
                }
                now += .milliseconds(100)
            }
        }
        let soon = evidence(listAfter: .milliseconds(10))
        let late = evidence(listAfter: .seconds(2))
        let veryLate = evidence(listAfter: .seconds(12))
        #expect(soon.0 == .remoteShoot)
        #expect(late.0 == .remoteShoot)
        #expect(veryLate.0 == .remoteShoot)
        // The 10 s hold counts from the open's reading, not from list's first poll.
        #expect(soon.1 <= USBCatalogueWatch.hold + .milliseconds(200))
        #expect(late.1 <= USBCatalogueWatch.hold + .milliseconds(200))
        #expect(veryLate.1 == .seconds(12))
    }

    @Test func theCatalogueWatchNeedsTheFullHoldAt100() {
        let t0 = ContinuousClock.now
        var watch = USBCatalogueWatch()
        #expect(watch.read(percent: 99, at: t0) == nil)
        #expect(watch.fullSince == nil)
        #expect(watch.read(percent: 100, at: t0 + .seconds(1)) == nil)
        #expect(watch.read(percent: 100, at: t0 + .seconds(11)) == nil)   // exactly 10 s: not yet
        #expect(watch.read(percent: 100, at: t0 + .seconds(11) + .milliseconds(1)) == t0 + .seconds(1))
    }

    final class FakeDevice {}

    @Test func aCameraListedTwiceIsOneCameraAndOnlyTheDeviceThatWentIsRemoved() {
        let id = CameraDescriptor.ID(rawValue: "00000000-0000-0000-0000-000000000000")
        let old = FakeDevice(), live = FakeDevice()
        let oldID = ObjectIdentifier(old), liveID = ObjectIdentifier(live)
        let d = CameraDescriptor(id: id, name: "ILCE-7CM2", mode: .usb(.mtp))
        var cameras = USBAttachedCameras()
        #expect(cameras.add(oldID, d) == [.appeared(d)])
        #expect(cameras.add(liveID, d) == [.appeared(d)])   // an update: still one camera
        #expect(cameras.add(liveID, d) == [])
        #expect(cameras.cameras == [d])
        #expect(cameras.device(for: id) == liveID)          // link(for:) opens the newest listing
        // The stale listing goes: nothing to report, the live one stays offered.
        #expect(cameras.remove(oldID) == [])
        #expect(cameras.cameras == [d])
        #expect(cameras.device(for: id) == liveID)
        #expect(cameras.remove(liveID) == [.disappeared(id)])
        #expect(cameras.cameras.isEmpty)
        #expect(cameras.remove(liveID) == [])
    }

    @Test func ifTheNewerListingGoesFirstTheOlderIsOfferedAgain() {
        let id = CameraDescriptor.ID(rawValue: "u")
        let old = FakeDevice(), new = FakeDevice()
        let d = CameraDescriptor(id: id, name: "Camera", mode: .usb(.mtp))
        var cameras = USBAttachedCameras()
        _ = cameras.add(ObjectIdentifier(old), d)
        _ = cameras.add(ObjectIdentifier(new), d)
        #expect(cameras.rename(ObjectIdentifier(old), to: "Old") == [])   // not offered, so no update
        let oldNow = CameraDescriptor(id: id, name: "Old", mode: .usb(.mtp))
        #expect(cameras.remove(ObjectIdentifier(new)) == [.appeared(oldNow)])
        #expect(cameras.device(for: id) == ObjectIdentifier(old))
        #expect(cameras.removeAll() == [.disappeared(id)])
        #expect(cameras.cameras.isEmpty)
    }

    @Test func aFullDiskWrappedInImageCaptureCoresDownloadFailedStopsTheJob() {
        let enospc = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let wrapped = NSError(domain: icc, code: -9934, userInfo: [NSUnderlyingErrorKey: enospc])
        let deeper = NSError(domain: icc, code: -9934, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: 640)])])
        #expect(USBFailureMapping.isOutOfSpace(wrapped))
        #expect(USBFailureMapping.isOutOfSpace(deeper))
        #expect(USBFailureMapping.isOutOfSpace(enospc))
        #expect(!USBFailureMapping.isOutOfSpace(NSError(domain: icc, code: -9934)))
        let full = USBFailureMapping.failure(domain: icc, code: -9934, operation: .download, deviceRemoved: false,
                                             outOfSpace: USBFailureMapping.isOutOfSpace(wrapped))
        #expect(full.kind == .phoneStorageFull)
        #expect(full.outcome == .stopJob)
        // A removal still wins: the file is copied again after the replug.
        let pulled = USBFailureMapping.failure(domain: icc, code: -9934, operation: .download, deviceRemoved: true,
                                               outOfSpace: true)
        #expect(pulled.kind == .disconnected)
    }

    @Test func aFullDiskSurvivesTheRemovalGrace() async {
        let failure = await RemovalStandIn().classify(icc, -9934, .close, outOfSpace: true)
        #expect(failure.kind == .phoneStorageFull)
    }

    @Test func progressOnlyGoesUpAndStopsWhenTheDownloadEnds() {
        var reports = USBProgressReports(size: 1000)
        #expect(reports.poll(fraction: 0) == 0)
        #expect(reports.poll(fraction: 0) == nil)           // no change
        #expect(reports.poll(fraction: 0.5) == 500)
        #expect(reports.poll(fraction: 0.4) == nil)         // never backwards
        #expect(reports.poll(fraction: 1) == nil)           // the full size comes from the file on disk
        #expect(reports.poll(fraction: 0.75) == 750)
        reports.end()
        #expect(reports.poll(fraction: 0.9) == nil)         // nothing after the final size
        #expect(reports.last == 750)
    }
}
