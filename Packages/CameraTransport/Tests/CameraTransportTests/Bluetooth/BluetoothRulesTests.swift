// The central's rules that need no Core Bluetooth (W10): the launch rule, the timings, the order in which the camera is looked
// for, the scan's match, and the mapping of the framework's states and errors. No identifier here is a camera's.

import BLEKit
import Foundation
import Testing
@testable import CameraTransport

@Suite("Bluetooth central rules")
struct BluetoothRulesTests {
    // MARK: Launch

    @Test(arguments: [BluetoothAuthorisation.notDetermined, .restricted, .denied, .allowedAlways])
    func withRemindersOnTheCentralIsMadeAtLaunch(_ authorisation: BluetoothAuthorisation) {
        #expect(BluetoothLaunchRule.createsCentralAtLaunch(remindersOn: true, authorisation: authorisation))
    }

    @Test func withRemindersOffOnlyAnAllowedAppMakesTheCentralAtLaunch() {
        #expect(BluetoothLaunchRule.createsCentralAtLaunch(remindersOn: false, authorisation: .allowedAlways))
        // Making a central before the person has been asked would show the permission prompt at launch.
        #expect(!BluetoothLaunchRule.createsCentralAtLaunch(remindersOn: false, authorisation: .notDetermined))
        #expect(!BluetoothLaunchRule.createsCentralAtLaunch(remindersOn: false, authorisation: .denied))
        #expect(!BluetoothLaunchRule.createsCentralAtLaunch(remindersOn: false, authorisation: .restricted))
    }

    // MARK: Power

    @Test func powerStatesSayWhatACallFailsWith() {
        #expect(BluetoothPower.poweredOn.failure == nil)
        #expect(BluetoothPower.unknown.failure == nil) // wait for it to settle
        #expect(BluetoothPower.resetting.failure == nil) // wait for it to settle
        #expect(BluetoothPower.poweredOff.failure == .bluetoothOff)
        #expect(BluetoothPower.unauthorised.failure == .unauthorised)
        #expect(BluetoothPower.unsupported.failure == .bluetoothOff) // the Simulator
    }

    @Test func aLinkUnderAPowerChangeDropsForTheRightReason() {
        #expect(BluetoothPower.resetting.dropReason == .linkDropped)
        #expect(BluetoothPower.poweredOff.dropReason == .bluetoothOff)
        #expect(BluetoothPower.unauthorised.dropReason == .unauthorised)
    }

    @Test func thePowerWaitHasNoLimitWhileThePermissionPromptIsUp() {
        #expect(BluetoothTiming.powerWait(authorisation: .notDetermined) == nil)
        #expect(BluetoothTiming.powerWait(authorisation: .allowedAlways) == .seconds(30))
        #expect(BluetoothTiming.powerWait(authorisation: .denied) == .seconds(30))
    }

    @Test func theTimingsAreTheSpikesLimits() {
        #expect(BluetoothTiming.powerOn == .seconds(30))
        #expect(BluetoothTiming.connectKnown == .seconds(8))
        #expect(BluetoothTiming.connect == .seconds(20))
        #expect(BluetoothTiming.scan == .seconds(10))
        #expect(BluetoothTiming.discovery == .seconds(15))
        #expect(BluetoothTiming.disconnectGrace == .seconds(2))
    }

    // MARK: Connect order

    private static let camera = UUID()
    private static let other = UUID()

    @Test func aStoredIdentifierNotConnectedToTheSystemGetsAShortGo() {
        let attempts = BluetoothConnectPlan.attempts(
            storedIdentifier: [.init(id: Self.camera, name: "ILCE-7CM2")], connectedToSystem: [])
        #expect(attempts == [.init(peripheral: Self.camera, route: .storedIdentifier, timeout: .seconds(8))])
    }

    @Test func aStoredIdentifierThatIsConnectedToTheSystemGetsTheFullTime() {
        let attempts = BluetoothConnectPlan.attempts(
            storedIdentifier: [.init(id: Self.camera, name: "ILCE-7CM2")],
            connectedToSystem: [.init(id: Self.camera, name: "ILCE-7CM2")])
        // Tried once, by the stored identifier, not again as a system connection.
        #expect(attempts == [.init(peripheral: Self.camera, route: .storedIdentifier, timeout: .seconds(20))])
    }

