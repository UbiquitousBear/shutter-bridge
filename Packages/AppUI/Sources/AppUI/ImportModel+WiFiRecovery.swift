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
        wifiRecoveryPhase = coordinator.plan.phase
        coordinator.onPhaseChanged = { [weak self] phase in self?.wifiRecoveryPhase = phase }
    }

    /// What the Import screen offers for a Wi-Fi job the recovery is getting back, or waiting on the person for (W16).
    public enum WiFiRecoveryControl: Sendable, Hashable {
        /// The recovery is reaching the camera by itself: a spinner and a line, no button.
        case reconnecting
        /// The recovery gave up, or waits for a join it couldn't make from where it was: *Try Again*.
        case tryAgain
    }

    /// Nil unless a Wi-Fi job with a recovery and a session attached is paused for its camera, its card or a join: hidden
    /// rather than greyed out when it doesn't apply.
    public var wifiRecoveryControl: WiFiRecoveryControl? {
        guard camera?.descriptor.carrier == .wifi, let wifiRecovery, wifiRecovery.session != nil,
              case let .paused(reason) = state else { return nil }
        switch reason {
        case .needsJoin, .cameraUnreachable, .cardUnavailable: break
        case .appInBackground, .stalled, .byPerson, .taskExpired, .cameraRemoved: return nil
        }
        switch wifiRecoveryPhase {
        case .waitingForCard, .reopening, .relisting: return .reconnecting
        case .idle, .pausedForJoin, .gaveUp: return .tryAgain
        }
    }

    /// *Try Again* on the Import screen: the recovery runs again from the front (`WiFiRecoveryCoordinator.tryAgain()`).
    /// Does nothing when the screen offers no Try Again.
    public func tryAgainWiFi() {
        guard wifiRecoveryControl == .tryAgain else { return }
        wifiRecovery?.tryAgain()
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
