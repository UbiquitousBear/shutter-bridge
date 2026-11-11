import CameraTransport
import Foundation
import ImportEngine
import Testing
@testable import AppUI

private let cam = CameraDescriptor.ID(rawValue: "wifi-a")
private let otherCam = CameraDescriptor.ID(rawValue: "wifi-b")
private let fixedNow = Date(timeIntervalSince1970: 1_794_000_000)

@MainActor
private struct Harness {
    let source = FakeConnectionSource()
    let record = InMemoryLocalNetworkExplainedRecord()
    let clock = WiFiTestClock()
    let model: WiFiImportModel

    init(explained: Bool = false) {
        if explained { record.recordExplained() }
        model = WiFiImportModel(source: source, record: record, clock: clock, now: { fixedNow })
    }

    func send(_ event: WiFiConnectionEvent) { model.apply(event) }
    func phase(_ phase: WirelessPhase, remaining: Duration? = nil, of id: CameraDescriptor.ID = cam) {
        model.apply(.phase(id, phase, stayRemaining: remaining))
    }
}

@MainActor
@Suite("Wi-Fi import model: the connection's states")
struct WiFiImportModelTests {
    // MARK: The Local Network explanation

    @Test func theFirstConnectionIsExplainedAndContinueRecordsIt() async {
        let h = Harness()
        let gate = Task { @MainActor in await h.model.beforeFirstConnection() }
        #expect(await waitUntilOnMain { h.model.isExplainingLocalNetwork })
        #expect(h.model.statusLine == nil)   // the screen shows the explanation's own copy
        #expect(!h.record.hasExplained)
        h.model.continueAfterExplaining()
        #expect(await bounded(gate) == true)
        #expect(!h.model.isExplainingLocalNetwork)
        #expect(h.record.hasExplained)
        // Once explained, the gate is open at once, whatever follows.
        #expect(await h.model.beforeFirstConnection())
        #expect(!h.model.isExplainingLocalNetwork)
    }

    @Test func notNowCancelsTheConnectionAndTheExplanationComesAgain() async {
        let h = Harness()
        let gate = Task { @MainActor in await h.model.beforeFirstConnection() }
        #expect(await waitUntilOnMain { h.model.isExplainingLocalNetwork })
        h.model.declineExplaining()
        #expect(await bounded(gate) == false)
        #expect(!h.model.isExplainingLocalNetwork && !h.record.hasExplained)
        let again = Task { @MainActor in await h.model.beforeFirstConnection() }
        #expect(await waitUntilOnMain { h.model.isExplainingLocalNetwork })
        h.model.continueAfterExplaining()
        #expect(await bounded(again) == true)
    }

    @Test func aCancelledCallerEndsTheWait() async {
        let h = Harness()
        let gate = Task { @MainActor in await h.model.beforeFirstConnection() }
        #expect(await waitUntilOnMain { h.model.isExplainingLocalNetwork })
        gate.cancel()
        #expect(await bounded(gate) == false)
        #expect(await waitUntilOnMain { !h.model.isExplainingLocalNetwork })
        #expect(!h.record.hasExplained)
    }

    @Test func aCallerCancelledBeforeItAsksNeverShowsTheExplanation() async {
        let h = Harness()
        let gate = Task { @MainActor () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await h.model.beforeFirstConnection()
        }
        #expect(await bounded(gate) == false)
        #expect(!h.model.isExplainingLocalNetwork)
    }

    @Test func twoConnectionsAskedTogetherShareOneExplanation() async {
        let h = Harness()
        let first = Task { @MainActor in await h.model.beforeFirstConnection() }
        let second = Task { @MainActor in await h.model.beforeFirstConnection() }
        #expect(await waitUntilOnMain { h.model.isExplainingLocalNetwork })
        h.model.continueAfterExplaining()
        #expect(await bounded(first) == true)
        #expect(await bounded(second) == true)
    }

    @Test func continueWithNothingWaitingRecordsNothing() {
        let h = Harness()
        h.model.continueAfterExplaining()
        #expect(!h.record.hasExplained)
    }

