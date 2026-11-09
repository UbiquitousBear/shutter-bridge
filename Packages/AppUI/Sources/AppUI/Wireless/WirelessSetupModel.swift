import CameraTransport
import Foundation
import Observation

// What the wireless screens (W16) need from the models beyond what W15 gave them: the Cameras screen's way in to setting
// a Wi-Fi camera up (the pairing and typed-address sheets), and the few values the join's status and the Local Network
// explanation are drawn from. Plain Swift, tested on Linux; the screens only draw these.

/// Lists a camera at an address the person typed. `WiFiCameraSource` in the app, a fake in tests.
public protocol TypedCameraAdding: Sendable {
    /// Remembers the camera at `address` and lists it; the same address again gives the camera already listed.
    func addTypedCamera(_ address: TypedCameraAddress) async -> CameraDescriptor
}

extension WiFiCameraSource: TypedCameraAdding {}

/// Setting a Wi-Fi camera up from the Cameras screen: pairing over Bluetooth (`OnboardingModel`, in a sheet) or typing the
/// camera's address (`TypedAddressModel`, in a sheet). One sheet at a time, made fresh each time it opens, so a new
/// pairing starts at the explanation.
///
/// - Closing the pairing sheet while it waits for the person cancels the check, which closes the Bluetooth link
///   (`OnboardingModel.cancel()`); swiping it down does the same.
/// - A camera that was paired, or added by address, is said once on the Cameras screen (`addedNotice`); discovery lists it
///   by itself (`WiFiCameraSource` sends `.appeared`).
/// - Without a pairing checker (an app model with no wireless parts: `AppModel.wirelessSetup`), `canPair` is false
///   and the screen hides Pair Over Bluetooth rather than greying it out.
///
/// Logs nothing: the models it makes log what they do, never an identifier or an address.
@MainActor
@Observable
public final class WirelessSetupModel {
    public enum Sheet: String, Sendable, Hashable, Identifiable {
        case pairing
        case typedAddress

        public var id: String { rawValue }
    }

    /// The sheet that is up, if any.
    public private(set) var sheet: Sheet?
    /// The pairing's model, made when the pairing sheet opens and kept after it closes (so the sheet doesn't go blank
    /// while it slides away); nil before the first.
    public private(set) var onboarding: OnboardingModel?
    /// The typed-address sheet's model, made when that sheet opens.
    public private(set) var typedAddress: TypedAddressModel?
    /// The camera just added, said once on the Cameras screen; nil once closed or after the next sheet opens.
    public private(set) var addedNotice: StatusNotice?

    @ObservationIgnored private let checker: (any PairingChecking)?
    @ObservationIgnored private let registry: any PairedCameraRegistering
    @ObservationIgnored private let adder: any TypedCameraAdding
    @ObservationIgnored private let log: any BenchLog
    /// Counts the notices, so a second camera added with the same text is said again.
    @ObservationIgnored private var noticeCount = 0

    /// - Parameters:
    ///   - checker: The pairing check over the app's Bluetooth central (`BluetoothPairingChecker`); nil hides pairing.
    ///   - registry: Lists a camera once it is paired (`WiFiCameraSource`).
    ///   - adder: Lists a camera at a typed address (`WiFiCameraSource`).
    public init(checker: (any PairingChecking)?, registry: any PairedCameraRegistering, adder: any TypedCameraAdding,
                log: any BenchLog = SilentBenchLog()) {
        self.checker = checker
        self.registry = registry
        self.adder = adder
        self.log = log
    }

    /// Over the app's Wi-Fi cameras: the source lists both kinds.
    public convenience init(source: WiFiCameraSource, checker: (any PairingChecking)?,
                            log: any BenchLog = SilentBenchLog()) {
        self.init(checker: checker, registry: source, adder: source, log: log)
    }

    /// Whether Pair Over Bluetooth is offered.
    public var canPair: Bool { checker != nil }

    /// Opens the pairing sheet at its explanation. Does nothing without a checker.
    public func showPairing() {
        guard let checker else { return }
        closeCurrent()
        addedNotice = nil
        onboarding = OnboardingModel(checker: checker, registry: registry, log: log)
        sheet = .pairing
    }

