import Catalogue
import Foundation
import Observation

/// Keep or Reject.
public enum CullDecision: String, Sendable, Hashable, CaseIterable {
    case keep
    case reject
}

/// What the person has said about one unit: a decision (nil while unmarked) and an optional rating from 0 to 5
/// (0 is no stars). One mark for a RAW+JPEG pair (D4); the catalogue stores it per file, under each content key.
public struct CullMark: Sendable, Hashable {
    public static let ratingRange = 0 ... 5
    public static let unmarked = CullMark()

    public var decision: CullDecision?
    /// Always within `ratingRange`.
    public private(set) var rating: Int

    public init(decision: CullDecision? = nil, rating: Int = 0) {
        self.decision = decision
        self.rating = min(max(rating, Self.ratingRange.lowerBound), Self.ratingRange.upperBound)
    }

    public var isUnmarked: Bool { self == .unmarked }

    /// The unit's mark in `marks`: the one under its own key, else the first marked half of a pair, else unmarked.
    public static func of(_ unit: CullUnit, in marks: [ObjectIdentity.ContentKey: CullMark]) -> CullMark {
        if let mark = marks[unit.id] { return mark }
        for key in unit.keys.dropFirst() {
            if let mark = marks[key], !mark.isUnmarked { return mark }
        }
        return .unmarked
    }
}

/// Where marks are saved. The catalogue's side (`CullMark` rows, `setMark(_:rating:for:)`, `clearMarks(of:)`) is I7's;
/// the session only knows this.
public protocol CullMarkWriting: Sendable {
    /// Saves `mark` under every key, together (both halves of a pair). An unmarked mark clears them.
    func write(_ mark: CullMark, for keys: [ObjectIdentity.ContentKey]) async throws
}

/// A mark that couldn't be saved; the screen says so, and the unit shows its earlier mark again.
public struct CullWriteFailure: Sendable, Hashable {
    public var unit: CullUnit.ID
    /// For the log only; never shown, and never a file name or identity.
    public var detail: String
}

/// The loupe's state over one list of units (a day's, or all of a camera's): where the person is, every unit's mark,
/// and an undo of the last mark. Pure logic on the main actor, so it runs on Linux against a fake writer.
///
/// - **Marks apply at once** in memory and are saved in order, one write after another, so a slow store never
///   reorders two marks on the same unit. A failed write puts back the last mark the store accepted for that unit (if
///   nothing newer has replaced the failed one) and sets `writeFailure`.
/// - **Undo** reverts the last mark made (up to `undoLimit` of them), shows that unit again and saves the earlier
///   mark. There is no redo.
/// - Navigation never wraps: at either end it stays put and says so.
@MainActor
@Observable
public final class CullSession {
    /// How many marks can be undone.
    public static let undoLimit = 100

    public let units: [CullUnit]
    public private(set) var index: Int
    public private(set) var marks: [CullUnit.ID: CullMark] = [:]
    public private(set) var writeFailure: CullWriteFailure?
    /// When true, a Keep or Reject on the current unit moves on to the next one (not past the last).
    public var advancesAfterDecision = false

    private struct UndoEntry {
        var unit: CullUnit.ID
        var before: CullMark
        var after: CullMark
    }

    @ObservationIgnored private var undoStack: [UndoEntry] = []
    @ObservationIgnored private let writer: any CullMarkWriting
    @ObservationIgnored private let indexByID: [CullUnit.ID: Int]
    @ObservationIgnored private var writeTail: Task<Void, Never>?
    /// The last mark the store accepted for each unit (absent: unmarked), seeded from the catalogue's marks.
    @ObservationIgnored private var saved: [CullUnit.ID: CullMark] = [:]

    /// - Parameters:
    ///   - marks: what the catalogue holds, by content key (a unit's mark is read under its keys, see `CullMark.of`).
    ///   - startingAt: clamped into the list.
    public init(units: [CullUnit], marks: [ObjectIdentity.ContentKey: CullMark] = [:], startingAt: Int = 0,
                writer: any CullMarkWriting) {
        self.units = units
        self.writer = writer
        self.index = units.isEmpty ? 0 : min(max(startingAt, 0), units.count - 1)
        var lookup: [CullUnit.ID: Int] = [:]
        var initial: [CullUnit.ID: CullMark] = [:]
        for (i, unit) in units.enumerated() where lookup[unit.id] == nil {
            lookup[unit.id] = i
            let mark = CullMark.of(unit, in: marks)
            if !mark.isUnmarked { initial[unit.id] = mark }
        }
        self.marks = initial
        self.saved = initial
        self.indexByID = lookup
    }

