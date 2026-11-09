import CameraTransport
import Foundation
import Synchronization
import Testing
@testable import AppUI

private let peripheralA = PeripheralID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
private let peripheralB = PeripheralID(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!)

/// A pairing check that answers as scripted. With `waits`, it parks until its task is cancelled (or `release()`), and
/// then answers `.cancelled`, as `PairingCheck` does; with `ignoresCancel` it answers its script even when cancelled.
private final class FakeChecker: PairingChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [(PairingOutcome, PeripheralID?)]
    private var knowns: [PeripheralID?] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waits = false
    var ignoresCancel = false

    init(_ scripted: [(PairingOutcome, PeripheralID?)] = []) { self.scripted = scripted }

    var calls: Int { lock.withLock { knowns.count } }
    var knownPassed: [PeripheralID?] { lock.withLock { knowns } }

    func check(known: PeripheralID?) async -> (PairingOutcome, PeripheralID?) {
        lock.withLock { knowns.append(known) }
        if waits {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                        lock.unlock()
                    }
                }
            } onCancel: {
                release()
            }
            if Task.isCancelled, !ignoresCancel { return (.cancelled, peripheralA) }
        }
        return lock.withLock { scripted.count > 1 ? scripted.removeFirst() : scripted[0] }
    }

    func release() {
        let parked = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        for continuation in parked { continuation.resume() }
    }
}

private final class FakeRegistry: PairedCameraRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var registered: [PeripheralID] = []
    var peripherals: [PeripheralID] { lock.withLock { registered } }

    func registerPairedCamera(peripheral: PeripheralID) async -> CameraDescriptor {
        lock.withLock { registered.append(peripheral) }
        return CameraDescriptor(id: .init(rawValue: "wifi-test"), name: "Camera", mode: .wifi(.cameraNetwork))
    }
}

@MainActor
@Suite("Wi-Fi onboarding model")
struct OnboardingModelTests {
    private func model(_ checker: FakeChecker, registry: FakeRegistry = FakeRegistry(),
                       known: PeripheralID? = nil) -> OnboardingModel {
        OnboardingModel(checker: checker, registry: registry, known: known)
    }

    @Test func itExplainsBeforeAnythingStarts() {
        let checker = FakeChecker([(.paired, peripheralA)])
        let m = model(checker)
        #expect(m.step == .explain)
        #expect(m.actions == [.start])
        let text = m.steps.joined(separator: " ")
        #expect(text.contains("MENU › Network › Bluetooth › Pairing"))
        #expect(text.contains("Bluetooth Function") && text.contains("Bluetooth Rmt Ctrl"))   // both until it is known
        #expect(text.contains("Two prompts"))
        #expect(m.detail.contains("Bluetooth"))   // iOS asks for it too
        #expect(checker.calls == 0)   // nothing started by explaining
    }

    @Test func aPairingRegistersTheCameraAndEnds() async {
        let checker = FakeChecker([(.paired, peripheralA)])
        let registry = FakeRegistry()
        let m = model(checker, registry: registry)
        await m.start()
        #expect(m.step == .paired(already: false))
        #expect(m.title == "Camera Paired")
        #expect(m.actions == [.done])
        #expect(registry.peripherals == [peripheralA])
        #expect(m.pairedCamera?.id.rawValue == "wifi-test")
        await m.start()   // nothing more once paired
        #expect(checker.calls == 1)
    }

    @Test func anExistingPairingSaysNothingWasConfirmed() async {
        let m = model(FakeChecker([(.alreadyPaired, peripheralA)]))
        await m.start()
        #expect(m.step == .paired(already: true))
        #expect(m.title == "Already Paired")
        #expect(m.detail.contains("nothing to confirm"))
    }

    @Test func aRefusalSendsThePersonToThePairingScreenAndTryAgainReusesThePeripheral() async {
        let checker = FakeChecker([(.notPaired, peripheralA), (.paired, peripheralA)])
        let registry = FakeRegistry()
        let m = model(checker, registry: registry)
        await m.start()
        #expect(m.step == .notPaired)
        #expect(m.detail.contains("MENU › Network › Bluetooth › Pairing"))
        #expect(m.detail.contains("Try Again"))
        #expect(m.actions == [.tryAgain])
        #expect(registry.peripherals.isEmpty)   // a refusal isn't a pairing
        await m.tryAgain()
        #expect(m.step == .paired(already: false))
        #expect(checker.calls == 2)   // one per tap, never a loop
        #expect(checker.knownPassed == [nil, peripheralA])   // the second connects by the first's identifier
    }