    /// Opens the typed-address sheet with an empty field.
    public func showTypedAddress() {
        closeCurrent()
        addedNotice = nil
        typedAddress = TypedAddressModel { [weak self] address in
            await self?.typedAddressAdded(address)
        }
        sheet = .typedAddress
    }

    /// The sheet for `.sheet(item:)`: setting it to nil (the close button, a swipe down) is `close()`. Setting another
    /// sheet opens it.
    public var presentedSheet: Sheet? {
        get { sheet }
        set {
            switch newValue {
            case nil: close()
            case .pairing?: if sheet != .pairing { showPairing() }
            case .typedAddress?: if sheet != .typedAddress { showTypedAddress() }
            }
        }
    }

    /// Closes the sheet that is up. A pairing that was waiting is cancelled; one that finished paired says so.
    public func close() {
        closeCurrent()
    }

    /// Takes the added camera's notice off the screen.
    public func dismissAddedNotice() {
        addedNotice = nil
    }

    private func closeCurrent() {
        guard let open = sheet else { return }
        sheet = nil
        switch open {
        case .pairing:
            guard let onboarding else { return }
            if case .paired = onboarding.step, let camera = onboarding.pairedCamera {
                announceAdded(camera)
            } else {
                // Cancels a check that is waiting (closing the link); otherwise only resets a model nobody shows again.
                onboarding.cancel()
            }
        case .typedAddress:
            break
        }
    }

    private func typedAddressAdded(_ address: TypedCameraAddress) async {
        let camera = await adder.addTypedCamera(address)
        // The camera is listed whether or not the sheet is still up; only the pairing sheet, opened meanwhile, isn't
        // closed or talked over.
        switch sheet {
        case .typedAddress?: sheet = nil
        case nil: break
        case .pairing?: return
        }
        announceAdded(camera)
    }

    private func announceAdded(_ camera: CameraDescriptor) {
        noticeCount += 1
        addedNotice = StatusNotice(id: noticeCount, text: CamerasWording.added(camera), tone: .success,
                                   systemImage: "checkmark.circle", dismissesItself: true)
    }
}

extension WiFiImportModel {
    /// The Local Network explanation as a sheet's `isPresented`: it is up while a connection waits for it, and dismissing
    /// it (a swipe down) is *Not Now*. Continue and Not Now take it down themselves.
    public var showsLocalNetworkExplanation: Bool {
        get { isExplainingLocalNetwork }
        set {
            guard !newValue, isExplainingLocalNetwork else { return }
            declineExplaining()
        }
    }

    /// The join's line for the screens' status (`JoinStatusView`): the wait for iOS's Local Network prompt, else the step
    /// the session is at as the screens say it with the app in front (`WiFiWording.stepInFront(_:)`), else nil. Unlike `statusLine` it leaves out a failure: the screen that
    /// started the connection says why it failed in its own place (Browse's failed state, the Import screen's job line).
    public var activityLine: String? {
        if isExplainingLocalNetwork { return nil }
        if isWaitingForLocalNetwork {
            return localNetworkWaitIsLong ? WiFiWording.stillWaitingForLocalNetwork : WiFiWording.waitingForLocalNetwork
        }
        return WiFiWording.stepInFront(phase)
    }

    /// A spinner goes beside the line while the session is busy getting somewhere: reaching the camera, waiting for iOS's
    /// prompt, or leaving. Not while it stays or waits for the person.
    public var showsActivity: Bool {
        isConnecting || isWaitingForLocalNetwork || phase == .leaving
    }

    /// Whether the status has anything to say about `camera` (the camera in view, `camera`): a line or a note.
    public func hasStatus(for camera: CameraDescriptor.ID?) -> Bool {
        guard let camera, self.camera == camera else { return false }
        return activityLine != nil || !notes.isEmpty
    }

    /// The notes can be closed once the only one left is the one after leaving (the mobile-data note goes by itself when
    /// the phone leaves).
    public var canDismissNotes: Bool { notes == [WiFiWording.wifiMayStayOn] }

    /// The date the stay's countdown counts to, while the phone stays on the camera's network after an import and the
    /// date is still ahead.
    public func stayCountdownEnd(now: Date = Date()) -> Date? {
        guard phase == .staying, let end = stayEndsAt, end > now else { return nil }
        return end
    }
}
