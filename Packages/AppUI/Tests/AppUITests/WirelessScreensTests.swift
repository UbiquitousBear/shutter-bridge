import CameraTransport
import Catalogue
import ImportEngine
import Foundation
import Synchronization
import Testing
@testable import AppUI

// W16 (wireless screens): the values the SwiftUI screens are drawn from that the W15/W14/W18 models didn't expose, and the
// copy the screens add. The screens themselves are compiled by CI's Xcode 27 job; everything they decide is here. Every wait
// is bounded (`waitUntilOnMain`, `eventually`, `bounded`).

private let peripheral = PeripheralID(UUID(uuidString: "0A0B0C0D-0E0F-1011-1213-141516171819")!)
private let pairedCamera = CameraDescriptor(id: .init(rawValue: "wifi-paired"), name: "Camera",
                                            mode: .wifi(.cameraNetwork))
private let fixedNow = Date(timeIntervalSince1970: 1_794_000_000)

/// A pairing check that answers at once, or with `waits`, parks until its task is cancelled and answers `.cancelled`.
private final class ScriptedChecker: PairingChecking, Sendable {
    let outcome: PairingOutcome
    let waits: Bool
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }

    init(_ outcome: PairingOutcome = .paired, waits: Bool = false) {
        self.outcome = outcome
        self.waits = waits
    }

    func check(known: PeripheralID?) async -> (PairingOutcome, PeripheralID?) {
        calls.withLock { $0 += 1 }
        if waits {
            // Ends when the task is cancelled: `Task.sleep` throws then. Bounded by the suite's time limit otherwise.
            while (try? await Task.sleep(for: .milliseconds(5))) != nil {}
            return (.cancelled, peripheral)
        }
        return (outcome, peripheral)
    }
}

private final class RecordingRegistry: PairedCameraRegistering, Sendable {
    private let registered = Mutex<[PeripheralID]>([])
    var peripherals: [PeripheralID] { registered.withLock { $0 } }

    func registerPairedCamera(peripheral: PeripheralID) async -> CameraDescriptor {
        registered.withLock { $0.append(peripheral) }
        return pairedCamera
    }
}

private final class RecordingAdder: TypedCameraAdding, Sendable {
    private let added = Mutex<[TypedCameraAddress]>([])
    var addresses: [TypedCameraAddress] { added.withLock { $0 } }

    func addTypedCamera(_ address: TypedCameraAddress) async -> CameraDescriptor {
        let count = added.withLock { list -> Int in
            list.append(address)
            return list.count
        }
        return CameraDescriptor(id: .init(rawValue: "wifi-typed-\(count)"), name: "Camera", mode: .wifi(.otherNetwork))
    }
}

// MARK: - Setting a Wi-Fi camera up

@MainActor
@Suite("Wireless setup model (the Cameras screen's sheets)", .timeLimit(.minutes(1)))
struct WirelessSetupModelTests {
    private func setup(_ checker: ScriptedChecker? = ScriptedChecker(), registry: RecordingRegistry = RecordingRegistry(),
                       adder: RecordingAdder = RecordingAdder()) -> WirelessSetupModel {
        WirelessSetupModel(checker: checker, registry: registry, adder: adder)
    }

    @Test func withoutACheckerPairingIsHiddenAndDoesNothing() {
        let model = setup(nil)
        #expect(!model.canPair)
        model.showPairing()
        #expect(model.sheet == nil)
        #expect(model.onboarding == nil)
        // The typed address is always offered (backlog section 5: "the escape hatch, always offered").
        model.showTypedAddress()
        #expect(model.sheet == .typedAddress)
        #expect(model.typedAddress != nil)
    }

