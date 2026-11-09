import Testing
@testable import PTPKit

@Suite("Sony handle set")
struct SonyHandleSetTests {
    @Test func aNewListingIsAllUnseen() {
        let before = SonyHandleSet([])
        let now = SonyHandleSet([0x4000_10A3, 0x4000_10A4])
        #expect(before.unseen(in: now) == [0x4000_10A3, 0x4000_10A4])
        #expect(before.gone(in: now).isEmpty)
    }

    @Test func aRelistOfTheSameCardAsksForNothing() {
        let listed = SonyHandleSet([5, 6, 7])
        let current = SonyHandleSet([5, 6, 7])
        #expect(listed.unseen(in: current).isEmpty && listed.gone(in: current).isEmpty)
        #expect(listed == current)
    }

    @Test func unseenKeepsTheCurrentListingsOrder() {
        let listed = SonyHandleSet([1, 2, 3])
        // The camera's order is the caller's: the diff keeps it, so a newest-first listing stays newest first.
        let current = SonyHandleSet([9, 3, 8, 2, 1, 7])
        #expect(listed.unseen(in: current) == [9, 8, 7])
        #expect(listed.gone(in: current).isEmpty)
    }

    @Test func goneKeepsTheListedOrder() {
        let listed = SonyHandleSet([10, 20, 30, 40])
        let current = SonyHandleSet([20, 40, 50])
        #expect(listed.gone(in: current) == [10, 30])
        #expect(listed.unseen(in: current) == [50])
    }

    @Test func aReusedHandleLooksSeenSoIdentityMustDecide() {
        // Handles are only a hint: a different card can reuse a number, which the set reports as seen. The
        // caller's name and size check is what catches it.
        let listed = SonyHandleSet([1, 2, 3])
        let swapped = SonyHandleSet([2, 8])
        #expect(listed.unseen(in: swapped) == [8])
        #expect(listed.gone(in: swapped) == [1, 3])
    }

    @Test func duplicatesCollapseAndEqualityIgnoresOrder() {
        let a = SonyHandleSet([3, 1, 3, 2, 1])
        #expect(a.count == 3 && a.handles == [3, 1, 2])
        #expect(a == SonyHandleSet([1, 2, 3]))
        #expect(a != SonyHandleSet([1, 2]))
        #expect(a.contains(2) && !a.contains(4))
        #expect(SonyHandleSet([]).isEmpty && !a.isEmpty)
    }

    @Test func aLargeCardDiffsInOneLinearPass() {
        let listed = SonyHandleSet(0 ..< 5_000)
        let current = SonyHandleSet(100 ..< 5_050)
        #expect(listed.unseen(in: current) == Array(5_000 ..< 5_050))
        #expect(listed.gone(in: current) == Array(0 ..< 100))
    }
}
