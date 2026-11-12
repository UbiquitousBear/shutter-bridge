import Foundation
import PTPKit
import Testing
@testable import CameraTransport

/// The card's free space over USB (I17): when `USBLink` may ask, the two pass-through requests, and the sum. The
/// ImageCaptureCore half (`USBLink.cardFreeSpace()`) is compiled by CI's Xcode 27 job and checked on the bench.
@Suite("The card's free space through the PTP pass-through")
struct CardFreeSpaceTests {
    private static let card = PTPStorageInfo(
        storageType: 4, filesystemType: 3, accessCapability: 0, maxCapacity: 127_865_454_592,
        freeSpaceInBytes: 52_301_234_176, freeSpaceInImages: 0, storageDescription: "", volumeLabel: "")

    @Test func onlyInMTPAfterTheCatalogueWithNoDownloadInFlight() {
        #expect(CardFreeSpace.mayAsk(mode: .mtp, catalogueComplete: true, downloadsInFlight: 0))
        #expect(!CardFreeSpace.mayAsk(mode: .mtp, catalogueComplete: false, downloadsInFlight: 0))
        #expect(!CardFreeSpace.mayAsk(mode: .mtp, catalogueComplete: true, downloadsInFlight: 1))
        #expect(!CardFreeSpace.mayAsk(mode: .massStorage, catalogueComplete: true, downloadsInFlight: 0))
        #expect(!CardFreeSpace.mayAsk(mode: .remoteShoot, catalogueComplete: true, downloadsInFlight: 0))
    }

    @Test func storesWithoutACapacityReportNothing() {
        var empty = Self.card
        empty.maxCapacity = 0
        empty.freeSpaceInBytes = 0
        #expect(CardFreeSpace.total(of: []) == nil)
        #expect(CardFreeSpace.total(of: [empty]) == nil)
        #expect(CardFreeSpace.total(of: [Self.card, empty]) == 52_301_234_176)
        #expect(CardFreeSpace.total(of: [Self.card, Self.card]) == 104_602_468_352)
    }

    @Test func freeSpaceIsNeverMoreThanTheCapacityAndNeverOverflows() {
        var odd = Self.card
        odd.freeSpaceInBytes = .max
        #expect(CardFreeSpace.total(of: [odd]) == Self.card.maxCapacity)
        var huge = Self.card
        huge.maxCapacity = .max
        huge.freeSpaceInBytes = .max
        #expect(CardFreeSpace.total(of: [huge, huge]) == .max)
    }

    @Test func readsTheLogicalStoresThroughThePassThrough() async {
        let camera = FakePassThrough(ids: [PTPStorageID(rawValue: 0x0001_0001), PTPStorageID(rawValue: 0x0002_0000)],
                                     info: Self.card)
        let free = await CardFreeSpace.read { try await camera.send($0) }
        #expect(free == 52_301_234_176)
        // GetStorageIDs, then GetStorageInfo for the store with a logical store only: the empty slot isn't asked.
        #expect(await camera.sent == [PTPOperationCode.getStorageIDs.rawValue, PTPOperationCode.getStorageInfo.rawValue])
        #expect(await camera.storages == [0x0001_0001])
    }

    @Test func anyFailureLeavesTheFreeSpaceUnknown() async {
        let ids = [PTPStorageID(rawValue: 0x0001_0001)]
        for failure in FakePassThrough.Failure.allCases {
            let camera = FakePassThrough(ids: ids, info: Self.card, failure: failure)
            #expect(await CardFreeSpace.read { try await camera.send($0) } == nil, "\(failure)")
        }
    }
}

/// A camera's answers to GetStorageIDs and GetStorageInfo, laid out as ImageCaptureCore hands them back in MTP (the
/// bare data phase, then the response container: `PTPPassThrough.Layout.dataThenResponse`).
private actor FakePassThrough {
    enum Failure: CaseIterable {
        case throwsOnInfo, noAnswer, notOK, garbledInfo
    }

    private let ids: [PTPStorageID]
    private let info: PTPStorageInfo
    private let failure: Failure?
    private(set) var sent: [UInt16] = []
    private(set) var storages: [UInt32] = []

    init(ids: [PTPStorageID], info: PTPStorageInfo, failure: Failure? = nil) {
        self.ids = ids
        self.info = info
        self.failure = failure
    }

    struct Pulled: Error {}

    func send(_ command: PTPContainer) throws -> (first: Data, second: Data) {
        sent.append(command.code)
        let isInfo = command.code == PTPOperationCode.getStorageInfo.rawValue
        if isInfo, let storage = command.parameters.first { storages.append(storage) }
        let data = isInfo ? info.encode() : PTPStorageID.encodeArray(ids)
        let ok = PTPContainer(type: .response, code: PTPResponseCode.ok.rawValue, transactionID: command.transactionID,
                              parameters: []).encode()
        switch (failure, isInfo) {
        case (.throwsOnInfo?, true): throw Pulled()
        case (.noAnswer?, true): return (Data(), Data())
        case (.notOK?, true):
            let busy = PTPContainer(type: .response, code: 0x2019, transactionID: command.transactionID, parameters: [])
            return (Data(), busy.encode())
        case (.garbledInfo?, true): return (Data([0x01, 0x02]), ok)
        default: return (data, ok)
        }
    }
}