    @Test func pairingOpensAtTheStepsAndAPairedCameraIsSaidWhenItCloses() async {
        let registry = RecordingRegistry()
        let model = setup(registry: registry)
        #expect(model.canPair)
        model.showPairing()
        #expect(model.sheet == .pairing)
        let first = try! #require(model.onboarding)
        #expect(first.step == .explain)
        await first.start()
        #expect(first.step == .paired(already: false))
        #expect(registry.peripherals == [peripheral])
        #expect(model.addedNotice == nil)   // said once the sheet closes, not over it

        model.close()   // Done
        #expect(model.sheet == nil)
        let notice = try! #require(model.addedNotice)
        #expect(notice.text == CamerasWording.added(pairedCamera))
        #expect(notice.tone == .success)
        #expect(notice.dismissesItself)

        // Opening it again starts over, at the steps, with a model of its own; the old notice goes.
        model.showPairing()
        let second = try! #require(model.onboarding)
        #expect(second !== first)
        #expect(second.step == .explain)
        #expect(model.addedNotice == nil)
    }

    @Test func closingWhileWaitingCancelsTheCheck() async {
        let checker = ScriptedChecker(waits: true)
        let model = setup(checker)
        model.showPairing()
        let onboarding = try! #require(model.onboarding)
        let run = Task { @MainActor in await onboarding.start() }
        #expect(await waitUntilOnMain { onboarding.isWaiting && checker.count == 1 })
        model.presentedSheet = nil   // a swipe down, or the close button
        #expect(await bounded(run) != nil)
        #expect(model.sheet == nil)
        #expect(onboarding.step == .explain)
        #expect(model.addedNotice == nil)
    }

    @Test func closingANotPairedSheetSaysNothing() async {
        let model = setup(ScriptedChecker(.notPaired))
        model.showPairing()
        let onboarding = try! #require(model.onboarding)
        await onboarding.start()
        #expect(onboarding.step == .notPaired)
        model.close()
        #expect(model.addedNotice == nil)
    }

    @Test func aTypedAddressIsAddedTheSheetClosesAndTheCameraIsSaid() async {
        let adder = RecordingAdder()
        let model = setup(adder: adder)
        model.presentedSheet = .typedAddress
        #expect(model.sheet == .typedAddress)
        let typed = try! #require(model.typedAddress)
        typed.text = "10.0.0.12"
        #expect(await typed.add())
        #expect(adder.addresses.map(\.host) == ["10.0.0.12"])
        #expect(model.sheet == nil)
        #expect(model.addedNotice?.text == CamerasWording.added(pairedCamera))   // "Camera added. …" either way
        let firstID = model.addedNotice?.id

        model.showTypedAddress()
        let again = try! #require(model.typedAddress)
        #expect(again !== typed)
        #expect(again.text.isEmpty)
        again.text = "camera.local:15741"
        #expect(await again.add())
        #expect(model.addedNotice?.id != firstID)   // a second camera is said again
        model.dismissAddedNotice()
        #expect(model.addedNotice == nil)
    }

    @Test func textThatIsntAnAddressAddsNothingAndKeepsTheSheet() async {
        let adder = RecordingAdder()
        let model = setup(adder: adder)
        model.showTypedAddress()
        let typed = try! #require(model.typedAddress)
        for text in ["http://10.0.0.12", "192.168.122.1", "", "10.0.0"] {
            typed.text = text
            #expect(!(await typed.add()), "\(text)")
        }
        #expect(adder.addresses.isEmpty)
        #expect(model.sheet == .typedAddress)
        #expect(model.addedNotice == nil)
    }

    @Test func switchingSheetsClosesTheFirst() async {
        let checker = ScriptedChecker(waits: true)
        let model = setup(checker)
        model.showPairing()
        let onboarding = try! #require(model.onboarding)
        let run = Task { @MainActor in await onboarding.start() }
        #expect(await waitUntilOnMain { onboarding.isWaiting })
        model.presentedSheet = .typedAddress
        #expect(model.sheet == .typedAddress)
        #expect(await bounded(run) != nil)   // the pairing's wait was cancelled
        #expect(onboarding.step == .explain)
    }
}

// MARK: - The join's status and the Local Network explanation

