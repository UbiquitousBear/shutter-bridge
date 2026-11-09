import PTPKit

/// From the camera's PTP/IP events to `CameraLinkEvent`s, for one whole-card session (backlog Iteration 3, section 4,
/// *Events*). Pure, so it is tested on Linux; `IPLink` keeps one per session and feeds it every event in arrival order.
///
/// - **StoreRemoved** (0x4005) becomes `.storeRemoved`, and the card counts as removed until StoreAdded. The camera
///   dropped its card this way on 3 and 4 Nov, then answered StoreNotAvailable and InvalidObjectHandle, then switched
///   its Wi-Fi off about 6 s later.
/// - **StoreAdded** (0x4004) becomes `.storeAdded` only when it brings a removed card back. The first StoreAdded of a
///   session is the card arriving after SDIO_SetContentsTransferMode `[2, 1, 0]` (fixture `event-4004.bin`,
///   `[0x00010001]`), part of opening rather than news: forwarding it would make the engine list again for nothing.
/// - **Everything else** is ignored and its code kept for the log: Sony's ObjectAdded 0xC201 (with the buffer slot
///   0xFFFFC001, not a card handle; ObjectAdded isn't acted on in 1.0), the two 0xC225 seen on a reopen (meaning
///   unknown), 0xC223 shutter state, standard ObjectAdded, and any code not known here.
struct IPEventMapper: Sendable, Equatable {
    /// What one event comes to.
    enum Mapped: Sendable, Equatable {
        /// Send this to the link's readers.
        case forward(CameraLinkEvent)
        /// Note the code in the log and do nothing.
        case ignore(PTPEventCode)
    }

    /// StoreRemoved has come and StoreAdded hasn't since.
    private(set) var cardRemoved = false
    /// A StoreAdded has come in this session (the card's arrival, or its return).
    private(set) var storeAddedSeen = false

    mutating func map(_ event: PTPIP.Event) -> Mapped {
        switch SonySessionEvent(event) {
        case .storeRemoved:
            cardRemoved = true
            return .forward(.storeRemoved)
        case .storeAdded:
            storeAddedSeen = true
            guard cardRemoved else { return .ignore(event.code) }
            cardRemoved = false
            return .forward(.storeAdded)
        case .objectAdded, .other:
            return .ignore(event.code)
        }
    }
}
