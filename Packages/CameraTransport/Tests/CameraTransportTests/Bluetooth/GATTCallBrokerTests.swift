// The calls waiting on Core Bluetooth's callbacks (W10, `CBContinuations.swift`): each ends exactly once, by its answer, its
// time limit, a cancellation or a failure, on a virtual clock, so nothing here waits in real time.

import BLEKit
import Foundation
import Synchronization
import Testing
@testable import CameraTransport

/// Yields until `condition` holds (the test's time limit is the backstop).
private func until(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private let camera = UUID()
private let otherCamera = UUID()

@Suite("GATT call broker")
struct GATTCallBrokerTests {
    @Test func anRSSIReadIsAnsweredWithItsValueAndFailsWhenItsPeripheralGoes() async {
        let broker = GATTCallBroker(clock: VirtualClock())
        let answered = await broker.call(.rssi(camera), timeout: .seconds(5)) {
            broker.answer(.rssi(camera), .signal(-61))
        }
        #expect(answered == .signal(-61))
        #expect(GATTWaitKey.rssi(camera).peripheral == camera)
        let pending = Task { await broker.call(.rssi(camera), timeout: .seconds(5)) {} }
        await until { broker.isWaiting(.rssi(camera)) }
        #expect(broker.fail(.linkDropped) { $0.peripheral == camera } == 1)
        #expect(await pending.value == .failed(.linkDropped))
    }

    @Test func anAnswerEndsTheCallAndTheRequestIsSentOnceAfterTheCallIsRegistered() async {
        let broker = GATTCallBroker(clock: VirtualClock())
        let started = Counter()
        let outcome = await broker.call(.read(camera, .status), timeout: .seconds(15)) {
            started.bump()
            // Registered before the request goes out, so even an immediate answer reaches it.
            #expect(broker.isWaiting(.read(camera, .status)))
            broker.answer(.read(camera, .status), .value(Data([0x04, 0x00, 0x01, 0x02, 0x00])))
        }
        #expect(outcome == .value(Data([0x04, 0x00, 0x01, 0x02, 0x00])))
        #expect(started.count == 1)
        #expect(broker.waitingCount == 0)
    }

    @Test func answersGoToTheCallThatHasWaitedLongest() async {
        let broker = GATTCallBroker(clock: VirtualClock())
        let first = Task { await broker.call(.read(camera, .status), timeout: nil) {} }
        await until { broker.waitingCount == 1 }
        let second = Task { await broker.call(.read(camera, .status), timeout: nil) {} }
        await until { broker.waitingCount == 2 }
        #expect(broker.answer(.read(camera, .status), .value(Data([1]))))
        #expect(broker.answer(.read(camera, .status), .value(Data([2]))))
        #expect(await first.value == .value(Data([1])))
        #expect(await second.value == .value(Data([2])))
        #expect(!broker.answer(.read(camera, .status), .value(Data([3])))) // nobody waiting
    }

    @Test func anAnswerForAnotherKeyLeavesTheCallWaiting() async {
        let broker = GATTCallBroker(clock: VirtualClock())
        let call = Task { await broker.call(.read(camera, .status), timeout: nil) {} }
        await until { broker.waitingCount == 1 }
        #expect(!broker.answer(.read(camera, .battery), .value(Data())))
        #expect(!broker.answer(.read(otherCamera, .status), .value(Data())))
        #expect(!broker.answer(.write(camera, .status), .done))
        #expect(broker.isWaiting(.read(camera, .status)))
        broker.answer(.read(camera, .status), .done)
        #expect(await call.value == .done)
    }

    @Test func aCallThatGetsNoAnswerTimesOutAtItsLimit() async {
        let clock = VirtualClock()
        let broker = GATTCallBroker(clock: clock)
        let call = Task { await broker.call(.write(camera, .wifiOn), timeout: .seconds(15)) {} }
        await clock.waitUntilSomeoneSleeps()
        clock.advance(by: .seconds(14))
        #expect(broker.waitingCount == 1)
        clock.advance(by: .seconds(1))
        #expect(await call.value == .failed(.timedOut))
        #expect(broker.waitingCount == 0)
        // The late answer finds nobody.
        #expect(!broker.answer(.write(camera, .wifiOn), .done))
    }

    @Test func aTimedOutReadDoesNotSwallowTheAnswerToTheNextOne() async {
        let clock = VirtualClock()
        let broker = GATTCallBroker(clock: clock)
        let first = Task { await broker.call(.read(camera, .ssid), timeout: .seconds(15)) {} }
        await clock.waitUntilSomeoneSleeps()
        clock.advance(by: .seconds(15))
        #expect(await first.value == .failed(.timedOut))
        let retry = Task { await broker.call(.read(camera, .ssid), timeout: .seconds(15)) {} }
        await clock.waitUntilSomeoneSleeps()
        broker.answer(.read(camera, .ssid), .value(Data([0x01, 0x02, 0x03])))
        #expect(await retry.value == .value(Data([0x01, 0x02, 0x03])))
    }

    @Test func anAnsweredCallLeavesNoTimerOnTheClock() async {
        let clock = VirtualClock()
        let broker = GATTCallBroker(clock: clock)
        let call = Task { await broker.call(.notify(camera, .status), timeout: .seconds(10)) {} }
        await clock.waitUntilSomeoneSleeps()
        broker.answer(.notify(camera, .status), .notifying(true))
        #expect(await call.value == .notifying(true))
        await clock.waitUntil { sleepers, _, _ in sleepers == 0 }
    }

    @Test func theReadWithNoLimitWaitsForThePerson() async {
        // The pairing read: 12.3 s on 4 Nov 13:06, longer than any limit the spike gave a read.
        let clock = VirtualClock()
        let broker = GATTCallBroker(clock: clock)
        let call = Task { await broker.call(.read(camera, .status), timeout: nil) {} }
        await until { broker.waitingCount == 1 }
        clock.advance(by: .seconds(120))
        #expect(broker.isWaiting(.read(camera, .status)))
        broker.answer(.read(camera, .status), .value(Data([0x04, 0x00, 0x01, 0x00, 0x00])))
        #expect(await call.value == .value(Data([0x04, 0x00, 0x01, 0x00, 0x00])))
    }

    @Test func cancellingTheCallerDropsTheWaitAtOnce() async {
        // *Cancel* during the pairing read: the continuation is dropped, and the answer that comes later finds nothing.
        let broker = GATTCallBroker(clock: VirtualClock())
        let call = Task { await broker.call(.read(camera, .status), timeout: nil) {} }
        await until { broker.waitingCount == 1 }
        call.cancel()
        #expect(await call.value == .failed(.cancelled))
        #expect(broker.waitingCount == 0)
        #expect(!broker.answer(.read(camera, .status), .value(Data())))
    }

    @Test func aCallerAlreadyCancelledSendsNothing() async {
        let broker = GATTCallBroker(clock: VirtualClock())
        let started = Counter()
        let call = Task {
            await until { Task.isCancelled }
            return await broker.call(.write(camera, .wifiOn), timeout: .seconds(15)) { started.bump() }
        }
        call.cancel()
        #expect(await call.value == .failed(.cancelled))
        #expect(started.count == 0) // CC08 is never written for a cancelled hand-off
        #expect(broker.waitingCount == 0)
    }

    @Test func aDropFailsOnlyThatPeripheralsCalls() async {
        let broker = GATTCallBroker(clock: VirtualClock())
        let read = Task { await broker.call(.read(camera, .status), timeout: nil) {} }
        let notify = Task { await broker.call(.notify(camera, .battery), timeout: .seconds(10)) {} }
        let elsewhere = Task { await broker.call(.read(otherCamera, .status), timeout: nil) {} }
        let power = Task { await broker.call(.power, timeout: nil) {} }
        await until { broker.waitingCount == 4 }
        #expect(broker.fail(.linkDropped) { $0.peripheral == camera } == 2)
        #expect(await read.value == .failed(.linkDropped))
        #expect(await notify.value == .failed(.linkDropped))
        #expect(broker.waitingCount == 2)
        // Bluetooth going off fails everything but the wait for the power.
        #expect(broker.fail(.bluetoothOff) { $0 != .power } == 1)
        #expect(await elsewhere.value == .failed(.bluetoothOff))
        #expect(broker.answerAll(.power, .done) == 1)
        #expect(await power.value == .done)
    }

    @Test func thePowerSettlingAnswersEveryWaitForIt() async {
        let broker = GATTCallBroker(clock: VirtualClock())
        let calls = (0 ..< 3).map { _ in Task { await broker.call(.power, timeout: nil) {} } }
        await until { broker.waitingCount == 3 }
        #expect(broker.answerAll(.power, .failed(.unauthorised)) == 3)
        for call in calls { #expect(await call.value == .failed(.unauthorised)) }
        #expect(broker.answerAll(.power, .done) == 0)
    }

    @Test func waitKeysNameTheirPeripheral() {
        #expect(GATTWaitKey.power.peripheral == nil)
        #expect(GATTWaitKey.scan.peripheral == nil)
        for key in [GATTWaitKey.connect(camera), .services(camera), .characteristics(camera), .read(camera, .ssid),
                    .write(camera, .wifiOn), .notify(camera, .status)] {
            #expect(key.peripheral == camera)
        }
    }
}

@Suite("Latest-value streams")
struct LatestValueFanOutTests {
    @Test func aStreamStartsWithTheValueNowThenGetsEachChange() async {
        let fan = LatestValueFanOut<GATTLinkState>(.connected)
        let stream = fan.subscribe()
        fan.send(.dropped(.linkDropped))
        fan.finish()
        var seen: [GATTLinkState] = []
        for await state in stream { seen.append(state) }
        #expect(seen == [.connected, .dropped(.linkDropped)])
    }

    @Test func aStreamTakenAfterTheEndGetsTheLastValueAndEnds() async {
        let fan = LatestValueFanOut<GATTLinkState>(.connected)
        fan.send(.dropped(.cancelled))
        fan.finish()
        fan.send(.connected) // ignored after the end
        var seen: [GATTLinkState] = []
        for await state in fan.subscribe() { seen.append(state) }
        #expect(seen == [.dropped(.cancelled)])
        #expect(fan.current == .dropped(.cancelled))
    }

    @Test func eachStreamIsIndependentAndALateOneMissesNothingCurrent() async {
        let fan = LatestValueFanOut<BluetoothPower>(.unknown)
        let early = fan.subscribe()
        fan.send(.poweredOn)
        let late = fan.subscribe()
        fan.send(.poweredOff)
        fan.finish()
        var earlySeen: [BluetoothPower] = []
        for await power in early { earlySeen.append(power) }
        var lateSeen: [BluetoothPower] = []
        for await power in late { lateSeen.append(power) }
        #expect(earlySeen == [.unknown, .poweredOn, .poweredOff])
        #expect(lateSeen == [.poweredOn, .poweredOff])
    }

    @Test func aStreamWhoseReaderHasGoneIsDropped() async {
        let fan = LatestValueFanOut<BluetoothPower>(.unknown)
        do {
            let stream = fan.subscribe()
            #expect(fan.subscriberCount == 1)
            _ = stream
        }
        await until { fan.subscriberCount == 0 }
        #expect(!fan.isFinished)
    }
}