@MainActor
@Suite("Wi-Fi status as the screens draw it", .timeLimit(.minutes(1)))
struct WiFiStatusScreenTests {
    private let cam = CameraDescriptor.ID(rawValue: "wifi-a")
    private let otherCam = CameraDescriptor.ID(rawValue: "wifi-b")

    private func model(explained: Bool = false) -> (WiFiImportModel, InMemoryLocalNetworkExplainedRecord) {
        let record = InMemoryLocalNetworkExplainedRecord(hasExplained: explained)
        let model = WiFiImportModel(source: FakeConnectionSource(), record: record, clock: WiFiTestClock(),
                                    now: { fixedNow })
        return (model, record)
    }

    @Test func swipingTheExplanationAwayIsNotNow() async {
        let (model, record) = model()
        #expect(!model.showsLocalNetworkExplanation)
        model.showsLocalNetworkExplanation = true   // nothing to show: does nothing
        #expect(!model.isExplainingLocalNetwork)
        let gate = Task { @MainActor in await model.beforeFirstConnection() }
        #expect(await waitUntilOnMain { model.showsLocalNetworkExplanation })
        model.showsLocalNetworkExplanation = false
        #expect(await bounded(gate) == false)
        #expect(!record.hasExplained)
        #expect(!model.showsLocalNetworkExplanation)
        model.showsLocalNetworkExplanation = false   // again: nothing happens
        #expect(!model.isExplainingLocalNetwork)
    }

    @Test func continueTakesTheSheetDownWithoutCountingAsNotNow() async {
        let (model, record) = model()
        let gate = Task { @MainActor in await model.beforeFirstConnection() }
        #expect(await waitUntilOnMain { model.showsLocalNetworkExplanation })
        model.continueAfterExplaining()
        // SwiftUI may write false back as the sheet goes; the connection still goes on.
        model.showsLocalNetworkExplanation = false
        #expect(await bounded(gate) == true)
        #expect(record.hasExplained)
    }

    @Test func theJoinIsShownWithASpinnerAndTheMobileDataNote() {
        let (model, _) = model(explained: true)
        model.apply(.connecting(cam))
        #expect(!model.hasStatus(for: cam))   // idle: nothing to say yet
        model.apply(.phase(cam, .handingOff, stayRemaining: nil))
        #expect(model.activityLine == WiFiWording.step(.handingOff))
        #expect(model.showsActivity)
        #expect(model.notes.isEmpty)
        model.apply(.phase(cam, .joining, stayRemaining: nil))
        #expect(model.activityLine == WiFiWording.step(.joining))
        #expect(model.notes == [WiFiWording.mobileDataNote])
        #expect(model.hasStatus(for: cam))
        #expect(!model.hasStatus(for: otherCam))
        #expect(!model.hasStatus(for: nil))
        #expect(!model.canDismissNotes)
        model.apply(.link(cam, .waitingForLocalNetwork))
        #expect(model.activityLine == WiFiWording.waitingForLocalNetwork)
        #expect(model.showsActivity)
        model.apply(.phase(cam, .ready, stayRemaining: nil))
        #expect(model.activityLine == nil)   // connected: the screen shows the card or the import
        #expect(!model.showsActivity)
        #expect(model.notes == [WiFiWording.mobileDataNote])
    }

    @Test func aFailureIsLeftToTheScreenThatStartedTheConnection() {
        let (model, _) = model(explained: true)
        model.apply(.connecting(cam))
        model.apply(.phase(cam, .handingOff, stayRemaining: nil))
        model.apply(.failed(cam, .cameraNotFound))
        model.apply(.phase(cam, .idle, stayRemaining: nil))
        #expect(model.statusLine == WiFiWording.failure(.cameraNotFound))
        #expect(model.activityLine == nil)
        #expect(!model.hasStatus(for: cam))
    }

    @Test func aPauseForThePersonIsShownWithoutASpinner() {
        let (model, _) = model(explained: true)
        model.apply(.connecting(cam))
        model.apply(.phase(cam, .paused(.bluetoothOff), stayRemaining: nil))
        #expect(model.activityLine == WiFiWording.paused(.bluetoothOff))
        #expect(!model.showsActivity)
        #expect(model.hasStatus(for: cam))
    }

