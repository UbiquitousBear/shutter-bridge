// The pairing check for onboarding (docs/iteration-3-4-backlog.md section 6): connect, turn Sony's five notifications on,
// read CC09 with nobody's patience limit, and say what happened.

import BLEKit
import Foundation

public enum PairingOutcome: Sendable, Equatable {
    /// The first protected read came back at once: iOS already held a pairing (Creators' App's, for one). Onboarding skips
    /// its explanation.
    case alreadyPaired
    /// The read waited for the person (iOS's pairing request and the camera's confirmation) and then came back.
    case paired
    /// The camera refused the read (ATT "insufficient encryption" or "insufficient authentication"): it isn't paired with
    /// this phone, or its Pairing screen isn't open. Send the person to MENU › Network › Bluetooth › Pairing. Never retried.
    case notPaired
    /// The person pressed *Cancel* (the task was cancelled).
    case cancelled
    /// Nothing about pairing could be learnt: Bluetooth is off or not allowed, the camera wasn't found, the link dropped
    /// twice, or something unexpected. The failure says which.
    case unavailable(GATTFailure)
}

public struct PairingCheck: Sendable {
    private let clock: any Clock<Duration>

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Runs the check.
    ///
    /// - The first protected read, CC09, has no timeout: with the camera's Pairing screen open it starts iOS's pairing
    ///   request and the camera's confirmation, and returned 12.3 s after it was sent with both accepted (4 Nov 13:06).
    ///   Cancelling the task cancels the read and closes the link.
    /// - Whether the phone was already paired is told by how long the read took (`HandoffTiming.pairingPromptThreshold`).
    /// - A dropped link is retried once, from a fresh connection (opening the Pairing screen can drop an existing link: 5 Nov
    ///   01:19:41). A second drop is `unavailable(.linkDropped)`.
    /// - `notPaired` is final. It never loops.
    ///
    /// - Returns: the outcome, and the camera's peripheral identifier whenever a link was made (the identifier was the same
    ///   across removing and redoing the pairing, so onboarding stores it even for `notPaired`), else nil.
    public func run(connector: any GATTConnector, known: PeripheralID?) async -> (PairingOutcome, PeripheralID?) {
        var known = known
        var identifier: PeripheralID?
        for attempt in 1 ... 2 {
            switch await once(connector: connector, known: known) {
            case .finished(let outcome, let id):
                return (outcome, id ?? identifier)
            case .dropped(let id):
                identifier = id ?? identifier
                known = identifier ?? known
                if Task.isCancelled { return (.cancelled, identifier) }
                if attempt == 2 { return (.unavailable(.linkDropped), identifier) }
            }
        }
        return (.unavailable(.linkDropped), identifier) // unreachable: the second attempt always returns above
    }

    private enum Attempt {
        case finished(PairingOutcome, PeripheralID?)
        case dropped(PeripheralID?)
    }

    private func once(connector: any GATTConnector, known: PeripheralID?) async -> Attempt {
        let link: any GATTLink
        do throws(GATTFailure) { link = try await connector.connect(known: known) }
        catch { return conclude(error, id: nil) }
        let id = link.peripheral

        do throws(GATTFailure) {
            _ = try await NotificationSwitches.turnOn(link)
            let started = ClockMark.now(on: clock)
            _ = try await link.read(.status, timeout: nil)
            let took = started.elapsed
            if Task.isCancelled {
                await link.disconnect()
                return .finished(.cancelled, id)
            }
            _ = await NotificationSwitches.turnOff(link)
            await link.disconnect()
            return .finished(took < HandoffTiming.pairingPromptThreshold ? .alreadyPaired : .paired, id)
        } catch {
            await link.disconnect()
            return conclude(error, id: id)
        }
    }

    private func conclude(_ error: GATTFailure, id: PeripheralID?) -> Attempt {
        if Task.isCancelled { return .finished(.cancelled, id) }
        switch error {
        case .notPaired: return .finished(.notPaired, id)
        case .cancelled: return .finished(.cancelled, id)
        case .linkDropped: return .dropped(id)
        default: return .finished(.unavailable(error), id)
        }
    }
}
