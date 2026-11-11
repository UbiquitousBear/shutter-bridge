import Catalogue
import Foundation
import Testing
@testable import AppUI

@MainActor
@Suite("Cull session: navigation, marks and undo")
struct CullSessionTests {
    func session(_ count: Int = 5, marks: [ObjectIdentity.ContentKey: CullMark] = [:], startingAt: Int = 0,
                 writer: RecordingMarkWriter = RecordingMarkWriter()) -> (CullSession, RecordingMarkWriter) {
        (CullSession(units: cullUnits(count), marks: marks, startingAt: startingAt, writer: writer), writer)
    }

    @Test func navigationStaysInsideTheList() {
        let (s, _) = session(3)
        #expect(s.index == 0 && s.current?.id == s.units[0].id && s.count == 3)
        #expect(!s.canGoPrevious && !s.previous() && s.index == 0)
        #expect(s.next() && s.next() && s.index == 2)
        #expect(!s.canGoNext && !s.next() && s.index == 2)
        #expect(s.previous() && s.index == 1)
        #expect(s.go(to: 0) && s.index == 0)
        #expect(!s.go(to: 3) && !s.go(to: -1) && s.index == 0)
    }

    @Test func startingPositionIsClampedAndAnEmptyListIsSafe() {
        #expect(session(3, startingAt: 9).0.index == 2)
        #expect(session(3, startingAt: -4).0.index == 0)
        let (empty, writer) = session(0)
        #expect(empty.current == nil && !empty.next() && !empty.previous())
        empty.keep()
        empty.setRating(3)
        #expect(!empty.canUndo && !empty.undo() && empty.marks.isEmpty)
        #expect(writer.writes.isEmpty)
    }

    @Test func keepAndRejectSaveAtOnceUnderEveryKeyOfThePair() async {
        let raw = cullFile("DSC00001.ARW"), jpg = cullFile("DSC00001.JPG")
        let pair = CullDay.days(of: [raw, jpg])[0].units
        let writer = RecordingMarkWriter()
        let s = CullSession(units: pair, writer: writer)
        s.keep()
        // In memory straight away, before the write has run.
        #expect(s.currentMark == CullMark(decision: .keep))
        await s.settled()
        #expect(writer.writes == [.init(mark: CullMark(decision: .keep), keys: [raw.contentKey, jpg.contentKey])])
        s.reject()
        await s.settled()
        #expect(s.currentMark.decision == .reject)
        #expect(writer.writes.count == 2)
    }