    @Test func aKnownPeripheralIsPassedOnTheFirstCheck() async {
        let checker = FakeChecker([(.alreadyPaired, peripheralB)])
        let m = model(checker, known: peripheralB)
        await m.start()
        #expect(checker.knownPassed == [peripheralB])
    }

    @Test func eachUnavailableReasonSaysWhatToDoNext() async {
        let failures: [GATTFailure] = [.bluetoothOff, .unauthorised, .linkDropped, .serviceMissing, .timedOut, .other(7)]
        for failure in failures {
            let m = model(FakeChecker([(.unavailable(failure), nil)]))
            await m.start()
            #expect(m.step == .unavailable(failure))
            #expect(!m.title.isEmpty)
            #expect(m.detail.hasSuffix("."))
            #expect(m.actions.contains(.tryAgain))
            #expect(!m.detail.lowercased().contains("sony"))
        }
        let denied = model(FakeChecker([(.unavailable(.unauthorised), nil)]))
        await denied.start()
        #expect(denied.actions == [.openSettings, .tryAgain])
        #expect(denied.detail.contains("Settings"))
        let off = model(FakeChecker([(.unavailable(.bluetoothOff), nil)]))
        await off.start()
        #expect(off.detail.contains("Turn on Bluetooth"))
        let dropped = model(FakeChecker([(.unavailable(.linkDropped), nil)]))
        await dropped.start()
        #expect(dropped.detail.contains("dropped twice"))   // after the check's own single retry
    }

    @Test func aSecondStartWhileWaitingDoesNothing() async {
        let checker = FakeChecker([(.paired, peripheralA)])
        checker.waits = true
        let m = model(checker)
        let first = Task { @MainActor in await m.start() }
        #expect(await waitUntilOnMain { m.isWaiting && checker.calls == 1 })
        #expect(m.actions == [.cancel])
        await m.start()
        #expect(checker.calls == 1)
        checker.waits = false
        checker.release()
        #expect(await bounded(first) != nil)
        #expect(m.step == .paired(already: false))
    }

    @Test func cancelWhileWaitingStopsTheCheckAndGoesBackToTheExplanation() async {
        let checker = FakeChecker([(.paired, peripheralA)])
        checker.waits = true
        let registry = FakeRegistry()
        let m = model(checker, registry: registry)
        let run = Task { @MainActor in await m.start() }
        #expect(await waitUntilOnMain { m.isWaiting && checker.calls == 1 })
        m.cancel()
        #expect(await bounded(run) != nil)
        #expect(m.step == .explain)
        #expect(registry.peripherals.isEmpty)
        // And it can start again.
        checker.waits = false
        await m.start()
        #expect(m.step == .paired(already: false))
    }

    @Test func theCancelWinsOverAResultThatArrivesAsItIsCancelled() async {
        let checker = FakeChecker([(.paired, peripheralA)])
        checker.waits = true
        checker.ignoresCancel = true
        let registry = FakeRegistry()
        let m = model(checker, registry: registry)
        let run = Task { @MainActor in await m.start() }
        #expect(await waitUntilOnMain { m.isWaiting && checker.calls == 1 })
        m.cancel()
        #expect(await bounded(run) != nil)
        #expect(m.step == .explain)
        #expect(registry.peripherals.isEmpty)   // the person cancelled: nothing is registered
    }

    @Test func aCancelledCallerCancelsTheCheck() async {
        let checker = FakeChecker([(.paired, peripheralA)])
        checker.waits = true
        let m = model(checker)
        let run = Task { @MainActor in await m.start() }
        #expect(await waitUntilOnMain { m.isWaiting && checker.calls == 1 })
        run.cancel()   // the screen went away
        #expect(await bounded(run) != nil)
        #expect(m.step == .explain)
    }

    @Test func cancelOutsideAWaitGoesBackToTheExplanationUnlessPaired() async {
        let m = model(FakeChecker([(.notPaired, peripheralA)]))
        await m.start()
        m.cancel()
        #expect(m.step == .explain)
        let paired = model(FakeChecker([(.paired, peripheralA)]))
        await paired.start()
        paired.cancel()
        #expect(paired.step == .paired(already: false))
    }