    // MARK: Steps

    @Test func theStepsOfAConnectionAreSaidInOrder() {
        let h = Harness(explained: true)
        #expect(h.model.statusLine == nil)
        h.send(.connecting(cam))
        h.phase(.handingOff)
        #expect(h.model.statusLine == "Switching on the camera's Wi-Fi…")
        #expect(h.model.isConnecting && !h.model.isJoined)
        h.phase(.joining)
        #expect(h.model.statusLine == "Joining the camera's Wi-Fi. Tap Join if iOS asks.")
        #expect(h.model.isJoined)
        h.phase(.openingSession)
        #expect(h.model.statusLine == "Opening the camera…")
        h.phase(.ready)
        #expect(h.model.statusLine == nil && h.model.isJoined && !h.model.isConnecting)
        h.phase(.staying, remaining: .seconds(180))
        #expect(h.model.statusLine == WiFiWording.stay)
        h.phase(.leaving)
        #expect(h.model.statusLine == "Leaving the camera's Wi-Fi…")
        #expect(!h.model.isJoined)
    }

    @Test func mobileDataIsMentionedExactlyWhileJoined() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.handingOff)
        #expect(h.model.notes.isEmpty)   // not on the camera's network yet
        for phase in [WirelessPhase.joining, .openingSession, .ready, .staying] {
            h.phase(phase)
            #expect(h.model.notes == [WiFiWording.mobileDataNote], "\(phase)")
        }
        h.phase(.leaving)
        #expect(h.model.notes.isEmpty)
    }

    @Test func afterLeavingTheCamerasWiFiMayStayOnUntilTheNextConnection() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.ready)
        h.phase(.leaving)
        h.phase(.idle)
        #expect(h.model.wifiMayStayOn)
        #expect(h.model.notes == [WiFiWording.wifiMayStayOn])
        #expect(WiFiWording.wifiMayStayOn.contains("may stay on"))
        h.model.dismissNotes()
        #expect(h.model.notes.isEmpty)
        // A new connection clears it, and it comes back only after another leave.
        h.phase(.leaving)
        h.phase(.idle)
        #expect(h.model.wifiMayStayOn)
        h.send(.connecting(cam))
        #expect(!h.model.wifiMayStayOn)
        h.phase(.handingOff)
        #expect(!h.model.wifiMayStayOn)
    }

    @Test func anIdleSessionThatNeverLeftSaysNothingAboutTheCamerasWiFi() {
        let h = Harness(explained: true)
        h.phase(.idle)
        #expect(!h.model.wifiMayStayOn && h.model.notes.isEmpty)
    }

    @Test func theStayEndsWhenTheSessionSaysAndNotBefore() {
        let h = Harness(explained: true)
        h.phase(.staying, remaining: .seconds(180))
        #expect(h.model.stayEndsAt == fixedNow.addingTimeInterval(180))
        h.phase(.staying, remaining: .milliseconds(90_500))
        #expect(h.model.stayEndsAt == fixedNow.addingTimeInterval(90.5))
        h.phase(.staying, remaining: nil)
        #expect(h.model.stayEndsAt == nil)
        h.phase(.staying, remaining: .seconds(60))
        h.phase(.leaving)
        #expect(h.model.stayEndsAt == nil)
    }

    @Test func aPauseNamesWhatThePersonMustDo() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        for pause in [WirelessPause.needsJoin, .notPaired, .bluetoothOff, .bluetoothNotAllowed, .joinDeclined] {
            h.phase(.paused(pause))
            #expect(h.model.pause == pause)
            #expect(h.model.statusLine == WiFiWording.paused(pause))
            #expect(!h.model.isConnecting)
        }
        h.phase(.handingOff)
        #expect(h.model.pause == nil)
    }

    // MARK: Waiting for iOS's Local Network prompt

    @Test func waitingForLocalNetworkIsAStateNotAFailure() async {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.openingSession)
        h.send(.link(cam, .waitingForLocalNetwork))
        #expect(h.model.isWaitingForLocalNetwork)
        #expect(h.model.statusLine == WiFiWording.waitingForLocalNetwork)
        #expect(h.model.failure == nil)
        // Answered: the session opens, and the line goes.
        h.phase(.ready)
        #expect(!h.model.isWaitingForLocalNetwork)
        #expect(h.model.statusLine == nil)
    }

    @Test func aLongWaitSaysThePromptMayNotHaveShown() async {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.openingSession)
        h.send(.link(cam, .waitingForLocalNetwork))
        #expect(await waitUntil { h.clock.sleeperCount == 1 })
        h.clock.advance(by: WiFiImportTiming.localNetworkHintAfter - .seconds(1))
        #expect(!h.model.localNetworkWaitIsLong)
        h.clock.advance(by: .seconds(1))
        #expect(await waitUntilOnMain { h.model.localNetworkWaitIsLong })
        #expect(h.model.statusLine == WiFiWording.stillWaitingForLocalNetwork)
        #expect(WiFiWording.stillWaitingForLocalNetwork.contains("Settings"))
        h.phase(.ready)
        #expect(!h.model.localNetworkWaitIsLong && h.model.statusLine == nil)
    }

    @Test func anAnswerEndsTheHintTimer() async {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.openingSession)
        h.send(.link(cam, .waitingForLocalNetwork))
        #expect(await waitUntil { h.clock.sleeperCount == 1 })
        h.phase(.ready)
        #expect(await waitUntil { h.clock.sleeperCount == 0 })   // cancelled, not left sleeping
        h.clock.advance(by: .seconds(60))
        #expect(!h.model.localNetworkWaitIsLong)
    }

    @Test func aLostSessionOrAFailureEndsTheWait() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.send(.link(cam, .waitingForLocalNetwork))
        h.send(.link(cam, .sessionLost(generation: 1)))
        #expect(!h.model.isWaitingForLocalNetwork)
        h.send(.link(cam, .waitingForLocalNetwork))
        h.send(.failed(cam, .noGateway))
        #expect(!h.model.isWaitingForLocalNetwork)
    }

    // MARK: Failures

    @Test func aFailureSaysWhyAndWhatToDo() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.send(.failed(cam, .cameraNotFound))
        #expect(h.model.failure == .cameraNotFound)
        #expect(h.model.statusLine == WiFiWording.failure(.cameraNotFound))
        #expect(h.model.statusLine?.contains("close to this iPhone") == true)
        // A new connection clears it, and while it connects the step is shown instead.
        h.send(.connecting(cam))
        #expect(h.model.failure == nil)
        h.phase(.joining)
        #expect(h.model.statusLine == WiFiWording.step(.joining))
    }

    @Test func aFailureStaysOnTheLineOnceTheSessionIsIdleAgain() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.joining)
        h.send(.failed(cam, .join(.userDenied)))
        h.phase(.idle)
        #expect(h.model.statusLine == WiFiWording.paused(.joinDeclined))
    }

    @Test func aCancelHasNoLine() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.send(.failed(cam, .cancelled))
        #expect(h.model.statusLine == nil)
    }

    // MARK: Which camera

    @Test func eventsAboutAnotherCameraAreIgnoredUntilItsConnectionBegins() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.joining)
        h.phase(.ready, of: otherCam)
        h.send(.failed(otherCam, .noGateway))
        h.send(.link(otherCam, .waitingForLocalNetwork))
        #expect(h.model.camera == cam && h.model.phase == .joining)
        #expect(h.model.failure == nil && !h.model.isWaitingForLocalNetwork)
        h.send(.connecting(otherCam))
        h.phase(.handingOff, of: otherCam)
        #expect(h.model.camera == otherCam && h.model.phase == .handingOff)
    }

    @Test func nothingIsShownAboutBatteryOrFreeSpace() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.ready)
        let lines = [h.model.statusLine ?? ""] + h.model.notes
        for line in lines { #expect(!line.lowercased().contains("battery") && !line.contains("0%")) }
    }

    // MARK: Following the source

    @Test func startFollowsTheSourceOnce() async {
        let h = Harness(explained: true)
        h.model.start()
        h.model.start()   // one consumer: a second read of the stream would take events from the first
        h.source.send(.connecting(cam))
        h.source.send(.phase(cam, .joining, stayRemaining: nil))
        #expect(await waitUntilOnMain { h.model.phase == .joining })
        h.source.send(.phase(cam, .ready, stayRemaining: nil))
        #expect(await waitUntilOnMain { h.model.phase == .ready })
    }

    // MARK: A join held with the app away (bench 19.1)

    @Test func aHeldJoinAsksThePersonToComeBackWithoutASpinner() {
        let h = Harness(explained: true)
        h.send(.connecting(cam))
        h.phase(.handingOff)
        h.phase(.awaitingFront)
        let line = "Come back to Shutter Bridge to finish joining the camera's Wi-Fi."
        #expect(h.model.statusLine == line)
        #expect(h.model.activityLine == line)
        #expect(h.model.isConnecting && !h.model.isJoined)
        #expect(!h.model.showsActivity)
        #expect(h.model.hasStatus(for: cam))
        // Back in front, the join's own line.
        h.phase(.joining)
        #expect(h.model.activityLine == WiFiWording.step(.joining))
        #expect(h.model.showsActivity)
    }

    @Test func aHeldJoinPostsOneNotificationWhenAllowedAndWithdrawsItOnReturn() async {
        let h = Harness(explained: true)
        let notifier = FakeNotifier(.authorised)
        h.model.notifier = notifier
        h.send(.connecting(cam))
        h.phase(.handingOff)
        h.phase(.awaitingFront)
        h.phase(.awaitingFront)   // still held: no second notification
        await h.model.joinNotificationSettled()
        #expect(notifier.posts == [.joinWaiting])
        #expect(AppNotification.joinWaiting.body == "Open Shutter Bridge to join the camera's Wi-Fi.")
        h.phase(.joining)
        await h.model.joinNotificationSettled()
        #expect(notifier.withdrawals == [.joinWaiting])
        #expect(notifier.requests == 0)   // never asks for permission
    }

    @Test func aHeldJoinNeverAsksForNotificationsAndPostsNothingWhenNotAllowed() async {
        let h = Harness(explained: true)
        let notifier = FakeNotifier(.notDetermined)
        h.model.notifier = notifier
        h.send(.connecting(cam))
        h.phase(.awaitingFront)
        h.send(.failed(cam, .paused(.needsJoin)))
        await h.model.joinNotificationSettled()
        #expect(notifier.posts.isEmpty && notifier.withdrawals.isEmpty && notifier.requests == 0)
    }

    @Test func theJoinsFailuresSayWhatReallyHappened() {
        // A pause for a join, as an open failure: the app had to be open.
        let needsApp = "Shutter Bridge has to be open to join the camera's Wi-Fi. Try again, and stay in Shutter Bridge "
            + "until iOS asks to join."
        #expect(WiFiWording.failure(.paused(.needsJoin)) == needsApp)
        #expect(WiFiWording.failure(.join(.notInForeground)) == needsApp)
        // The strip's step for the same pause is unchanged.
        #expect(WiFiWording.step(.paused(.needsJoin)) == "Open Shutter Bridge to join the camera's Wi-Fi.")
        // A rewrite that failed: the camera's Wi-Fi lapsed before iOS joined.
        let rewrite = "The camera's Wi-Fi switched itself off before iOS joined it. Try again, and tap Join as soon as "
            + "iOS asks."
        for failure in [HandoffFailure.timedOut(lastStatus: nil), .wifiDidNotStart(lastStatus: nil), .linkDropped(afterWrite: true)] {
            #expect(WiFiWording.failure(.rewriteFailed(failure)) == rewrite)
        }
        #expect(WiFiWording.failure(.rewriteFailed(.cancelled)) == nil)
        // A first hand-off that really failed in front keeps its sentence.
        #expect(WiFiWording.failure(.handoff(.timedOut(lastStatus: nil)))
            == "The camera didn't switch its Wi-Fi on. Check that it is on with Bluetooth Function on, then try again.")
    }

    // MARK: Wording

    @Test func theCopyIsBritishWithANextStepInEveryFailure() {
        let failures: [WirelessFailure] = [
            .paused(.needsJoin), .paused(.notPaired), .paused(.bluetoothOff), .paused(.bluetoothNotAllowed),
            .paused(.joinDeclined), .cameraNotFound, .bluetooth(.serviceMissing), .bluetooth(.timedOut),
            .bluetooth(.bluetoothOff), .bluetooth(.unauthorised), .bluetooth(.notPaired), .handoff(.notPaired),
            .handoff(.timedOut(lastStatus: nil)), .handoff(.wifiLapsed(lastStatus: nil)), .join(.userDenied),
            .join(.invalidCredentials), .join(.other(1)), .join(.notInForeground), .noGateway, .cameraWiFiLapsed,
            .rewriteFailed(.timedOut(lastStatus: nil)), .rewriteFailed(.notPaired),
            .link(CameraLinkFailure(.refused)), .link(CameraLinkFailure(.noAnswer)),
            .link(CameraLinkFailure(.identityChanged)), .link(CameraLinkFailure(.cardUnavailable)),
        ]
        let nextSteps = ["try again", "again", "Check", "Turn on", "Allow", "Move closer", "Import over USB-C", "Open",
                         "Connect", "Free some space"]
        for failure in failures {
            let line = WiFiWording.failure(failure)
            #expect(line != nil, "\(failure)")
            let text = line ?? ""
            #expect(text.hasSuffix("."), "\(text)")
            #expect(nextSteps.contains { text.contains($0) }, "no next step: \(text)")
            #expect(!text.lowercased().contains("sony") && !text.contains("color"), "\(text)")
        }
        for silent in [WirelessFailure.cancelled, .join(.cancelled), .handoff(.cancelled), .bluetooth(.cancelled)] {
            #expect(WiFiWording.failure(silent) == nil)
        }
    }

    @Test func theStepsAndNotesAreFinishedSentences() {
        let phases: [WirelessPhase] = [.handingOff, .joining, .openingSession, .staying, .leaving, .paused(.needsJoin)]
        for phase in phases {
            let line = WiFiWording.step(phase) ?? ""
            #expect(!line.isEmpty && !line.lowercased().contains("sony"), "\(phase)")
        }
        #expect(WiFiWording.step(.idle) == nil && WiFiWording.step(.ready) == nil)
        for line in [WiFiWording.stay, WiFiWording.mobileDataNote, WiFiWording.wifiMayStayOn,
                     WiFiWording.localNetworkDetail, WiFiWording.waitingForLocalNetwork,
                     WiFiWording.stillWaitingForLocalNetwork] {
            #expect(line.hasSuffix("."), "\(line)")
        }
        #expect(WiFiWording.localNetworkTitle == "Allow Local Network Access")
        #expect(WiFiWording.mobileDataNote.contains("mobile data"))
    }

    @Test func wifiListingFailuresDontMentionTheCable() {
        for kind in CameraLinkFailure.Kind.allCases {
            let line = WiFiWording.listingFailed(kind)
            if kind == .busy || kind == .noAnswer {
                #expect(!line.contains("cable"))
            } else {
                #expect(line == BrowseWording.listingFailed(kind))
            }
        }
    }

    @Test func theWiFiPauseReasonsAreWordedWithANextStep() {
        for reason in [PauseReason.taskExpired, .cardUnavailable, .cameraUnreachable, .needsJoin] {
            let line = ImportWording.paused(reason)
            #expect(line.hasSuffix(".") && !line.contains("Placeholder"), "\(line)")
        }
        #expect(ImportWording.paused(.taskExpired).contains("Tap Continue to resume"))
        #expect(ImportWording.paused(.needsJoin).contains("join the camera's Wi-Fi"))
        #expect(ImportWording.paused(.cardUnavailable).contains("Check that the card is in the camera;"))
        #expect(ImportWording.paused(.cameraUnreachable).contains("Move closer"))
    }
}
