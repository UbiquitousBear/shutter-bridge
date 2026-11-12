import Foundation
import PTPKit

/// A link that can say how much space is free on the camera's card, for the Cameras screen's "12.3 GB free" (backlog
/// section 9, I17). `USBLink` conforms (behind `canImport(ImageCaptureCore)`); a test fake in AppUI's tests.
public protocol CardFreeSpaceReading: Sendable {
    /// The free space on the camera's card, in bytes, or nil when it can't be read now: another mode than Image
    /// Transfer (MTP), the catalogue not complete yet, a download in flight, the camera not answering, or no store
    /// that reports a capacity. Never throws and never shows as 0 for unknown: the screen leaves the line out.
    func cardFreeSpace() async -> UInt64?
}

/// The transport-neutral half of the free-space read: when a USB link may ask, the two PTP requests it sends through
/// ImageCaptureCore's pass-through (GetStorageIDs, then GetStorageInfo for each logical store), and the sum of what
/// they report. Pure, so it is tested on Linux with a fake pass-through; `USBLink` supplies the real one.
///
/// The bench read the card's free space this way in Image Transfer (MTP) on 1 Nov (spike build 3, *GetStorageIDs +
/// GetStorageInfo*, after the catalogue). In Image Transfer (MSC) the camera answers no PTP command (a request never
/// completed), and in Remote Shoot (PC Remote) the catalogue lists no files, so the read is MTP only; asking during
/// MTP's 65–123 s catalogue or alongside a download is untried, so it waits for both to be over.
public enum CardFreeSpace {
    /// How long one request waits before the read gives up (the thumbnails' limit; GetStorageInfo answered at once on
    /// the bench).
    public static let requestLimit: Duration = .seconds(10)

    /// Whether a USB link in `mode` may send the requests now.
    public static func mayAsk(mode: USBMode, catalogueComplete: Bool, downloadsInFlight: Int) -> Bool {
        mode == .mtp && catalogueComplete && downloadsInFlight == 0
    }

    /// The free bytes over the stores that report a capacity (a store with capacity 0 reports nothing, as the Wi-Fi
    /// session's does), saturating rather than overflowing; nil when no store reports one.
    public static func total(of stores: [PTPStorageInfo]) -> UInt64? {
        let reporting = stores.filter { $0.maxCapacity > 0 }
        guard !reporting.isEmpty else { return nil }
        return reporting.reduce(UInt64(0)) { sum, store in
            let free = min(store.freeSpaceInBytes, store.maxCapacity)
            let (added, overflow) = sum.addingReportingOverflow(free)
            return overflow ? .max : added
        }
    }

    /// Sends GetStorageIDs, then GetStorageInfo for each store that has a logical store (an empty slot has none),
    /// through `send`, which hands back the two values ImageCaptureCore's pass-through completes with. Nil when a
    /// request throws, a reply can't be decoded or isn't OK, or no store reports a capacity: the free space is then
    /// unknown, which the screen doesn't show. The storage's description and volume label are read but never kept.
    public static func read(
        send: @Sendable (PTPContainer) async throws -> (first: Data, second: Data)
    ) async -> UInt64? {
        var transaction: UInt32 = 1
        func transact(_ build: (UInt32) -> PTPContainer) async -> Data? {
            let command = build(transaction)
            transaction += 1
            guard let raw = try? await send(command),
                  let reply = try? PTPPassThrough.decodeReply(raw.first, raw.second, for: command),
                  reply.responseCode.isOK else { return nil }
            return reply.data
        }
        guard let idData = await transact({ PTPCommand.getStorageIDs(tx: $0) }),
              let ids = try? PTPStorageID.decodeArray(idData) else { return nil }
        var stores: [PTPStorageInfo] = []
        for id in ids where id.hasLogicalStore {
            guard let infoData = await transact({ PTPCommand.getStorageInfo(id, tx: $0) }),
                  let info = try? PTPStorageInfo.decode(infoData) else { return nil }
            stores.append(info)
        }
        return total(of: stores)
    }
}