    /// The screens show only in front: a pause for a join leaves the Import summary to say Try Again, and a declined
    /// join says to try again, neither "open Shutter Bridge" nor "open the camera again".
    @Test func inFrontAJoinPauseDoesntSayOpenTheApp() {
        let (model, _) = model(explained: true)
        model.apply(.connecting(cam))
        model.apply(.phase(cam, .paused(.needsJoin), stayRemaining: nil))
        #expect(model.activityLine == nil)
        #expect(!model.hasStatus(for: cam))
        model.apply(.phase(cam, .paused(.joinDeclined), stayRemaining: nil))
        let declined = model.activityLine
        #expect(declined == WiFiWording.stepInFront(.paused(.joinDeclined)))
        #expect(declined?.contains("Try again") == true)
        #expect(declined?.contains("Open the camera") == false)
        #expect(declined?.contains("Open Shutter Bridge") == false)
    }

    @Test func theStayCountsDownAndTheNoteAfterLeavingCanBeClosed() {
        let (model, _) = model(explained: true)
        model.apply(.connecting(cam))
        model.apply(.phase(cam, .ready, stayRemaining: nil))
        #expect(model.stayCountdownEnd(now: fixedNow) == nil)
        model.apply(.phase(cam, .staying, stayRemaining: .seconds(180)))
        #expect(model.activityLine == WiFiWording.stay)
        #expect(!model.showsActivity)
        #expect(model.stayCountdownEnd(now: fixedNow) == fixedNow.addingTimeInterval(180))
        #expect(model.stayCountdownEnd(now: fixedNow.addingTimeInterval(180)) == nil)   // over: no 0:00 left showing
        model.apply(.phase(cam, .leaving, stayRemaining: nil))
        #expect(model.showsActivity)
        #expect(model.stayCountdownEnd(now: fixedNow) == nil)
        model.apply(.phase(cam, .idle, stayRemaining: nil))
        #expect(model.notes == [WiFiWording.wifiMayStayOn])
        #expect(model.canDismissNotes)
        #expect(model.hasStatus(for: cam))
        model.dismissNotes()
        #expect(!model.hasStatus(for: cam))
        #expect(!model.canDismissNotes)
    }
}

// MARK: - The Cameras screen: keys, the nearby badge and a reminder's camera

@MainActor
@Suite("Cameras model for the wireless screens", .timeLimit(.minutes(1)))
struct CamerasWirelessTests {
    private let a = CameraDescriptor(id: .init(rawValue: "wifi-a"), name: "ILCE-7CM2", mode: .wifi(.cameraNetwork))
    private let b = CameraDescriptor(id: .init(rawValue: "wifi-b"), name: "Camera", mode: .wifi(.cameraNetwork))
    private let usb = CameraDescriptor(id: .init(rawValue: "usb"), name: "Untitled", mode: .usb(.massStorage))
    private let keyA = CameraKey(rawValue: "wifi-serial:aaaa")
    private let keyB = CameraKey(rawValue: "wifi-serial:bbbb")

    @Test func keysAreReadAsCamerasAppearAndForgottenWhenTheyGo() async {
        let discovery = ScriptedDiscovery()
        await discovery.set(key: keyA, for: a.id)
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        await discovery.send(.appeared(a))
        await discovery.send(.appeared(b))
        await discovery.send(.appeared(usb))
        #expect(await eventually { model.cameras.count == 3 && model.knownKeys[a.id] == keyA })
        #expect(model.knownKeys[b.id] == nil)
        #expect(model.knownKeys[usb.id] == nil)

        #expect(model.isNearby(a) { $0 == keyA })
        #expect(!model.isNearby(a) { _ in false })
        // Unknown is not nearby: no key, no badge, whatever the scan says.
        #expect(!model.isNearby(b) { _ in true })
        #expect(!model.isNearby(usb) { _ in true })

        await discovery.send(.disappeared(a.id))
        #expect(await eventually { model.cameras.count == 2 })
        #expect(model.knownKeys[a.id] == nil)
    }

