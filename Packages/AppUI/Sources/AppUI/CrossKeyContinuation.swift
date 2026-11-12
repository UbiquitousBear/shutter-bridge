import CameraTransport
import Catalogue
import Foundation
import ImportEngine

/// Whether a card holds a paused job's files (D11; Shamil, 12 Nov: a paused USB job continued across MSC and MTP by
/// content): how many of the files the job has left are on it, matched as the engine's `remap` finds them again (name
/// ignoring ASCII case, capture time to the second, size; never the camera key or the folder).
///
/// - On **another camera key** (the same body in the other Image Transfer mode) the job continues only when the card
///   holds every file it has left (`continues`). A partial match, or nothing left known (the job paused before its first
///   listing), never continues: the job waits for its own camera, and nothing is lost.
/// - On the job's **own key, when that key is a name hash** (`usb-msc-name:`, `usb-mtp-name:`: every "Untitled" card on
///   any body shares it), the job continues when the card holds at least one file it has left (`holdsAny`), so a
///   swapped card or another body isn't taken for the job's camera, while its own card with a photo deleted since still
///   is (the deleted one is skipped as "no longer on the card", as before).
struct CrossKeyContinuation: Sendable, Hashable {
    /// How many files the job has left.
    let left: Int
    /// How many of them the card holds.
    let found: Int

    /// Every file left is on the card, and there is at least one.
    var continues: Bool { left > 0 && found == left }
    /// At least one file left is on the card.
    var holdsAny: Bool { found > 0 }

    init(left: Set<ObjectIdentity.ContentKey>, listing: [CameraItem], camera: CameraKey, timeZone: TimeZone) {
        let onCard = Set(listing.lazy.compactMap { $0.identity(camera: camera, timeZone: timeZone)?.contentKey })
        self.left = left.count
        found = left.filter(onCard.contains).count
    }

    /// The content keys of the job's files still to be copied from the camera: queued (a RAW+JPEG half held for its
    /// partner reads queued too), downloading or waiting to retry. Files being committed or resolved, and picks with no
    /// capture date (no identity), aren't.
    static func filesLeft(in files: [ImportFileStatus]) -> Set<ObjectIdentity.ContentKey> {
        Set(files.compactMap { file -> ObjectIdentity.ContentKey? in
            guard case let .file(identity) = file.id else { return nil }
            switch file.phase {
            case .queued, .downloading, .waitingToRetry: return identity.contentKey
            default: return nil
            }
        })
    }

    /// Whether `key` is a name hash that bodies can share, so the job's own key is checked by content too.
    static func isSharedKey(_ key: CameraKey) -> Bool {
        key.rawValue.hasPrefix("usb-msc-name:") || key.rawValue.hasPrefix("usb-mtp-name:")
    }
}
