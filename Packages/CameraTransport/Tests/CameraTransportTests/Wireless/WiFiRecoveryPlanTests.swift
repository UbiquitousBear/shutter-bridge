import Testing
@testable import CameraTransport

/// The Wi-Fi recovery's order as a table (backlog section 9; decision 3; Shamil, 9 Nov): wait for the card with the session
/// up, else reopen (the session's own 30 s on Wi-Fi before Bluetooth, then the join in front), list only the new handles,
/// and with the app away pause for a join rather than join; three recoveries by themselves per import.
@Suite("Wi-Fi recovery: the plan")
struct WiFiRecoveryPlanTests {
    /// Feeds `inputs` in order and returns each step.
    private func steps(_ inputs: [RecoveryInput], foreground: Bool = true, bluetooth: Bool = true,
                       plan: inout WiFiRecoveryPlan) -> [RecoveryStep] {
        inputs.map { plan.next(after: $0, foreground: foreground, bluetoothAllowed: bluetooth) }
    }

    private func steps(_ inputs: [RecoveryInput], foreground: Bool = true, bluetooth: Bool = true) -> [RecoveryStep] {
        var plan = WiFiRecoveryPlan()
        return steps(inputs, foreground: foreground, bluetooth: bluetooth, plan: &plan)
    }

    // MARK: Timings

    @Test func theTimingsAreTheDecidedAndMeasuredOnes() {
        #expect(WiFiRecoveryTiming.waitForStoreAdded == .seconds(15))
        // Shamil, 9 Nov: 30 s before going back to Bluetooth, one value with the session's Wi-Fi retry.
        #expect(WiFiRecoveryTiming.waitBeforeBluetooth == .seconds(30))
        #expect(WirelessTiming.wifiRetryBeforeBluetooth == WiFiRecoveryTiming.waitBeforeBluetooth)
        #expect(WiFiRecoveryTiming.rejoinWhileAway == .seconds(30))
        #expect(WiFiRecoveryTiming.recoveriesPerImport == 3)
        #expect(WiFiRecoveryPlan().recoveriesPerImport == 3)
    }

    // MARK: The order

    @Test func aCardThatComesBackOnTheSameSessionNeedsNothingMore() {
        var plan = WiFiRecoveryPlan()
        #expect(steps([.cardRemoved, .cardBack], plan: &plan) == [.waitForCard, .done])
        #expect(plan.phase == .idle)
        #expect(plan.recoveries == 1)
    }

