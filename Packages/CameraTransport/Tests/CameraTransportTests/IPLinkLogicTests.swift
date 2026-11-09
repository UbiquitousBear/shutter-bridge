import Foundation
import PTPKit
import Testing
@testable import CameraTransport

/// The pure parts of `IPLink` (plan W6): item IDs, the event rules, the failure table, folder paths and the session
/// kind. The link itself runs against the simulated camera in PTPSimulator's `IPLinkAgainstSimulatorTests`.
@Suite("IPLink's pure rules")
struct IPLinkLogicTests {
    // MARK: Item IDs

    @Test func itemIDsCarryTheHandleBothWays() throws {
        for raw: UInt32 in [0, 1, 0x4000_10A3, 0x0008_0000, UInt32.max] {
            let id = IPItemID.id(for: PTPObjectHandle(rawValue: raw))
            #expect(id.rawValue.hasPrefix("h-"))
            #expect(IPItemID.handle(of: id) == PTPObjectHandle(rawValue: raw))
        }
        // The spelling SimulatedCameraLink uses for a Wi-Fi item.
        #expect(IPItemID.id(for: PTPObjectHandle(rawValue: 0x4000_10A3)).rawValue == "h-400010a3")
    }

    @Test func foreignItemIDsAreRefused() {
        for raw in ["", "h-", "400010a3", "g1-400010a3", "h-123456789", "h-xyz", "h--1", "h-+1", "usb-1"] {
            #expect(IPItemID.handle(of: CameraItem.ID(rawValue: raw)) == nil, "\(raw)")
        }
    }

    // MARK: Events

    /// An event as the camera sends it (transaction ID 0xFFFFFFFF, as in the fixtures), decoded from its packet.
    private func event(_ code: PTPEventCode, _ parameters: [UInt32] = []) -> PTPIP.Event {
        // The packet is built here, so it always decodes.
        try! PTPIP.decodeEvent(PTPIP.event(code, transactionID: 0xFFFF_FFFF, parameters: parameters))
    }

    @Test func theSessionsOwnStoreAddedIsNotForwarded() {
        var mapper = IPEventMapper()
        #expect(mapper.map(event(.storeAdded, [0x0001_0001])) == .ignore(.storeAdded))
        #expect(mapper.storeAddedSeen && !mapper.cardRemoved)
    }

    @Test func aDroppedCardIsForwardedUntilItComesBack() {
        var mapper = IPEventMapper()
        _ = mapper.map(event(.storeAdded, [0x0001_0001]))
        #expect(mapper.map(event(.storeRemoved, [0x0001_0001])) == .forward(.storeRemoved))
        #expect(mapper.cardRemoved)
        #expect(mapper.map(event(.storeAdded, [0x0001_0001])) == .forward(.storeAdded))
        #expect(!mapper.cardRemoved)
        // Asked again with the card there: nothing new.
        #expect(mapper.map(event(.storeAdded, [0x0001_0001])) == .ignore(.storeAdded))
    }

    @Test func shotsAndUnknownEventsAreIgnored() {
        var mapper = IPEventMapper()
        let c225 = PTPEventCode(rawValue: 0xC225)
        let c223 = PTPEventCode(rawValue: 0xC223)
        #expect(mapper.map(event(.sonyObjectAdded, [0xFFFF_C001])) == .ignore(.sonyObjectAdded))
        #expect(mapper.map(event(c225, [0, 0x0001_0001, 0])) == .ignore(c225))
        #expect(mapper.map(event(c223, [1])) == .ignore(c223))
        #expect(mapper.map(event(.objectAdded, [7])) == .ignore(.objectAdded))
        #expect(!mapper.cardRemoved && !mapper.storeAddedSeen)
    }

    // MARK: Failures

    @Test func connectionFailuresRetryOnReconnectUnlessRefused() {
        let disconnecting: [PTPIPConnectionFailure] = [
            .timedOut(.transaction), .timedOut(.initCommandAck), .linkLost(posix: 53), .closed,
            .protocolViolation("x"), .aborted, .sinkFailed("x"), .cancelled, .cancelledBeforeStart, .notConnected,
        ]
        for failure in disconnecting {
            #expect(IPFailureMapping.failure(failure, during: .download).kind == .disconnected, "\(failure)")
        }
        #expect(IPFailureMapping.failure(.refused(initFailReason: 2), during: .open).kind == .refused)
        #expect(IPFailureMapping.failure(.refused(initFailReason: nil), during: .open).outcome == .stopJob)
        #expect(IPFailureMapping.failure(.busy, during: .list).outcome == .retryNow)
    }

