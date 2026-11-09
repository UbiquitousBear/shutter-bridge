#if canImport(CoreBluetooth) && os(iOS)
// The central's restore identifier and launch rule, on the real type (W10). Run only by CI's Xcode 27 job, in the iOS
// Simulator. No test here lets the central be made: making a `CBCentralManager` in a test bundle, which has no
// `NSBluetoothAlwaysUsageDescription`, ends the process (iOS's privacy check), so only the paths that make nothing are run.
// The rule itself, every combination, is tested on Linux (`BluetoothRulesTests`). The error mapping is tested on Linux
// against the domain names and codes written out in `CoreBluetoothErrorDomain` and `GATTFailure`; the last suite here checks
// those against the SDK's own constants.

import CoreBluetooth
import Testing
@testable import CameraTransport

@Suite("Bluetooth central at launch")
struct BluetoothCentralLaunchTests {
    @Test func theRestoreIdentifierIsTheOneThePlanFixes() {
        #expect(BluetoothCentral.restoreIdentifier == "net.shamil.shutter-bridge.central")
    }

    @Test(arguments: [BluetoothAuthorisation.notDetermined, .denied, .restricted])
    func withRemindersOffAndNoPermissionNothingIsMadeAtLaunch(_ authorisation: BluetoothAuthorisation) {
        var asked = 0
        let central = BluetoothCentral.makeAtLaunchIfAllowed(remindersOn: false, authorisation: {
            asked += 1
            return authorisation
        })
        #expect(central == nil)
        #expect(asked == 1) // the permission was read through the injected reader
        #expect(!BluetoothCentral.isMade) // so launching can't have shown the permission prompt
    }
}

@Suite("Core Bluetooth error constants")
struct CoreBluetoothErrorConstantsTests {
    @Test func theDomainNamesAreTheSDKs() {
        #expect(CBATTErrorDomain == CoreBluetoothErrorDomain.att)
        #expect(CBErrorDomain == CoreBluetoothErrorDomain.coreBluetooth)
    }

    @Test func theCoreBluetoothCodesAreTheSDKs() {
        #expect(CBError.Code.notConnected.rawValue == GATTFailure.cbNotConnected)
        #expect(CBError.Code.operationCancelled.rawValue == GATTFailure.cbOperationCancelled)
        #expect(CBError.Code.connectionTimeout.rawValue == GATTFailure.cbConnectionTimeout)
        #expect(CBError.Code.peripheralDisconnected.rawValue == GATTFailure.cbPeripheralDisconnected)
        #expect(CBError.Code.connectionFailed.rawValue == GATTFailure.cbConnectionFailed)
        #expect(CBError.Code.peerRemovedPairingInformation.rawValue == GATTFailure.cbPeerRemovedPairingInformation)
        #expect(CBError.Code.encryptionTimedOut.rawValue == GATTFailure.cbEncryptionTimedOut)
    }
}
#endif