    @Test func aCardThatDoesntComeBackInTimeReopensAndRelists() {
        #expect(steps([.cardRemoved, .cardWaitEnded, .reopened, .relisted])
            == [.waitForCard, .reopen(bluetoothSwitchOnWhenAway: true), .relist, .done])
    }

    @Test func aSessionLostWhileWaitingForTheCardReopensAtOnce() {
        // 4 Nov 01:08: StoreRemoved, then the camera's Wi-Fi off about 6 s later.
        var plan = WiFiRecoveryPlan()
        #expect(steps([.cardRemoved, .sessionLost], plan: &plan)
            == [.waitForCard, .reopen(bluetoothSwitchOnWhenAway: true)])
        #expect(plan.phase == .reopening)
        // The wait's end, arriving late, changes nothing.
        #expect(steps([.cardWaitEnded], plan: &plan) == [.noChange])
    }

    @Test func aLostSessionReopensWithoutWaitingForTheCard() {
        #expect(steps([.sessionLost, .reopened, .relisted])
            == [.reopen(bluetoothSwitchOnWhenAway: true), .relist, .done])
    }

    @Test(arguments: [true, false])
    func theReopenCarriesWhetherBluetoothMaySwitchTheWiFiOnWithTheAppAway(_ allowed: Bool) {
        #expect(steps([.sessionLost], foreground: false, bluetooth: allowed)
            == [.reopen(bluetoothSwitchOnWhenAway: allowed)])
    }

    // MARK: With the app away

    @Test func aJoinNeededWithTheAppAwayPausesAndTheReturnJoins() {
        var plan = WiFiRecoveryPlan()
        #expect(steps([.sessionLost, .needsJoin], foreground: false, plan: &plan)
            == [.reopen(bluetoothSwitchOnWhenAway: true), .pauseNeedsJoin])
        #expect(plan.phase == .pausedForJoin)
        #expect(plan.isRecovering)
        // Events while paused change nothing; the person coming back reopens, and the count starts again.
        #expect(steps([.sessionLost, .cardRemoved, .cardBack], foreground: false, plan: &plan)
            == [.noChange, .noChange, .noChange])
        #expect(steps([.personReturned, .reopened, .relisted], plan: &plan)
            == [.reopen(bluetoothSwitchOnWhenAway: true), .relist, .done])
        #expect(plan.recoveries == 0)
        #expect(!plan.isRecovering)
    }

    @Test func anyFailedReopenWithTheAppAwayPausesForTheJoin() {
        var plan = WiFiRecoveryPlan()
        #expect(steps([.sessionLost, .reopenFailed], foreground: false, plan: &plan)
            == [.reopen(bluetoothSwitchOnWhenAway: true), .pauseNeedsJoin])
        #expect(plan.phase == .pausedForJoin)
    }

    @Test func aFailedReopenInFrontGivesUpUntilThePersonTriesAgain() {
        var plan = WiFiRecoveryPlan()
        #expect(steps([.sessionLost, .reopenFailed], plan: &plan) == [.reopen(bluetoothSwitchOnWhenAway: true), .giveUp])
        #expect(plan.phase == .gaveUp)
        #expect(steps([.sessionLost], plan: &plan) == [.noChange])
        #expect(steps([.personReturned], plan: &plan) == [.reopen(bluetoothSwitchOnWhenAway: true)])
        #expect(plan.phase == .reopening)
    }

    @Test func aJoinNeededWhileListingPausesToo() {
        var plan = WiFiRecoveryPlan()
        #expect(steps([.sessionLost, .reopened, .needsJoin], foreground: false, plan: &plan)
            == [.reopen(bluetoothSwitchOnWhenAway: true), .relist, .pauseNeedsJoin])
    }

    // MARK: The limit

    @Test func threeRecoveriesByThemselvesThenItWaitsForThePerson() {
        var plan = WiFiRecoveryPlan()
        for _ in 1...3 {
            #expect(steps([.sessionLost, .reopened, .relisted], plan: &plan)
                == [.reopen(bluetoothSwitchOnWhenAway: true), .relist, .done])
        }
        #expect(plan.recoveries == 3)
        #expect(steps([.cardRemoved], plan: &plan) == [.giveUp])
        #expect(plan.phase == .gaveUp)
        #expect(steps([.personReturned], plan: &plan) == [.reopen(bluetoothSwitchOnWhenAway: true)])
        #expect(plan.recoveries == 0)
    }

    /// With the app away the person has to be told: an import with no recovery left pauses for a join (B:211).
    @Test(arguments: [RecoveryInput.sessionLost, .cardRemoved])
    func outOfRecoveriesWithTheAppAwayPausesForAJoin(_ input: RecoveryInput) {
        var plan = WiFiRecoveryPlan(recoveriesPerImport: 1)
        _ = steps([.sessionLost, .reopened, .relisted], plan: &plan)
        #expect(steps([input], foreground: false, plan: &plan) == [.pauseNeedsJoin])
        #expect(plan.phase == .pausedForJoin)
        #expect(steps([.personReturned], plan: &plan) == [.reopen(bluetoothSwitchOnWhenAway: true)])
        #expect(plan.recoveries == 0)
    }

    @Test func aFailedListingWithNoRecoveryLeftWithTheAppAwayPausesForAJoin() {
        var plan = WiFiRecoveryPlan(recoveriesPerImport: 1)
        #expect(steps([.sessionLost, .reopened, .relistFailed], foreground: false, plan: &plan)
            == [.reopen(bluetoothSwitchOnWhenAway: true), .relist, .pauseNeedsJoin])
        #expect(plan.phase == .pausedForJoin)
    }

    /// In front, a join the session still refuses waits for the person rather than retrying at once (and the count
    /// stays where it was).
    @Test func aJoinRefusedInFrontGivesUp() {
        var plan = WiFiRecoveryPlan()
        #expect(steps([.sessionLost, .needsJoin, .joinRefusedInFront], plan: &plan)
            == [.reopen(bluetoothSwitchOnWhenAway: true), .pauseNeedsJoin, .giveUp])
        #expect(plan.phase == .gaveUp)
        #expect(plan.recoveries == 1)
    }

    @Test func aCardThatCameBackCountsAsARecovery() {
        var plan = WiFiRecoveryPlan(recoveriesPerImport: 1)
        #expect(steps([.cardRemoved, .cardBack, .cardRemoved], plan: &plan) == [.waitForCard, .done, .giveUp])
    }

    @Test func aFailedListingIsAnotherRecoveryWhileTheImportHasOneLeft() {
        var plan = WiFiRecoveryPlan(recoveriesPerImport: 2)
        #expect(steps([.sessionLost, .reopened, .relistFailed, .reopened, .relistFailed], plan: &plan)
            == [.reopen(bluetoothSwitchOnWhenAway: true), .relist, .reopen(bluetoothSwitchOnWhenAway: true), .relist,
                .giveUp])
        #expect(plan.phase == .gaveUp)
    }

    @Test func resetForgetsTheRecoveryAndTheCount() {
        var plan = WiFiRecoveryPlan()
        _ = steps([.sessionLost, .reopened, .relisted, .cardRemoved], plan: &plan)
        #expect(plan.phase == .waitingForCard)
        plan.reset()
        #expect(plan == WiFiRecoveryPlan())
    }

    // MARK: What changes nothing

    struct Ignored: Sendable, CustomTestStringConvertible {
        var before: [RecoveryInput]
        var input: RecoveryInput
        var testDescription: String { "\(before) then \(input)" }
    }

    @Test(arguments: [
        Ignored(before: [], input: .cardBack),
        Ignored(before: [], input: .cardWaitEnded),
        Ignored(before: [], input: .reopened),
        Ignored(before: [], input: .relisted),
        Ignored(before: [], input: .reopenFailed),
        Ignored(before: [], input: .personReturned),
        Ignored(before: [.cardRemoved], input: .cardRemoved),
        Ignored(before: [.cardRemoved], input: .reopened),
        Ignored(before: [.cardRemoved], input: .personReturned),
        Ignored(before: [.sessionLost], input: .sessionLost),
        Ignored(before: [.sessionLost], input: .cardRemoved),
        Ignored(before: [.sessionLost], input: .cardBack),
        Ignored(before: [.sessionLost], input: .relisted),
        Ignored(before: [.sessionLost], input: .personReturned),
        Ignored(before: [.sessionLost, .reopened], input: .sessionLost),
        Ignored(before: [.sessionLost, .reopened], input: .cardRemoved),
        Ignored(before: [.sessionLost, .reopened], input: .reopened),
        Ignored(before: [], input: .joinRefusedInFront),
        Ignored(before: [.sessionLost], input: .joinRefusedInFront),
        Ignored(before: [.sessionLost, .reopenFailed], input: .joinRefusedInFront),
    ])
    func lateOrMisplacedInputsChangeNothing(_ row: Ignored) {
        var plan = WiFiRecoveryPlan()
        _ = steps(row.before, plan: &plan)
        let before = plan
        #expect(plan.next(after: row.input, foreground: true, bluetoothAllowed: true) == .noChange)
        #expect(plan == before)
    }
}
