// Sony's five notification switches, turned on before the hand-off and off again at the end.

import BLEKit

/// What `NotificationSwitches.turnOff` found, per characteristic.
public struct ReleaseReport: Sendable, Equatable {
    /// Confirmed off by iOS.
    public var turnedOff: [CameraControlCharacteristic] = []
    /// Core Bluetooth answered "unknown" while iOS lists another app's link to the camera: iOS shares one link and one set of
    /// switches between the apps, so this is harmless (measured with Creators' App: only CC0E confirmed, the other four
    /// came back "unknown", and Creators' App still worked; backlog section 7).
    public var leftOnHarmlessly: [CameraControlCharacteristic] = []
    /// Anything else. Best effort: the caller closes the link either way.
    public var failed: [CameraControlCharacteristic: GATTFailure] = [:]
    /// Not tried, because the link had dropped or the task was cancelled.
    public var notTried: [CameraControlCharacteristic] = []

    public init() {}
}

enum NotificationSwitches {
    /// Turns Sony's five notifications on, in the spike's order (`sonyNotificationSet`: CC09, CC10, CC0F, CC03, CC0E), each
    /// confirmed. A switch that isn't confirmed in time, or that fails with an error that says nothing about the link, is
    /// returned rather than thrown: the spike carried on with the next code (`doSubscribe`), and CC09 can be read instead.
    /// A failure that ends the link or means the phone isn't paired is thrown.
    ///
    /// - Returns: the switches that were not confirmed.
    static func turnOn(_ link: any GATTLink) async throws(GATTFailure) -> [CameraControlCharacteristic] {
        var unconfirmed: [CameraControlCharacteristic] = []
        for characteristic in CameraControlCharacteristic.sonyNotificationSet {
            do throws(GATTFailure) {
                try await link.setNotify(true, characteristic, timeout: HandoffTiming.subscribeEach)
            } catch {
                switch error {
                case .timedOut, .other: unconfirmed.append(characteristic)
                default: throw error
                }
            }
        }
        return unconfirmed
    }

    /// Turns the five off, one at a time, each with `HandoffTiming.unsubscribeEach`. A bonded camera may keep a client's
    /// switches across links, which is why the app turns them off itself instead of leaving it to the link closing.
    static func turnOff(_ link: any GATTLink) async -> ReleaseReport {
        var report = ReleaseReport()
        let set = CameraControlCharacteristic.sonyNotificationSet
        for (index, characteristic) in set.enumerated() {
            do throws(GATTFailure) {
                try await link.setNotify(false, characteristic, timeout: HandoffTiming.unsubscribeEach)
                report.turnedOff.append(characteristic)
            } catch {
                switch error {
                case .linkDropped, .cancelled:
                    report.notTried += set[index...]
                    return report
                case .other(0) where link.anotherAppHoldsLink:
                    report.leftOnHarmlessly.append(characteristic)
                default:
                    report.failed[characteristic] = error
                }
            }
        }
        return report
    }
}
