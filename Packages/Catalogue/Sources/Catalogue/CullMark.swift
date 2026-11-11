import Foundation

/// The person's mark on one file while culling, as the catalogue keeps it in its `CullMark` rows (decision-pack 3.21 B;
/// D4, Shamil, 11 Nov): *Keep* or *Reject*, a rating of 0 to 5 stars (0 is no stars), and when it was set. Written with
/// `CatalogueStore.setMark(_:rating:for:)` and read with `marks(of:)`. (AppUI's cull session has its own `CullMark`,
/// without the date; this is the stored record, named as `JobRecord` and `CameraRecord` are.)
///
/// **Kept by content key**, the file name ignoring ASCII case, the capture second and the size
/// (`ObjectIdentity.ContentKey`), not on the file's row: so a mark follows the file between the card and Staging,
/// exists for a file with no row under that camera, and survives *Forget imports* (D6). One mark per RAW+JPEG pair,
/// stored per file: both halves are written in one call. Catalogue only: no sidecar, nothing written to the card or
/// the staged file (D4).
public struct MarkRecord: Sendable, Hashable, Codable {
    /// *Keep* or *Reject*, with AppUI's `CullDecision`'s raw values.
    public enum Decision: String, Sendable, Hashable, Codable, CaseIterable {
        case keep
        case reject
    }

    /// The decision; nil when the file is only rated.
    public var decision: Decision?
    /// 0 to 5 stars (`ratings`); 0 is no stars.
    public var rating: Int
    /// When the mark was set.
    public var markedAt: Date

    /// The ratings a mark may carry.
    public static let ratings: ClosedRange<Int> = 0 ... 5

    public init(decision: Decision?, rating: Int = 0, markedAt: Date) {
        self.decision = decision
        self.rating = rating
        self.markedAt = markedAt
    }
}

/// The marking rules, for both stores.
enum MarkRule {
    /// The mark `setMark` stores, or nil when it stores none (no decision and no stars: the same as clearing, as an
    /// unmarked mark is in AppUI's cull session). Throws `CatalogueFailure.ratingOutOfRange` for a rating outside
    /// 0...5.
    static func mark(_ decision: MarkRecord.Decision?, rating: Int, at date: Date) throws(CatalogueFailure)
        -> MarkRecord? {
        guard MarkRecord.ratings.contains(rating) else { throw .ratingOutOfRange(rating) }
        guard decision != nil || rating > 0 else { return nil }
        return MarkRecord(decision: decision, rating: rating, markedAt: date)
    }

    /// The mark to answer with among several for one content key (a later sync could leave two): the latest, then a
    /// reject over a keep, then the higher rating, so the answer doesn't depend on the order the rows were read in.
    static func preferred(_ a: MarkRecord, over b: MarkRecord) -> Bool {
        if a.markedAt != b.markedAt { return a.markedAt > b.markedAt }
        if rank(a) != rank(b) { return rank(a) > rank(b) }
        return a.rating > b.rating
    }

    private static func rank(_ mark: MarkRecord) -> Int {
        switch mark.decision {
        case .reject: 2
        case .keep: 1
        case nil: 0
        }
    }
}

extension ObjectIdentity.ContentKey {
    /// One string per content key, for the `CullMark` row's lookups: every component length-prefixed (in UTF-8 bytes),
    /// as `ObjectIdentity.storageKey` is, from the already-folded name. Versioned, so a later change of form is a
    /// planned migration rather than a silent mismatch.
    var storageKey: String {
        var key = "c1"
        for part in [filename, captureDate.rawValue, String(size)] {
            key += "|\(part.utf8.count):\(part)"
        }
        return key
    }
}

/// One `CullMark` row's columns as plain values, so the mapping is unit-tested on Linux; the SwiftData model only
/// copies these. The decision is its raw string, so a value a later version adds reads back as no decision, not a
/// failure.
struct CullMarkColumns: Sendable, Hashable {
    /// `ObjectIdentity.ContentKey.storageKey`: unique, by the store's rule.
    var contentKey: String
    /// The name with ASCII letters upper-cased, as the content key holds it.
    var filename: String
    /// `YYYYMMDDThhmmss`, the camera's wall clock.
    var captureDate: String
    var size: Int64
    /// `MarkRecord.Decision`'s raw value; nil when only rated.
    var mark: String?
    /// 0 to 5; nil reads as no stars.
    var rating: Int?
    var markedAt: Date?
}

extension CullMarkColumns {
    init(_ mark: MarkRecord, for key: ObjectIdentity.ContentKey) {
        self.init(contentKey: key.storageKey, filename: key.filename, captureDate: key.captureDate.rawValue,
                  size: Int64(bitPattern: key.size), mark: mark.decision?.rawValue, rating: mark.rating,
                  markedAt: mark.markedAt)
    }

    /// The mark this row holds. A rating outside 0...5 (which no version of this code writes) reads as no stars.
    var markRecord: MarkRecord {
        MarkRecord(decision: mark.flatMap(MarkRecord.Decision.init(rawValue:)),
                   rating: rating.flatMap { MarkRecord.ratings.contains($0) ? $0 : nil } ?? 0,
                   markedAt: markedAt ?? .distantPast)
    }
}
