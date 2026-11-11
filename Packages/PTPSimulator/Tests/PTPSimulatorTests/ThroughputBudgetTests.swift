import Foundation
import PTPKit
import Testing
@testable import PTPSimulator

/// The slow-link budget and the data-phase packets it shapes (backlog Iteration 2, section 3, *Slow link*): pure, so
/// exact on any runner.
@Suite("Throughput budget", .timeLimit(.minutes(1)))
struct ThroughputBudgetTests {
    @Test func aBudgetThatCouldNeverGrantIsRefused() {
        #expect(ThroughputBudget(bytesPerTick: 0, every: .seconds(1)) == nil)
        #expect(ThroughputBudget(bytesPerTick: 1, every: .zero) == nil)
        #expect(ThroughputBudget(bytesPerTick: 1, every: .seconds(-1)) == nil)
        #expect(ThroughputBudget(bytesPerTick: 1, every: .nanoseconds(1)) != nil)
    }

    @Test func nothingIsGrantedUntilATickHasPassed() throws {
        var budget = try #require(ThroughputBudget(bytesPerTick: 1000, every: .seconds(1)))
        #expect(budget.take(upTo: 10) == 0)
        budget.advance(by: .milliseconds(999))
        #expect(budget.available == 0)
        budget.advance(by: .milliseconds(1))
        #expect(budget.available == 1000)
    }

    @Test func timeShortOfATickIsCarriedNeverRoundedUp() throws {
        var budget = try #require(ThroughputBudget(bytesPerTick: 100, every: .milliseconds(30)))
        for _ in 0 ..< 3 { budget.advance(by: .milliseconds(10)) }
        #expect(budget.available == 100)
        budget.advance(by: .milliseconds(65))        // 65 ms: two ticks and 5 ms over
        #expect(budget.available == 300)
        budget.advance(by: .milliseconds(25))        // the 5 ms and these 25 ms make a tick
        #expect(budget.available == 400)
    }

    @Test func aTakeNeverExceedsWhatIsAvailable() throws {
        var budget = try #require(ThroughputBudget(bytesPerTick: 1000, every: .seconds(1)))
        budget.advance(by: .seconds(3))
        #expect(budget.take(upTo: 2500) == 2500)
        #expect(budget.take(upTo: 2500) == 500)
        #expect(budget.take(upTo: 1) == 0)
        #expect(budget.available == 0)
    }

    @Test func bytesNobodyTookStayAvailableForTheNextTake() throws {
        var budget = try #require(ThroughputBudget(bytesPerTick: 10, every: .seconds(1)))
        budget.advance(by: .seconds(2))
        #expect(budget.take(upTo: 5) == 5)
        budget.advance(by: .seconds(1))
        #expect(budget.available == 25)
    }

    @Test func negativeTimeAndHugeBudgetsDoNotTrap() throws {
        var budget = try #require(ThroughputBudget(bytesPerTick: UInt64.max, every: .seconds(1)))
        budget.advance(by: .seconds(-5))
        #expect(budget.available == 0)
        budget.advance(by: .seconds(1_000_000))
        #expect(budget.available == UInt64.max)
        budget.advance(by: .seconds(1))
        #expect(budget.available == UInt64.max)
    }

    // MARK: Data-phase packets

    private func pattern(_ length: Int) -> Data {
        Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0) })
    }

    private func phase(length: Int) -> PTPResponder.DataPhase { .bytes(pattern(length)) }

    /// The payload bytes the data packets of an encoded phase carry, and how many packets carried them.
    private func payload(of packets: [Data]) throws -> (bytes: Data, count: Int) {
        var decoder = PTPIPStreamDecoder()
        var bytes = Data()
        var count = 0
        for packet in packets {
            for event in try decoder.feed(packet) {
                switch event {
                case let .dataBytes(data): bytes += data
                case .dataPacketBegan: count += 1
                default: break
                }
            }
        }
        return (bytes, count)
    }

    @Test func aLimitShrinksEachPacketAndTheBytesAreStillTheObjects() throws {
        let length = 2500
        var packets = DataPhasePackets(transactionID: 7, phase: phase(length: length), packetSize: 1000)
        #expect(packets.nextPayloadSize == 0)                       // Start_Data carries none
        var sent: [Data] = [packets.next(payloadLimit: 1) ?? Data()]
        var sizes: [Int] = []
        while true {
            let wanted = packets.nextPayloadSize
            if wanted == 0 { break }
            let limit = min(wanted, 300)                            // the budget grants 300 at a time
            sizes.append(limit)
            sent.append(packets.next(payloadLimit: limit) ?? Data())
        }
        #expect(sizes.reduce(0, +) == length)
        #expect(sizes.dropLast().allSatisfy { $0 == 300 })
        #expect(packets.next() == nil)
        let (bytes, _) = try payload(of: sent)
        #expect(bytes == pattern(length))
    }

    @Test func noLimitMakesTheSamePacketsAsBefore() {
        var plain = DataPhasePackets(transactionID: 3, phase: phase(length: 2500), packetSize: 1000)
        var limited = DataPhasePackets(transactionID: 3, phase: phase(length: 2500), packetSize: 1000)
        while let a = plain.next() {
            #expect(limited.next(payloadLimit: 1000) == a)
        }
        #expect(limited.next(payloadLimit: 1000) == nil)
    }

    @Test func aLimitAboveThePacketSizeIsCappedByIt() throws {
        var packets = DataPhasePackets(transactionID: 1, phase: phase(length: 5000), packetSize: 1000)
        _ = packets.next()
        #expect(packets.nextPayloadSize == 1000)
        let first = packets.next(payloadLimit: 1_000_000) ?? Data()
        #expect(try payload(of: [first]).bytes.count == 1000)
    }

    @Test func anEmptyPhaseNeedsNoBudget() {
        var packets = DataPhasePackets(transactionID: 1, phase: phase(length: 0), packetSize: 1000)
        _ = packets.next()
        #expect(packets.nextPayloadSize == 0)
        #expect(packets.next(payloadLimit: 1) != nil)               // End_Data with no bytes
        #expect(packets.next(payloadLimit: 1) == nil)
    }
}