    @Test func theWordingIsEnglishBritishAndFree() {
        let lines = OnboardingWording.explainSteps + [
            OnboardingWording.waitingDetail, OnboardingWording.pairedDetail, OnboardingWording.alreadyPairedDetail,
            OnboardingWording.notPairedDetail, OnboardingWording.bluetoothOffDetail,
            OnboardingWording.bluetoothNotAllowedDetail, OnboardingWording.droppedDetail,
            OnboardingWording.notFoundDetail, OnboardingWording.unsupportedDetail,
        ]
        for line in lines {
            #expect(line.hasSuffix("."), "\(line)")
            #expect(!line.lowercased().contains("sony"), "\(line)")
            #expect(!line.contains("color"), "\(line)")
        }
        // Titles are in title case.
        for title in [OnboardingWording.title, OnboardingWording.explainTitle, OnboardingWording.waitingTitle,
                      OnboardingWording.pairedTitle, OnboardingWording.notPairedTitle,
                      OnboardingWording.bluetoothOffTitle, OnboardingWording.droppedTitle,
                      OnboardingWording.notFoundTitle] {
            let small: Set<String> = ["a", "an", "the", "of", "to", "for", "with", "over"]
            for (index, word) in title.split(separator: " ").enumerated() where index > 0 && !small.contains(String(word)) {
                #expect(word.first?.isUppercase == true, "\(title)")
            }
        }
    }
}

@MainActor
@Suite("Typed camera address model")
struct TypedAddressModelTests {
    private final class Sink: @unchecked Sendable {
        var added: [TypedCameraAddress] = []
    }

    private func model(_ text: String = "", sink: Sink = Sink()) -> TypedAddressModel {
        TypedAddressModel(text: text) { sink.added.append($0) }
    }

    @Test func goodAddressesAreAccepted() {
        for text in [typedHost, "\(typedHost):15741", "  \(typedHost) ", "camera.local", "Camera.Local.:15740", "cam-1"] {
            let m = model(text)
            #expect(m.address != nil, "\(text)")
            #expect(m.problem == nil && m.message == nil && m.canAdd, "\(text)")
        }
        #expect(model("\(typedHost):15741").address?.port == 15741)
        #expect(model("Camera.Local.").address?.host == "camera.local")
    }

    @Test func anEmptyFieldHasNoComplaintAndCantBeAdded() {
        for text in ["", "   "] {
            let m = model(text)
            #expect(m.problem == nil && m.message == nil && !m.canAdd)
        }
    }

    @Test func eachMistakeIsNamedAndExplained() {
        let cases: [(String, TypedAddressModel.Problem)] = [
            ("http://\(typedHost)", .url), ("\(typedHost)/dd.xml", .url), ("me@\(typedHost)", .url),
            ("[::1]:15740", .ipv6), ("fe80::1", .ipv6),
            ("\(typedHost):0", .port), ("\(typedHost):70000", .port), ("\(typedHost):abc", .port), ("\(typedHost):", .port),
            ("192.0.2", .numbers), ("300.1.1.1", .numbers), ("192.0.2.020", .numbers), ("1.2.3.4.5", .numbers),
            ("0.0.0.1", .unusable), ("127.0.0.1", .unusable), ("224.0.0.1", .unusable), ("255.255.255.255", .unusable),
            ("bad_name", .name), ("under score.local", .name), ("münchen.local", .name),
            ("-bad.local", .other), ("a..b", .other),
        ]
        for (text, expected) in cases {
            let m = model(text)
            #expect(m.address == nil, "\(text)")
            #expect(m.problem == expected, "\(text) was \(String(describing: m.problem))")
            let message = m.message ?? ""
            #expect(message.hasSuffix("."), "\(text): \(message)")
            #expect(!m.canAdd)
        }
    }

    @Test func theCamerasOwnNetworkPointsToBluetoothSetup() {
        for text in ["192.168.122.1", "192.168.122.1:15741"] {
            let m = model(text)
            #expect(m.address == nil && !m.canAdd)
            #expect(m.problem == .cameraNetwork)
            #expect(m.message?.contains("Bluetooth") == true)
        }
    }

    @Test func everyProblemHasACopyThatSaysWhatToTypeInstead() {
        for problem in TypedAddressModel.Problem.allCases {
            let line = TypedAddressWording.problem(problem)
            #expect(line.hasSuffix(".") && !line.isEmpty)
            #expect(!line.lowercased().contains("sony"))
        }
    }

    @Test func addHandsTheAddressOverOnce() async {
        let sink = Sink()
        let m = model(" \(typedHost):15741 ", sink: sink)
        #expect(await m.add())
        #expect(sink.added.count == 1)
        #expect(sink.added.first?.host == typedHost && sink.added.first?.port == 15741)
        #expect(!m.isAdding)
    }

    @Test func addDoesNothingForTextThatIsNotAnAddress() async {
        let sink = Sink()
        for text in ["", "nope/", "192.168.122.1"] {
            let m = model(text, sink: sink)
            #expect(await m.add() == false)
        }
        #expect(sink.added.isEmpty)
    }

    @Test func theAddressNeverReachesADescription() {
        let address = model(typedHost).address
        #expect(address.map { "\($0)" }?.contains(typedHost) == false)
    }
}
