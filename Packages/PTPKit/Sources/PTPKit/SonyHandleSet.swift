// The handles a Sony whole-card session listed, and what changed since: a pure diff, no I/O.
//
// Over Wi-Fi the α7C II kept every file's handle across sessions in the spike (DSC02046.ARW kept 0x400010A3 on
// 2 Nov; all 336 files matched after the 23:51 Continue and all 298 after the 01:08 recovery; docs/spike-findings.md),
// so a reopened session needs GetObjectInfo (about 11–17 ms each) only for handles it hasn't seen. A handle is a hint,
// not an identity: the caller still checks name and size before it resumes or skips a file. How much time the diff
// saves against the spike's 8.3 s relist is unmeasured.

import Foundation

/// A set of object handles in the order they were listed, with the two questions a relist asks: which handles of the
/// current listing haven't been seen (`unseen(in:)`, the only ones that need GetObjectInfo), and which listed ones
/// have gone (`gone(in:)`).
///
/// Equality compares membership only, not order. Duplicates collapse to their first position.
public struct SonyHandleSet: Sendable, Equatable {
    /// The handles in listing order, each once.
    public let handles: [UInt32]
    private let members: Set<UInt32>

    public init(_ handles: some Sequence<UInt32>) {
        var seen = Set<UInt32>()
        var ordered: [UInt32] = []
        for handle in handles where seen.insert(handle).inserted { ordered.append(handle) }
        self.handles = ordered
        self.members = seen
    }

    public var count: Int { handles.count }
    public var isEmpty: Bool { handles.isEmpty }
    public func contains(_ handle: UInt32) -> Bool { members.contains(handle) }

    /// The handles of `current` that this set doesn't hold, in `current`'s order: the ones to ask GetObjectInfo for.
    public func unseen(in current: SonyHandleSet) -> [UInt32] {
        current.handles.filter { !members.contains($0) }
    }

    /// The handles of this set that `current` no longer holds, in this set's order.
    public func gone(in current: SonyHandleSet) -> [UInt32] {
        handles.filter { !current.members.contains($0) }
    }

    public static func == (lhs: SonyHandleSet, rhs: SonyHandleSet) -> Bool { lhs.members == rhs.members }
}
