import CameraTransport
import Foundation
import Observation

/// Runs the pairing check for the onboarding (`PairingCheck` over a `GATTConnector`, W5), behind a protocol so the model is
/// tested on Linux against a scripted one.
public protocol PairingChecking: Sendable {
    /// Connects, reads the first protected value with no time limit, and says what happened, with the peripheral's
    /// identifier whenever a link was made. Cancelling the task cancels the wait and closes the link.
    func check(known: PeripheralID?) async -> (PairingOutcome, PeripheralID?)
}

/// `PairingCheck` over the app's Bluetooth connector (`BluetoothCentral`, W10).
public struct BluetoothPairingChecker: PairingChecking {
    private let connector: any GATTConnector
    private let clock: any Clock<Duration>

    public init(connector: any GATTConnector, clock: any Clock<Duration> = ContinuousClock()) {
        self.connector = connector
        self.clock = clock
    }

    public func check(known: PeripheralID?) async -> (PairingOutcome, PeripheralID?) {
        await PairingCheck(clock: clock).run(connector: connector, known: known)
    }
}

/// The Wi-Fi onboarding: pairing the camera over Bluetooth, once (backlog Iteration 3, section 6; wireless plan W15).
///
/// The states (`Step`) are the ones the backlog asks for:
/// - **explain:** what is coming, before anything starts: open MENU › Network › Bluetooth › Pairing on the camera, check
///   *Bluetooth Function* and *Bluetooth Rmt Ctrl*, and that two prompts follow (iOS's pairing request, and the camera's
///   confirmation) and iOS asks for Bluetooth access (`OnboardingWording`).
/// - **waiting:** the first protected read is out and waits for the person, with no time limit (it returned 12.3 s after it
///   was sent on 4 Nov), and *Cancel* is offered. Cancelling cancels the check, which closes the link.
/// - **paired:** the camera is listed (`PairedCameraRegistering`), whether the pairing was just made or iOS already held
///   one (`alreadyPaired`: nothing was confirmed, and the copy says so).
/// - **not paired:** the camera refused the read (insufficient authentication or encryption): the person is sent to the
///   camera's Pairing screen, and *Try Again* runs the check again, once per tap, never in a loop.
/// - **unavailable:** Bluetooth is off or not allowed, the camera wasn't found, the link dropped, or the camera lacks the
///   service; each says what to do next.
///
/// A dropped link is retried once, from a new connection, inside `PairingCheck`, so the model never retries by itself: a
/// second drop is `unavailable(.linkDropped)`. The peripheral the check reached is kept for *Try Again* (it was the same
/// across removing and redoing the pairing), so a retry connects by it instead of scanning.
///
/// The model logs outcomes, never identifiers.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: Sendable, Equatable {
        case explain
        case waiting
        /// `already`: iOS held the pairing before; nothing was confirmed.
        case paired(already: Bool)
        case notPaired
        case unavailable(GATTFailure)
    }

    /// The buttons a screen shows for a step, in order, the first the primary.
    public enum Action: Sendable, Equatable {
        case start
        case cancel
        case tryAgain
        case done
        case openSettings

        public var title: String {
            switch self {
            case .start: OnboardingWording.start
            case .cancel: OnboardingWording.cancel
            case .tryAgain: OnboardingWording.tryAgain
            case .done: OnboardingWording.done
            case .openSettings: OnboardingWording.openSettings
            }
        }
    }

    public private(set) var step: Step = .explain
    /// The camera once it is paired and listed.
    public private(set) var pairedCamera: CameraDescriptor?

    @ObservationIgnored private let checker: any PairingChecking
    @ObservationIgnored private let registry: any PairedCameraRegistering
    @ObservationIgnored private let log: any BenchLog
    @ObservationIgnored private var known: PeripheralID?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false

    /// - Parameters:
    ///   - known: The peripheral of a camera being paired again (from the catalogue), so the check connects by it.
    public init(checker: any PairingChecking, registry: any PairedCameraRegistering, known: PeripheralID? = nil,
                log: any BenchLog = SilentBenchLog()) {
        self.checker = checker
        self.registry = registry
        self.known = known
        self.log = log
    }

    // MARK: - What the screen shows

    public var title: String {
        switch step {
        case .explain: OnboardingWording.explainTitle
        case .waiting: OnboardingWording.waitingTitle
        case let .paired(already): already ? OnboardingWording.alreadyPairedTitle : OnboardingWording.pairedTitle
        case .notPaired: OnboardingWording.notPairedTitle
        case let .unavailable(failure): OnboardingWording.unavailable(failure).title
        }
    }

    public var detail: String {
        switch step {
        case .explain: OnboardingWording.bluetoothPrompt
        case .waiting: OnboardingWording.waitingDetail
        case let .paired(already): already ? OnboardingWording.alreadyPairedDetail : OnboardingWording.pairedDetail
        case .notPaired: OnboardingWording.notPairedDetail
        case let .unavailable(failure): OnboardingWording.unavailable(failure).detail
        }
    }

    /// The numbered steps, while explaining.
    public var steps: [String] { step == .explain ? OnboardingWording.explainSteps : [] }

    public var actions: [Action] {
        switch step {
        case .explain: [.start]
        case .waiting: [.cancel]
        case .paired: [.done]
        case .notPaired: [.tryAgain]
        case .unavailable(.unauthorised): [.openSettings, .tryAgain]
        case .unavailable: [.tryAgain]
        }
    }

    public var isWaiting: Bool { step == .waiting }

    // MARK: - Actions

    /// Starts the pairing check and returns when it has ended (a result, or *Cancel*). Does nothing while one is running or
    /// once the camera is paired. Also what *Try Again* calls.
    public func start() async {
        guard running == nil else { return }
        if case .paired = step { return }
        cancelRequested = false
        step = .waiting
        let task = Task { await self.runCheck() }
        running = task
        // A caller that is cancelled (the screen went away) cancels the check too.
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running = nil
    }

    /// *Cancel* while waiting: stops the check, which closes the link, and goes back to the explanation. In any other
    /// step it goes back to the explanation too.
    public func cancel() {
        if let running {
            cancelRequested = true
            running.cancel()
        } else if step != .explain, !isPaired {
            step = .explain
        }
    }

    /// *Try Again*: the same as `start()`.
    public func tryAgain() async { await start() }

    private var isPaired: Bool {
        if case .paired = step { return true }
        return false
    }

    private func runCheck() async {
        let (outcome, peripheral) = await checker.check(known: known)
        if let peripheral { known = peripheral }
        // The person's Cancel wins over whatever the check answered as it was being cancelled.
        if cancelRequested || Task.isCancelled && outcome == .cancelled {
            log.note("onboarding: cancelled")
            step = .explain
            return
        }
        switch outcome {
        case .alreadyPaired, .paired:
            guard let peripheral else {
                // A pairing without a link to name can't happen; the check says what it can't have.
                step = .unavailable(.timedOut)
                return
            }
            let already = outcome == .alreadyPaired
            pairedCamera = await registry.registerPairedCamera(peripheral: peripheral)
            step = .paired(already: already)
            log.note("onboarding: paired\(already ? " (already)" : "")")
        case .notPaired:
            step = .notPaired
            log.note("onboarding: not paired")
        case .cancelled:
            step = .explain
            log.note("onboarding: cancelled")
        case let .unavailable(failure):
            step = .unavailable(failure)
            log.note("onboarding: unavailable (\(failure))")
        }
    }
}