    @Test func ratingKeepsTheDecisionAndTheDecisionKeepsTheRating() async {
        let (s, writer) = session(2)
        s.setRating(4)
        s.keep()
        s.setRating(9)
        #expect(s.currentMark == CullMark(decision: .keep, rating: 5))
        s.setDecision(nil)
        #expect(s.currentMark == CullMark(decision: nil, rating: 5))
        s.setRating(0)
        #expect(s.currentMark.isUnmarked && s.marks.isEmpty)
        await s.settled()
        #expect(writer.writes.map(\.mark) == [CullMark(rating: 4), CullMark(decision: .keep, rating: 4),
                                              CullMark(decision: .keep, rating: 5), CullMark(rating: 5),
                                              CullMark.unmarked])
    }

    @Test func markingTheSameThingAgainWritesNothingAndLeavesNothingToUndo() async {
        let (s, writer) = session(2)
        s.keep()
        s.keep()
        await s.settled()
        #expect(writer.writes.count == 1)
        s.undo()
        #expect(!s.canUndo)
    }

    @Test func undoRevertsTheLastMarkShowsItsUnitAndSavesTheEarlierMark() async {
        let (s, writer) = session(4)
        s.keep()
        s.next()
        s.reject()
        s.next()
        s.next()
        #expect(s.index == 3 && s.canUndo)
        #expect(s.undo())
        #expect(s.index == 1)                       // back on the unit whose mark was reverted
        #expect(s.mark(of: s.units[1]).isUnmarked)
        #expect(s.mark(of: s.units[0]).decision == .keep)
        #expect(s.undo() && s.index == 0 && s.marks.isEmpty)
        #expect(!s.canUndo && !s.undo())
        await s.settled()
        #expect(writer.writes.map(\.mark) == [CullMark(decision: .keep), CullMark(decision: .reject),
                                              CullMark.unmarked, CullMark.unmarked])
        #expect(writer.writes.map { $0.keys.count } == [1, 1, 1, 1])
    }

    @Test func undoPutsBackTheMarkThatWasThereBefore() async {
        let (s, writer) = session(1)
        s.reject()
        s.keep()
        s.undo()
        #expect(s.currentMark.decision == .reject)
        await s.settled()
        #expect(writer.writes.last?.mark == CullMark(decision: .reject))
    }

    @Test func onlyTheLastHundredMarksCanBeUndone() {
        let (s, _) = session(101)
        for _ in 0 ..< 101 {
            s.keep()
            s.next()
        }
        var undone = 0
        while s.undo() { undone += 1 }
        #expect(undone == CullSession.undoLimit)
        #expect(s.marks.count == 1)                  // the first unit's mark is past the limit
    }

    @Test func advancingAfterADecisionIsOptInAndStopsAtTheLastUnit() {
        let (s, _) = session(2)
        s.keep()
        #expect(s.index == 0)
        s.advancesAfterDecision = true
        s.setRating(3)
        #expect(s.index == 0)                        // a rating alone doesn't advance
        s.reject()
        #expect(s.index == 1)
        s.keep()
        #expect(s.index == 1)
    }

    @Test func nextUnmarkedSkipsDecidedUnitsButNotRatedOnes() {
        let (s, _) = session(5)
        s.go(to: 1)
        s.keep()
        s.go(to: 2)
        s.setRating(2)
        s.go(to: 3)
        s.reject()
        s.go(to: 0)
        #expect(s.goToNextUnmarked() && s.index == 2)
        #expect(s.goToNextUnmarked() && s.index == 4)
        #expect(!s.goToNextUnmarked() && s.index == 4)
    }

    @Test func marksFromTheCatalogueAreReadUnderAnyKeyOfAUnit() {
        let raw = cullFile("DSC00001.ARW"), jpg = cullFile("DSC00001.JPG"), lone = cullFile("DSC00002.ARW", at: "20261105T140002")
        let units = CullDay.days(of: [raw, jpg, lone])[0].units
        let s = CullSession(
            units: units,
            marks: [jpg.contentKey: CullMark(decision: .keep, rating: 3), lone.contentKey: CullMark(decision: .reject)],
            writer: RecordingMarkWriter())
        #expect(s.marks[units[0].id] == CullMark(decision: .keep, rating: 3))
        #expect(s.marks[units[1].id] == CullMark(decision: .reject))
        #expect(s.counts.kept == 1 && s.counts.rejected == 1 && s.counts.unmarked == 0)
    }

    @Test func keepersAreEveryFileOfEveryKeeperInListOrderWithTheRawFirst() {
        let files = [cullFile("DSC00001.JPG", at: "20261105T140001"), cullFile("DSC00001.ARW", at: "20261105T140001"),
                     cullFile("DSC00002.ARW", at: "20261105T140002"), cullFile("DSC00003.ARW", at: "20261105T140003")]
        let s = CullSession(units: CullDay.days(of: files)[0].units, writer: RecordingMarkWriter())
        s.keep()
        s.next()
        s.reject()
        s.next()
        s.keep()
        #expect(s.keepers.count == 2 && s.rejects.count == 1)
        #expect(s.keeperFiles.map(\.identity.filename) == ["DSC00001.ARW", "DSC00001.JPG", "DSC00003.ARW"])
    }

    @Test func marksAreSavedInTheOrderTheyWereMadeEvenWhenTheFirstWriteIsSlow() async {
        let (s, writer) = session(1)
        writer.delayNext(.milliseconds(60))
        s.keep()
        s.reject()
        await s.settled()
        #expect(writer.writes.map(\.mark.decision) == [.keep, .reject])
    }

    @Test func aFailedWritePutsTheEarlierMarkBackAndSaysSo() async {
        let (s, writer) = session(2)
        s.keep()
        await s.settled()
        writer.failNext()
        s.reject()
        #expect(s.currentMark.decision == .reject)   // optimistic until the write answers
        await s.settled()
        #expect(s.currentMark.decision == .keep)
        #expect(s.writeFailure?.unit == s.units[0].id)
        #expect(s.writeFailure?.detail == "Refused")
        // The failed mark can no longer be undone; the earlier one still can.
        #expect(s.undo())
        #expect(s.currentMark.isUnmarked)
        #expect(!s.canUndo)
        s.dismissWriteFailure()
        #expect(s.writeFailure == nil)
    }

    @Test func aFailedWriteDoesNotUndoANewerMark() async {
        let (s, writer) = session(1)
        writer.delayNext(.milliseconds(40))
        writer.failNext()
        s.keep()          // fails after the delay
        s.reject()        // made while the first is in flight
        await s.settled()
        #expect(s.currentMark.decision == .reject)
        #expect(writer.writes.map(\.mark.decision) == [.reject])
    }
}