    @Test func invalidObjectHandleSkipsTheFileOnlyWhileTheCardIsThere() {
        #expect(IPFailureMapping.kind(for: .invalidObjectHandle, during: .download, cardRemoved: false) == .itemNotFound)
        #expect(IPFailureMapping.kind(for: .invalidObjectHandle, during: .download, cardRemoved: true) == .cardUnavailable)
        #expect(IPFailureMapping.kind(for: .storeNotAvailable, during: .download, cardRemoved: false) == .cardUnavailable)
        #expect(IPFailureMapping.kind(for: .storeNotAvailable, during: .thumbnail, cardRemoved: false).outcome
            == .retryOnReconnect)
    }

    @Test func otherResponsesByOperation() {
        #expect(IPFailureMapping.kind(for: .deviceBusy, during: .download, cardRemoved: false) == .busy)
        #expect(IPFailureMapping.kind(for: .incompleteTransfer, during: .download, cardRemoved: false) == .noAnswer)
        #expect(IPFailureMapping.kind(for: .sessionNotOpen, during: .list, cardRemoved: false) == .disconnected)
        #expect(IPFailureMapping.kind(for: .accessDenied, during: .download, cardRemoved: false) == .unreadableItem)
        #expect(IPFailureMapping.kind(for: .noThumbnailPresent, during: .thumbnail, cardRemoved: false) == .unreadableItem)
        #expect(IPFailureMapping.kind(for: .operationNotSupported, during: .thumbnail, cardRemoved: false)
            == .unreadableItem)
        #expect(IPFailureMapping.kind(for: .operationNotSupported, during: .list, cardRemoved: false) == .modeListsNoFiles)
        #expect(IPFailureMapping.kind(for: .generalError, during: .open, cardRemoved: false) == .refused)
    }

    @Test func aSessionThatWontOpenIsClassified() {
        #expect(IPFailureMapping.failure(.linkFailed(.getDeviceInfo), connectionFailure: .refused(initFailReason: 2))
            .kind == .refused)
        #expect(IPFailureMapping.failure(.linkFailed(.getDeviceInfo), connectionFailure: .timedOut(.transaction))
            .kind == .disconnected)
        #expect(IPFailureMapping.failure(.linkFailed(.getDeviceInfo), connectionFailure: nil).kind == .disconnected)
        #expect(IPFailureMapping.failure(.stepFailed(.openSession(sessionID: 1), .accessDenied), connectionFailure: nil)
            .kind == .refused)
        #expect(IPFailureMapping.failure(.outOfOrder, connectionFailure: nil).kind == .disconnected)
    }

    @Test func handshakeRetryIsNotForTheCallersOwnCancellation() {
        #expect(IPLink.retriesHandshake(after: .refused(initFailReason: nil)))
        #expect(IPLink.retriesHandshake(after: .timedOut(.initCommandAck)))
        #expect(!IPLink.retriesHandshake(after: .cancelled))
        #expect(!IPLink.retriesHandshake(after: .cancelledBeforeStart))
    }

    @Test func aFullPhoneStopsTheJob() {
        let full = NSError(domain: NSPOSIXErrorDomain, code: 28)
        #expect(IPLink.writeFailure(full).kind == .phoneStorageFull)
        let other = NSError(domain: NSCocoaErrorDomain, code: 513)
        #expect(IPLink.writeFailure(other).kind == .unreadableItem)
    }

    // MARK: Listing

    private func info(_ name: String, format: PTPObjectFormat, parent: UInt32, date: String = "20261101T090000",
                      size: UInt32 = 100) -> PTPObjectInfo {
        PTPObjectInfo(storageID: PTPStorageID(rawValue: 0x0001_0001), objectFormat: format, protectionStatus: 0,
                      objectCompressedSize: size, thumbFormat: .undefined, thumbCompressedSize: 0, thumbPixWidth: 0,
                      thumbPixHeight: 0, imagePixWidth: 0, imagePixHeight: 0, imageBitDepth: 0,
                      parentObject: PTPObjectHandle(rawValue: parent), associationType: 0, associationDescription: 0,
                      sequenceNumber: 0, filename: name, captureDateRaw: date, modificationDateRaw: "", keywords: "")
    }

    @Test func foldersComeFromTheListingsOwnFolders() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let infos: [(handle: PTPObjectHandle, info: PTPObjectInfo)] = [
            (PTPObjectHandle(rawValue: 0x0008_0000), info("DCIM", format: .association, parent: 0)),
            (PTPObjectHandle(rawValue: 0x0010_0000), info("100MSDCF", format: .association, parent: 0x0008_0000)),
            (PTPObjectHandle(rawValue: 0x4000_10A3), info("DSC02046.ARW", format: .sonyARW, parent: 0x0010_0000,
                                                          date: "20261101T090002")),
            (PTPObjectHandle(rawValue: 0x4000_10A4), info("DSC02047.JPG", format: .exifJPEG, parent: 0x0010_0000,
                                                          date: "20261101T090004")),
            (PTPObjectHandle(rawValue: 0x4000_10A5), info("LOOSE.JPG", format: .exifJPEG, parent: 0x7777_0000,
                                                          date: "20261101T090000")),
            (PTPObjectHandle(rawValue: 0x4000_10A6), info("", format: .exifJPEG, parent: 0)),
        ]
        let items = IPListing.items(from: infos, timeZone: utc)
        #expect(items.map(\.name) == ["DSC02047.JPG", "DSC02046.ARW", "LOOSE.JPG"])
        #expect(items.map(\.folder) == ["DCIM/100MSDCF", "DCIM/100MSDCF", ""])
        #expect(items[0].id == IPItemID.id(for: PTPObjectHandle(rawValue: 0x4000_10A4)))
        #expect(items[0].format == .jpeg && items[1].format == .raw)
        #expect(items[1].captureDate == PTPDateTime.parse("20261101T090002", defaultTimeZone: utc))
        #expect(items[1].size == 100)
    }

    @Test func onlyPlainFileNamesAreListed() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        for name in ["DSC02046.ARW", "A..B.JPG", "..JPG", "a\\b.jpg"] {
            #expect(IPListing.isSafeFileName(name), "\(name)")
        }
        for name in ["", ".", "..", "../../Library/x", "DCIM/DSC1.JPG", "/DSC1.JPG", "DSC1.JPG/", "DSC\u{0}1.JPG"] {
            #expect(!IPListing.isSafeFileName(name), "\(name)")
            let item = IPListing.item(handle: PTPObjectHandle(rawValue: 0x4000_10A3),
                                      info: info(name, format: .exifJPEG, parent: 0), folders: [:], timeZone: utc)
            #expect(item == nil, "\(name)")
        }
    }

    @Test func aLoopInTheFolderTreeEnds() {
        let a = PTPObjectHandle(rawValue: 1)
        let b = PTPObjectHandle(rawValue: 2)
        let folders: [PTPObjectHandle: IPListing.Folder] = [a: .init(name: "A", parent: b), b: .init(name: "B", parent: a)]
        #expect(IPListing.folderPath(of: a, in: folders) == "B/A")
        var deep: [PTPObjectHandle: IPListing.Folder] = [:]
        for n: UInt32 in 1 ... 40 { deep[PTPObjectHandle(rawValue: n)] = .init(name: "f\(n)", parent: PTPObjectHandle(rawValue: n + 1)) }
        let path = IPListing.folderPath(of: PTPObjectHandle(rawValue: 1), in: deep)
        #expect(path.split(separator: "/").count == IPListing.maximumFolderDepth)
    }

    // MARK: Session

    @Test func theSessionKindFollowsWhichOpenWasAccepted() {
        let whole = [SonySessionRunner.Record(operation: .sdioOpenSession(sessionID: 1, functionMode: 1), response: .ok,
                                              accepted: true)]
        #expect(IPLink.sessionKind(of: whole) == .wholeCardContentsTransfer)
        let plain = [
            SonySessionRunner.Record(operation: .sdioOpenSession(sessionID: 1, functionMode: 1),
                                     response: .operationNotSupported, accepted: false),
            SonySessionRunner.Record(operation: .openSession(sessionID: 1), response: .ok, accepted: true),
        ]
        #expect(IPLink.sessionKind(of: plain) == .plain)
    }

    @Test func briefTransactionsGoAheadOfQueuedTransfers() {
        #expect(IPSession.nextTurn(among: []) == nil)
        #expect(IPSession.nextTurn(among: [.transfer, .transfer]) == 0)
        #expect(IPSession.nextTurn(among: [.transfer, .brief, .transfer, .brief]) == 1)
        #expect(IPSession.nextTurn(among: [.brief, .transfer]) == 0)
    }

    @Test func capabilitiesAreWiFisWithoutResumeBeforeDeviceInfo() {
        let capabilities = IPLink.capabilitiesWithoutResume
        #expect(capabilities.maxDownloadsInFlight == 1)
        #expect(!capabilities.resumesPartialFiles)
        #expect(!capabilities.reportsBatteryAndFreeSpace && !capabilities.deletes && capabilities.itemIDsSurviveReopen)
    }

    @Test func theDefaultConfigurationIsThePlans() {
        let configuration = IPLink.Configuration(guid: UUID())
        #expect(configuration.endpoint == .cameraNetwork)
        #expect(configuration.keepAlive == .seconds(10))
        #expect(configuration.timing.reply == .seconds(30))
        #expect(configuration.plan(reopening: false).listing.limit == .seconds(120))
        #expect(configuration.plan(reopening: true).listing.limit == .seconds(30))
        var reopening = configuration
        reopening.reopening = true
        #expect(reopening.plan(reopening: false).listing.limit == .seconds(30))
    }
}
