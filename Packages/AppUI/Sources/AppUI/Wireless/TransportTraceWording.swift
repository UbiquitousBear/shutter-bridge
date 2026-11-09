import CameraTransport
import Foundation

// The bench log's lines for the Wi-Fi route (W20): each `TransportTraceEvent` CameraTransport records becomes one line in the
// unified log through `BenchLog` (`OSLogBenchLog` in the app: subsystem net.shamil.shutter-bridge, category browse). Plain
// Swift, tested on Linux. Lines start "wifi join:" (the session and the hand-off) or "wifi link:" (the camera's session over
// Wi-Fi). Times are seconds since the step named in the line, to a tenth; sizes in MiB with the bytes; counts as numbers.
//
// The events carry no network name, password, serial, peripheral or device identifier, GUID or address, so no line can
// either: the only address written is the camera's fixed gateway, 192.168.122.1, which is the same on every α7C II.

extension TransportTrace {
    /// Writes each event as one line to `log`.
    public static func bench(_ log: any BenchLog) -> TransportTrace {
        TransportTrace { event in log.note(TransportTraceWording.line(for: event)) }
    }
}

/// The line for each event. docs/iteration-3-4-bench.md ("What the log holds") quotes these formats.
public enum TransportTraceWording {
    public static func line(for event: TransportTraceEvent) -> String {
        switch event {
        // MARK: The session
        case let .preparationStarted(joined, bluetoothFirst):
            if !joined { return "wifi join: preparing an import: Bluetooth, then the join" }
            return bluetoothFirst
                ? "wifi join: preparing an import: the camera's Wi-Fi is presumed off, so Bluetooth first"
                : "wifi join: preparing an import on the camera's Wi-Fi, without a join"
        case let .stayReopenGaveUp(after):
            return "wifi join: reopening on the camera's Wi-Fi gave up after \(seconds(after)); going back to Bluetooth"
        case let .bluetoothConnected(after):
            return "wifi join: Bluetooth connected in \(seconds(after))"
        case let .bluetoothSignal(dBm, after):
            let strength = dBm.map { "\($0) dBm" } ?? "not available"
            // Counted from before the connect, like the hand-off's total; the CC09, CC08 and details lines count from the run.
            return "wifi join: Bluetooth RSSI \(strength), \(seconds(after)) into the Bluetooth step (connect included)"
        case let .bluetoothDropped(afterWrite, reconnect):
            return "wifi join: the Bluetooth link dropped during the hand-off"
                + (afterWrite ? " after the CC08 write" : "") + "; connecting again (reconnect \(reconnect))"
        case let .handoffFinished(after, rewrite, wroteWiFiOn, statusTwoAlready, windowLeft):
            let write = wroteWiFiOn ? "CC08 written" : "no CC08 write, the camera's Wi-Fi was already on"
            let left = (statusTwoAlready ? "at most " : "") + seconds(windowLeft)
            return "wifi join: \(rewrite ? "rewrite " : "")hand-off done in \(seconds(after)) (connect included): \(write); "
                + "\(left) left of the camera's 50 s"
        case let .joinApplied(attempt, after, failure):
            guard let failure else {
                return "wifi join: join \(attempt) returned after \(seconds(after)) (iOS's prompt included)"
            }
            return "wifi join: join \(attempt) failed after \(seconds(after)): \(failure)"
        case let .gateway(found, after):
            return found
                ? "wifi join: the camera's gateway \(WirelessCamera.cameraNetworkGateway) appeared \(seconds(after)) "
                    + "after the join"
                : "wifi join: the camera's gateway didn't appear within \(seconds(after)) of the join"
        case let .cameraWiFiChecked(check, windowPassed, off):
            let seen: String
            switch check {
            case let .read(status): seen = "CC09 Wi-Fi status \(statusWord(status))"
            case .linkDown: seen = "the Bluetooth link is down"
            case .readFailed: seen = "CC09 couldn't be read"
            case .noLink: seen = "no Bluetooth link is held"
            }
            let window = windowPassed ? "have passed" : "have not passed"
            let decision = off ? "its Wi-Fi is off, so switching it on again" : "its Wi-Fi is on, so joining again as it is"
            return "wifi join: after the join, \(seen); the camera's 50 s \(window); \(decision)"
        case let .rewriteStarted(number, limit):
            return "wifi join: rewriting CC08, rewrite \(number) of \(limit)"
        case let .rejoinedWhileAway(found, after):
            return found
                ? "wifi join: with the app away, iOS rejoined the camera's Wi-Fi \(seconds(after)) after the hand-off"
                : "wifi join: with the app away, iOS didn't rejoin the camera's Wi-Fi within \(seconds(after))"
        case let .sessionOpened(after, tries, reopening):
            return "wifi join: the camera's session opened \(seconds(after)) after the first try, \(count(tries, "try", "tries")) "
                + "(\(reopening ? "reopening" : "fresh"))"
        case let .sessionNotOpened(after, tries, refused):
            return "wifi join: the camera's session didn't open: \(refused ? "refused" : "no answer") after "
                + "\(seconds(after)), \(count(tries, "try", "tries"))"
        case let .preparationEnded(succeeded, times):
            return "wifi join: \(succeeded ? "ready" : "not ready") after \(seconds(times.total)) "
                + "(hand-off \(seconds(times.handingOff)), join \(seconds(times.joining)), "
                + "session \(seconds(times.openingSession)))"

        // MARK: The hand-off
        case let .handoffStatus(status, after):
            return "wifi join: CC09 Wi-Fi status \(statusWord(status)) at \(seconds(after)) into the hand-off"
        case let .handoffWroteWiFiOn(after):
            return "wifi join: CC08 written (Wi-Fi on) at \(seconds(after)) into the hand-off"
        case let .handoffDetailsRead(after, tries):
            return "wifi join: network details read at \(seconds(after)) into the hand-off, try \(tries)"

        // MARK: The Wi-Fi link
        case let .linkConnected(after, reopening):
            return "wifi link: the camera answered on its port \(seconds(after)) after the open began "
                + "(\(reopening ? "reopening" : "fresh"))"
        case let .linkOpened(after, reopening, wholeCard, polls, listedAfter, pollTimedOut):
            let kind = reopening ? "reopening" : "fresh"
            guard wholeCard else {
                return "wifi link: session open \(seconds(after)) after the open began, a plain session with no listing "
                    + "poll (\(kind))"
            }
            let listed = listedAfter.map { ", listed \(seconds($0)) after the first poll" } ?? ""
            let limit = pollTimedOut ? ", the poll reached its limit" : ""
            return "wifi link: card ready \(seconds(after)) after the open began, \(count(polls, "poll", "polls"))"
                + "\(listed)\(limit) (\(kind))"
        case let .keepAlive(number, answered, idle, sincePrevious):
            let previous = sincePrevious.map { "\(seconds($0)) after the previous keep-alive" } ?? "the first this session"
            return "wifi link: keep-alive \(number) \(answered ? "answered" : "not answered"), \(seconds(idle)) after the "
                + "last command, \(previous)"
        case let .resumeStarted(offset, size):
            return "wifi link: resuming a file with 0x9211 from \(mebibytes(offset)) (\(offset) B) of \(mebibytes(size))"
        case let .resumeRefused(offset):
            return "wifi link: the camera refused the first 0x9211 read at \(mebibytes(offset)) (\(offset) B); copying "
                + "the file again from the start"
        case let .resumeFinished(reads):
            return "wifi link: the resumed file finished after \(count(reads, "0x9211 read", "0x9211 reads"))"
        case let .linkLost(failure):
            return "wifi link: the session was lost: \(lossReason(failure))"
        case let .linkClosed(seen):
            guard seen.sessionsOpened > 0 else { return "wifi link: closed without opening a session" }
            return "wifi link: closed: sessions opened \(seen.sessionsOpened), lost \(seen.sessionsLost); keep-alives "
                + "answered \(seen.keepAlivesAnswered), failed \(seen.keepAlivesFailed); GetDevicePropValue sent "
                + "\(seen.devicePropValueReads); 0x9211 resumes \(seen.resumes), reads \(seen.partialReads), refused "
                + "\(seen.resumeFallbacks); transfers aborted \(seen.transfersAborted)"
        }
    }