    @Test func aKeyLearntAtTheFirstSessionIsPickedUpWhenTheAppIsActive() async {
        let discovery = ScriptedDiscovery()
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        await discovery.send(.appeared(b))
        #expect(await eventually { model.cameras.count == 1 })
        #expect(model.knownKeys.isEmpty)
        await discovery.set(key: keyB, for: b.id)
        await model.becameActive()
        #expect(model.knownKeys[b.id] == keyB)
    }

    @Test func aRemindersCameraIsOpenedOnceItIsListedWithItsKey() async {
        let discovery = ScriptedDiscovery()
        await discovery.set(key: keyA, for: a.id)
        let model = CamerasModel(discovery: discovery, services: services())
        await model.becameActive()
        #expect(!model.showCamera(withKey: keyA))   // not listed yet: the request is kept by the caller
        #expect(model.path.isEmpty)
        await discovery.send(.appeared(a))
        #expect(await eventually { model.knownKeys[a.id] == keyA })
        #expect(model.showCamera(withKey: keyA))
        #expect(model.path == [a])
        #expect(model.showCamera(withKey: keyA))   // already browsed: left as it is
        #expect(model.path == [a])
        #expect(!model.showCamera(withKey: keyB))
        #expect(model.path == [a])
    }

    @Test func aWiFiRowNeverShowsBatteryOrFreeSpace() {
        let model = CamerasModel(discovery: ScriptedDiscovery(), services: services())
        #expect(model.deviceStatusLines(for: a, batteryPercent: 80, freeBytes: 1_000_000).isEmpty)
        #expect(model.deviceStatusLines(for: a).isEmpty)
        // Over USB a value nobody read is left out, never shown as 0.
        #expect(model.deviceStatusLines(for: usb).isEmpty)
        #expect(model.deviceStatusLines(for: usb, batteryPercent: 0).first == "Battery 0%")
    }
}

// MARK: - The copy the wireless screens add

@Suite("Wireless screens' wording")
struct WirelessScreensWordingTests {
    @Test func thePairingStepsNameThePathBothSettingsAndTheTwoPromptsInOrder() {
        let steps = OnboardingWording.explainSteps
        #expect(steps.count == 3)
        #expect(steps[0].contains("MENU › Network › Bluetooth › Pairing"))
        #expect(steps[1].contains("Bluetooth Function") && steps[1].contains("Bluetooth Rmt Ctrl"))
        let prompts = steps[2]
        #expect(prompts.contains("Two prompts"))
        let bluetooth = try! #require(prompts.range(of: "Bluetooth"))
        let camera = try! #require(prompts.range(of: "the camera asks"))
        #expect(bluetooth.lowerBound < camera.lowerBound)   // iOS's Bluetooth request first, then the camera's confirmation
    }

