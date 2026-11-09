import BLEKit
import Foundation
import Testing
@testable import CameraTransport

@Suite("GATT failures and timings")
struct GATTFailureTests {
    @Test(arguments: [0x05, 0x0F])
    func theMeasuredPairingRefusalsAreNotPaired(att: Int) {
        // ATT 0x0F on the first CC09 read, 0x05 on the second read, the CCAB read and the CC08 write (4 Nov, unpaired).
        for c in [CameraControlCharacteristic.status, .wifiOn, .wifiBand, .ssid] {
            #expect(GATTFailure.classify(att: att, coreBluetooth: nil, reading: c) == .notPaired)
        }
    }

    @Test(arguments: [0x08, 0x0C])
    func theSpikesOtherPairingHintsAreNotPairedToo(att: Int) {
        // Unverified: never sent by the camera; the spike treated them as pairing hints.
        #expect(GATTFailure.classify(att: att, coreBluetooth: nil, reading: .status) == .notPaired)
    }

    @Test func attNineDOnTheNetworkDetailsMeansTheWiFiIsOffNotUnpaired() {
        #expect(GATTFailure.classify(att: 0x9D, coreBluetooth: nil, reading: .ssid) == .wifiOff)
        #expect(GATTFailure.classify(att: 0x9D, coreBluetooth: nil, reading: .passphrase) == .wifiOff)
        // Measured only on CC06 and CC07, so anywhere else it is just an error code.
        #expect(GATTFailure.classify(att: 0x9D, coreBluetooth: nil, reading: .status) == .other(0x9D))
        #expect(GATTFailure.classify(att: 0x9D, coreBluetooth: nil, reading: nil) == .other(0x9D))
    }

    @Test func coreBluetoothCodesMapToTheLinkSituations() {
        func cb(_ code: Int) -> GATTFailure { .classify(att: nil, coreBluetooth: code, reading: nil) }
        #expect(cb(7) == .linkDropped) // peripheralDisconnected
        #expect(cb(3) == .linkDropped) // notConnected
        #expect(cb(10) == .linkDropped) // connectionFailed
        #expect(cb(6) == .timedOut) // connectionTimeout
        #expect(cb(5) == .cancelled) // operationCancelled
        #expect(cb(14) == .notPaired) // peerRemovedPairingInformation (unverified)
        #expect(cb(15) == .notPaired) // encryptionTimedOut (unverified)
        #expect(cb(0) == .other(0)) // "unknown", what the notification switches returned with Creators' App
        #expect(cb(99) == .other(99))
    }

    @Test func anAttCodeWinsOverACoreBluetoothCode() {
        #expect(GATTFailure.classify(att: 0x05, coreBluetooth: 7, reading: nil) == .notPaired)
        #expect(GATTFailure.classify(att: nil, coreBluetooth: nil, reading: nil) == .other(0))
    }

    @Test func aPeripheralIdentifierPrintsRedacted() {
        let uuid = UUID()
        let id = PeripheralID(uuid)
        for text in ["\(id)", String(describing: id), String(reflecting: id), "\(Mirror(reflecting: id).children.map { "\($0.value)" })"] {
            #expect(!text.contains(uuid.uuidString))
        }
        var dumped = ""
        dump(id, to: &dumped)
        #expect(!dumped.contains(uuid.uuidString))
        #expect(id == PeripheralID(uuid))
    }

    @Test func theTimingsAreTheMeasuredAndSpikeValues() {
        // Pinned so that changing one is a decision, with its evidence updated in HandoffTiming.
        #expect(HandoffTiming.subscribeEach == .seconds(10))
        #expect(HandoffTiming.unsubscribeEach == .seconds(5))
        #expect(HandoffTiming.afterSubscribe == .seconds(1))
        #expect(HandoffTiming.statusRead == .seconds(15))
        #expect(HandoffTiming.wifiOnAck == .seconds(15))
        #expect(HandoffTiming.statusTwo == .seconds(30))
        #expect(HandoffTiming.pollIfSilentAfter == .seconds(3))
        #expect(HandoffTiming.pollEvery == .seconds(1))
        #expect(HandoffTiming.pollRead == .seconds(5))
        #expect(HandoffTiming.fallbackGrace == .seconds(3))
        #expect(HandoffTiming.credentialRetry == .seconds(2))
        #expect(HandoffTiming.credentialWindow == .seconds(20))
        #expect(HandoffTiming.credentialMinimumTries == 3)
        #expect(HandoffTiming.credentialRead == .seconds(15))
        #expect(HandoffTiming.cameraWiFiWindow == .seconds(50))
        #expect(HandoffTiming.pairingPromptThreshold == .seconds(3))
    }
}