    // MARK: Parts

    /// Seconds to a tenth, rounded half up, never negative: "8.0 s".
    static func seconds(_ duration: Duration) -> String {
        let (whole, attoseconds) = duration.components
        let milliseconds = whole * 1_000 + attoseconds / 1_000_000_000_000_000
        let tenths = max(0, (milliseconds + 50) / 100)
        return "\(tenths / 10).\(tenths % 10) s"
    }

    /// MiB to a tenth, rounded half up: "16.0 MiB".
    static func mebibytes(_ bytes: UInt64) -> String {
        let tenths = (bytes / 1_048_576) * 10 + ((bytes % 1_048_576) * 10 + 524_288) / 1_048_576
        return "\(tenths / 10).\(tenths % 10) MiB"
    }

    /// CC09's Wi-Fi status as a number and a word; a value outside 0 to 3 isn't written out.
    static func statusWord(_ status: UInt8?) -> String {
        switch status {
        case 0?: "0 (off)"
        case 1?: "1 (starting)"
        case 2?: "2 (on)"
        case 3?: "3 (stopping)"
        case .some: "an unknown value"
        case nil: "unreadable"
        }
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }

    /// Why a session was lost, in words. The connection's own text (a protocol violation's, a sink's) is left out.
    static func lossReason(_ failure: PTPIPConnectionFailure?) -> String {
        guard let failure else { return "the camera answered SessionNotOpen" }
        switch failure {
        case .refused: return "the camera refused the connection"
        case .timedOut: return "no answer in time"
        case .linkLost: return "the network went away"
        case .closed: return "the camera closed the connection"
        case .aborted: return "the app cut the transfer off"
        case .protocolViolation: return "the camera's bytes broke PTP/IP"
        case .sinkFailed: return "writing the file failed"
        case .cancelled, .cancelledBeforeStart: return "cancelled"
        case .busy, .notConnected, .alreadyUsed, .invalidCommand: return "a call out of turn"
        }
    }
}