    @Test func theCamerasConfirmationIsQuotedOnlyOnceItIsKnown() {
        // The placeholder (B:144): until Shamil reads the camera's wording, the copy doesn't guess it.
        let unknown = OnboardingWording.steps(cameraConfirmation: nil)[2]
        #expect(unknown.contains("the camera asks you to confirm"))
        #expect(!unknown.contains("\u{2018}"))
        let known = OnboardingWording.steps(cameraConfirmation: "Pair with this device?")[2]
        #expect(known.contains("the camera asks \u{2018}Pair with this device?\u{2019}"))
        #expect(OnboardingWording.explainSteps == OnboardingWording.steps(
            cameraConfirmation: OnboardingWording.cameraConfirmationWording))
    }

    @Test func eachCameraRowSaysHowItIsReachedAndWhatOpeningItDoes() {
        #expect(CamerasWording.detailLine(.usb(.massStorage)) == CamerasWording.modeLine(.usb(.massStorage)))
        #expect(CamerasWording.detailLine(.usb(.mtp)) == CamerasWording.modeLine(.usb(.mtp)))
        #expect(CamerasWording.detailLine(.wifi(.cameraNetwork)) != CamerasWording.detailLine(.wifi(.otherNetwork)))
        for route in WiFiRoute.allCases {
            #expect(!CamerasWording.detailLine(.wifi(route)).contains("USB"))
            #expect(CamerasWording.badge(for: .wifi(route)) == CamerasWording.wifiBadge)
        }
        var hints = Set<String>()
        for mode in [CameraMode.usb(.massStorage), .wifi(.cameraNetwork), .wifi(.otherNetwork)] {
            hints.insert(CamerasWording.rowHint(mode))
        }
        #expect(hints.count == 3)
    }

    @Test func aCameraAddedIsNamedUnlessItIsJustCamera() {
        let generic = CameraDescriptor(id: .init(rawValue: "x"), name: "Camera", mode: .wifi(.cameraNetwork))
        let named = CameraDescriptor(id: .init(rawValue: "y"), name: "Studio body", mode: .wifi(.otherNetwork))
        #expect(CamerasWording.added(generic) == "Camera added. Tap it to open its card.")
        #expect(CamerasWording.added(named) == "Studio body added. Tap it to open its card.")
    }

    @Test func theNewCopyIsBritishHasNoMakersMarksAndEndsLinesWithAFullStop() {
        let sentences = [
            CamerasWording.addWiFiCameraHint, CamerasWording.addWiFiCameraByAddressHint, CamerasWording.wifiEmptyHint,
            ImportWording.needsJoinInFront, WiFiWording.stepInFront(.paused(.joinDeclined)) ?? "",
            ImportWording.tryAgainHint, WiFiWording.dismissNotesHint, WiFiWording.localNetworkContinueHint,
            WiFiWording.localNetworkNotNowHint, SettingsWording.remindersHint, OnboardingWording.startHint,
            OnboardingWording.cancelHint, OnboardingWording.tryAgainHint, OnboardingWording.openSettingsHint,
            OnboardingWording.doneHint, TypedAddressWording.connectHint,
        ] + WiFiRoute.allCases.map { CamerasWording.rowHint(.wifi($0)) }
            + PauseReason.allCases.map { ImportWording.pausedTryAgain($0) }
        for line in sentences {
            #expect(line.hasSuffix("."), "\(line)")
        }
        let titles = [CamerasWording.addWiFiCamera, CamerasWording.pairOverBluetooth, CamerasWording.typeAddress,
                      CamerasWording.nearbyBadge, ImportWording.tryAgain]
        let small: Set<String> = ["a", "an", "the", "of", "to", "for", "with", "over"]
        for title in titles {
            for (index, word) in title.split(separator: " ").enumerated()
            where index == 0 || !small.contains(String(word)) {
                #expect(word.first?.isUppercase == true, "\(title)")
            }
        }
        for line in sentences + titles + OnboardingWording.explainSteps {
            #expect(!line.lowercased().contains("sony"), "\(line)")
            #expect(!line.contains("color") && !line.contains("behavior") && !line.contains("catalog "), "\(line)")
        }
        #expect(OnboardingWording.stepLabel(2, of: 3, "Check.") == "Step 2 of 3. Check.")
        #expect(SettingsWording.remindersValue(on: true) == "On" && SettingsWording.remindersValue(on: false) == "Off")
        // In front the pause names its next step, Try Again, and doesn't ask to open the app the person is in.
        #expect(ImportWording.needsJoinInFront.contains("Try Again"))
        #expect(!ImportWording.needsJoinInFront.contains("open Shutter Bridge"))
        // Once the recovery has given up, only Try Again carries the job on, so its lines end with it.
        for reason in [PauseReason.cameraUnreachable, .cardUnavailable] {
            #expect(ImportWording.pausedTryAgain(reason).hasSuffix("then tap Try Again."))
            #expect(!ImportWording.pausedTryAgain(reason).contains("by itself"))
        }
        #expect(ImportWording.pausedTryAgain(.needsJoin) == ImportWording.needsJoinInFront)
    }
}
