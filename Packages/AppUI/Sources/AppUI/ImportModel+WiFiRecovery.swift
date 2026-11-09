import CameraTransport
import Foundation
import ImportEngine

// The Import model's side of the Wi-Fi recovery (W14; backlog Iteration 3, section 9). Kept out of ImportModel.swift, which
// holds only the hook lines: `refresh()` hands each job state to the coordinator and the scene's return to the front tells it
// the person is back.

extension ImportModel: WiFiRecoveryHost {
    /// Attaches the Wi-Fi recovery, which then follows every job state the model reads. The app (W16) makes one per model and
    /// sets its `session` while a Wi-Fi job runs.
    public func attachWiFiRecovery(_ coordinator: WiFiRecoveryCoordinator) {
        wifiRecovery = coordinator
        coordinator.host = self
    }

    var isAppAway: Bool { isAway }
    var isPausedByPerson: Bool { pausedByPerson }
    var recoveryCarrier: CameraCarrier? { camera?.descriptor.carrier }
    /// The job's files as the camera listed them. For an import of the whole card, the usual one over Wi-Fi, that is the
    /// card, so only handles added since are asked about.
    var recoveryKnownItems: [CameraItem] { snapshot.files.map(\.item) }

    func recoveryRoute() async -> ImportRoute? { await continuingRoute() }
    func recoveryWaitTick() { background.nudge() }

    func recoveryCarriesOn(through link: any CameraLink) async {
        await hold(link)
        await refresh()
    }
}