    // MARK: Navigation

    public var current: CullUnit? { units.indices.contains(index) ? units[index] : nil }
    public var count: Int { units.count }
    public var canGoNext: Bool { index + 1 < units.count }
    public var canGoPrevious: Bool { index > 0 }

    /// Moves one unit on; false (and no move) at the last.
    @discardableResult
    public func next() -> Bool {
        guard canGoNext else { return false }
        index += 1
        return true
    }

    /// Moves one unit back; false (and no move) at the first.
    @discardableResult
    public func previous() -> Bool {
        guard canGoPrevious else { return false }
        index -= 1
        return true
    }

    /// Moves to `position` if it is in the list.
    @discardableResult
    public func go(to position: Int) -> Bool {
        guard units.indices.contains(position) else { return false }
        index = position
        return true
    }

    /// Moves to the next unit after the current one that has no decision (a rating alone doesn't count), if any.
    @discardableResult
    public func goToNextUnmarked() -> Bool {
        guard let found = units.indices.dropFirst(index + 1).first(where: { mark(of: units[$0]).decision == nil })
        else { return false }
        index = found
        return true
    }

    // MARK: Marks

    public func mark(of unit: CullUnit) -> CullMark { marks[unit.id] ?? .unmarked }
    public var currentMark: CullMark { current.map(mark(of:)) ?? .unmarked }

    public func keep() { setDecision(.keep) }
    public func reject() { setDecision(.reject) }

    /// Sets (or, with nil, clears) the current unit's decision, keeping its rating.
    public func setDecision(_ decision: CullDecision?) {
        guard let unit = current else { return }
        var mark = mark(of: unit)
        mark.decision = decision
        apply(mark, to: unit)
        if advancesAfterDecision, decision != nil { next() }
    }

    /// Sets the current unit's rating, clamped to 0...5, keeping its decision.
    public func setRating(_ rating: Int) {
        guard let unit = current else { return }
        var mark = mark(of: unit)
        mark = CullMark(decision: mark.decision, rating: rating)
        apply(mark, to: unit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    /// Reverts the last mark, shows its unit and saves the earlier mark. False when there is nothing to undo.
    @discardableResult
    public func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        guard let position = indexByID[entry.unit] else { return false }
        index = position
        marks[entry.unit] = entry.before.isUnmarked ? nil : entry.before
        enqueueWrite(entry.before, for: units[position])
        return true
    }

    private func apply(_ new: CullMark, to unit: CullUnit) {
        let old = mark(of: unit)
        guard new != old else { return }
        undoStack.append(UndoEntry(unit: unit.id, before: old, after: new))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        marks[unit.id] = new.isUnmarked ? nil : new
        enqueueWrite(new, for: unit)
    }

    // MARK: Saving

    /// Waits until every mark made so far has been saved or has failed.
    public func settled() async {
        var waited: Task<Void, Never>?
        while let tail = writeTail, tail != waited {
            waited = tail
            await tail.value
        }
    }

    public func dismissWriteFailure() { writeFailure = nil }

    private func enqueueWrite(_ mark: CullMark, for unit: CullUnit) {
        let previous = writeTail
        let (writer, keys, id) = (writer, unit.keys, unit.id)
        writeTail = Task {
            await previous?.value
            do {
                try await writer.write(mark, for: keys)
                self.saved[id] = mark.isUnmarked ? nil : mark
            } catch {
                // Only if nothing newer has replaced the mark: a later change owns the unit now. Back to what the
                // store holds, which is not always the mark this change replaced (that one may have failed too).
                if self.mark(of: unit) == mark {
                    self.marks[id] = self.saved[id]
                    self.undoStack.removeAll { $0.unit == id && $0.after == mark }
                }
                self.writeFailure = CullWriteFailure(unit: id, detail: String(describing: type(of: error)))
            }
        }
    }

    // MARK: What to import

    /// The units marked Keep, in list order.
    public var keepers: [CullUnit] { units.filter { mark(of: $0).decision == .keep } }
    public var rejects: [CullUnit] { units.filter { mark(of: $0).decision == .reject } }

    /// Every file of every keeper, a pair's RAW first: what *Import keepers* is handed.
    public var keeperFiles: [CullFile] { keepers.flatMap(\.files) }

    public var counts: CullCounts {
        var byKey: [ObjectIdentity.ContentKey: CullMark] = [:]
        for (id, mark) in marks { byKey[id] = mark }
        return CullCounts(units: units, marks: byKey)
    }
}