    @Test func aDifferentSystemConnectionIsTriedAfterTheStoredIdentifier() {
        let attempts = BluetoothConnectPlan.attempts(
            storedIdentifier: [.init(id: Self.camera, name: nil)],
            connectedToSystem: [.init(id: Self.other, name: "ILCE-7CM2")])
        #expect(attempts == [
            .init(peripheral: Self.camera, route: .storedIdentifier, timeout: .seconds(8)),
            .init(peripheral: Self.other, route: .connectedToSystem, timeout: .seconds(20)),
        ])
    }

    @Test func withoutAStoredIdentifierTheCameraAmongTheSystemsConnectionsIsPreferred() {
        let attempts = BluetoothConnectPlan.attempts(
            storedIdentifier: [],
            connectedToSystem: [.init(id: Self.other, name: "Watch"), .init(id: Self.camera, name: "ILCE-7CM2")])
        #expect(attempts == [.init(peripheral: Self.camera, route: .connectedToSystem, timeout: .seconds(20))])
    }

    @Test func withNothingRetrievedTheConnectGoesStraightToTheScan() {
        #expect(BluetoothConnectPlan.attempts(storedIdentifier: [], connectedToSystem: []).isEmpty)
    }

    @Test func preferCameraTakesACamerasNameElseTheFirst() {
        let unnamed = BluetoothConnectPlan.Candidate(id: Self.other, name: nil)
        let named = BluetoothConnectPlan.Candidate(id: Self.camera, name: "ilce-7cm2")
        #expect(BluetoothConnectPlan.preferCamera([unnamed, named]) == named)
        #expect(BluetoothConnectPlan.preferCamera([unnamed]) == unnamed)
        #expect(BluetoothConnectPlan.preferCamera([]) == nil)
    }

    // MARK: Scan match

    /// Sony's company ID, little-endian, and 20 bytes of payload (all zero: no real advertisement is in a test).
    private static let sonyData = Data([0x2D, 0x01] + [UInt8](repeating: 0, count: 20))

    @Test func theScanMatchesSonysCompanyAndACamerasName() {
        #expect(BluetoothConnectPlan.scanMatches(manufacturerData: Self.sonyData, name: "ILCE-7CM2"))
    }

    @Test func theScanIgnoresAnythingElse() {
        // Another company with a camera's name.
        #expect(!BluetoothConnectPlan.scanMatches(manufacturerData: Data([0x4C, 0x00, 0x01]), name: "ILCE-7CM2"))
        // Sony, but not named like a camera (headphones, say).
        #expect(!BluetoothConnectPlan.scanMatches(manufacturerData: Self.sonyData, name: "WH-1000XM5"))
        #expect(!BluetoothConnectPlan.scanMatches(manufacturerData: Self.sonyData, name: nil))
        // No manufacturer data, or too little for a company ID.
        #expect(!BluetoothConnectPlan.scanMatches(manufacturerData: nil, name: "ILCE-7CM2"))
        #expect(!BluetoothConnectPlan.scanMatches(manufacturerData: Data([0x2D]), name: "ILCE-7CM2"))
    }

    // MARK: Errors

    @Test func errorsAreMappedByTheirDomain() {
        #expect(GATTFailure.classify(domain: "CBATTErrorDomain", code: 0x0F, reading: .status) == .notPaired)
        #expect(GATTFailure.classify(domain: "CBATTErrorDomain", code: 0x9D, reading: .ssid) == .wifiOff)
        #expect(GATTFailure.classify(domain: "CBErrorDomain", code: 7, reading: nil) == .linkDropped)
        #expect(GATTFailure.classify(domain: "CBErrorDomain", code: 0, reading: nil) == .other(0))
        // The domain decides: 7 from the camera is an ATT code, not "peripheral disconnected".
        #expect(GATTFailure.classify(domain: "CBATTErrorDomain", code: 7, reading: nil) == .other(7))
        // CBInternalErrorDomain 13: the link that dropped by itself after a join (5 Nov 02:21).
        #expect(GATTFailure.classify(domain: "CBInternalErrorDomain", code: 13, reading: nil) == .other(13))
    }

    @Test func aDropIsLinkDroppedUnlessThePairingIsGone() {
        #expect(GATTFailure.dropReason(domain: nil, code: nil) == .linkDropped)
        #expect(GATTFailure.dropReason(domain: "CBErrorDomain", code: 7) == .linkDropped) // peripheralDisconnected
        #expect(GATTFailure.dropReason(domain: "CBErrorDomain", code: 6) == .linkDropped) // connectionTimeout
        #expect(GATTFailure.dropReason(domain: "CBInternalErrorDomain", code: 13) == .linkDropped)
        #expect(GATTFailure.dropReason(domain: "CBErrorDomain", code: 14) == .notPaired) // peerRemovedPairingInformation
    }

    // MARK: Value routing

    @Test func aValueAnswersTheWaitingReadFirst() {
        #expect(GATTValueRoute.route(readWaiting: true, characteristic: .status, isNotifying: true, hasError: false) == .answerRead)
        #expect(GATTValueRoute.route(readWaiting: true, characteristic: .ssid, isNotifying: false, hasError: true) == .answerRead)
    }

    @Test func otherwiseOnlyANotifyingCharacteristicMakesANotification() {
        #expect(GATTValueRoute.route(readWaiting: false, characteristic: .status, isNotifying: true, hasError: false) == .notification)
        #expect(GATTValueRoute.route(readWaiting: false, characteristic: .status, isNotifying: false, hasError: false) == .ignore)
        #expect(GATTValueRoute.route(readWaiting: false, characteristic: .status, isNotifying: true, hasError: true) == .ignore)
        #expect(GATTValueRoute.route(readWaiting: false, characteristic: nil, isNotifying: true, hasError: false) == .ignore)
    }

    @Test func aLateNetworkDetailNeverReachesANotificationStream() {
        for secret in CameraControlCharacteristic.secret {
            #expect(GATTValueRoute.route(readWaiting: false, characteristic: secret, isNotifying: false, hasError: false) == .ignore)
            #expect(GATTValueRoute.route(readWaiting: false, characteristic: secret, isNotifying: true, hasError: false) == .ignore)
        }
    }
}
