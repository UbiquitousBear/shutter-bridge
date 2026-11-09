import Foundation
import PTPKit

extension IPLink {
    /// How an `IPLink` reaches its camera and runs its session. Every timing is a named value with what it rests on
    /// (wireless plan, decision 8).
    public struct Configuration: Sendable {
        /// Where the camera's PTP/IP responder listens: 192.168.122.1:15740 on the camera's own network (the 1.0
        /// route, fixed on the α7C II).
        public var endpoint: PTPIPEndpoint = .cameraNetwork
        /// The initiator GUID, kept per camera in the catalogue (`ptpipGUID`). A new GUID connected with no prompt on
        /// the camera and so did the same GUID after a power cycle (backlog Iteration 3, section 1), so it only lets
        /// the camera recognise the phone.
        public var guid: UUID
        /// The initiator name the camera may show. Generic wording, no Sony marks.
        public var friendlyName = "Shutter Bridge"
        /// The serial the app knows for this camera (from an earlier session's DeviceInfo, where the PTP/IP
        /// DeviceInfo carries it). A session whose DeviceInfo shows another serial is refused as `identityChanged`
        /// and nothing is listed (camera pinning, backlog B:68). Nil or empty for a camera seen for the first time:
        /// the link then pins the first session's serial and holds every reopen in its life to it.
        public var knownSerial: String?
        /// The keep-alive: GetDeviceInfo once the session has been idle this long, never during a transaction
        /// (backlog B:117; `SonyContentsTransferPlan.keepAliveInterval`, the spike's 10 s, which kept sessions up
        /// where the camera is reported to drop them after about 30 s idle). Nil turns it off.
        public var keepAlive: Duration? = SonyContentsTransferPlan.wholeCard().keepAliveInterval
        /// The first open is a reopen of a session the app had a moment ago (after a pause, or a lost session in an
        /// earlier link): the listing poll gives up after 30 s instead of 120 s (`SonyContentsTransferPlan
        /// .wholeCard(reopening:)`; a reopen after a drop took about 2.5 s in the spike). A reopen of this link after
        /// `.sessionLost` always counts as one.
        public var reopening = false
        /// The connection's time limits: connect 10 s, Init acks 60 s (a first ack can take 40 s or more), 30 s for the
        /// next bytes of a reply (the plan's `replyTimeout`), 60 s while a channel waits for the Local Network prompt
        /// (`unverified`). Every command has a limit; a download has none as a whole, only between its reads (B:72).
        public var timing = PTPIPConnection.Timing()
        /// The zone the camera's clock is in. The α7C II's DateTime strings carry none (`YYYYMMDDThhmmss`), so its
        /// wall-clock time is read in this zone, as Photos reads the same EXIF value.
        public var timeZone: TimeZone = .current

        public init(guid: UUID, endpoint: PTPIPEndpoint = .cameraNetwork, friendlyName: String = "Shutter Bridge",
                    knownSerial: String? = nil) {
            self.guid = guid
            self.endpoint = endpoint
            self.friendlyName = friendlyName
            self.knownSerial = knownSerial
        }

        /// The session plan for an open: the whole-card plan, with the 30 s poll limit for a reopen.
        func plan(reopening: Bool) -> SonyContentsTransferPlan {
            SonyContentsTransferPlan.wholeCard(reopening: reopening || self.reopening)
        }
    }
}
