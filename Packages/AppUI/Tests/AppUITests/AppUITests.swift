import Testing
@testable import AppUI

@Suite("Cameras empty state")
struct CamerasEmptyStateTests {
    let copy = CamerasEmptyState.standard

    @Test func usesTheCamerasWordingAndRecommendsMSC() {
        #expect(copy.modeAdvice.contains("Select USB Connect Mode"))
        #expect(copy.modeAdvice.contains("choose Image Transfer (MSC)"))
        #expect(copy.modeAdvice.contains("Image Transfer (MTP)"))
        #expect(copy.remoteShootNote.contains("Remote Shoot (PC Remote)"))
        #expect(copy.connect.contains("USB-C"))
    }

    @Test func noSonyMarksAndNoUnfinishedLines() {
        // "Works with" wording only: the copy never names the maker, and every line is a finished sentence.
        for line in copy.lines + [CamerasEmptyState.notYetLookingNotice] {
            #expect(!line.lowercased().contains("sony"), "\(line)")
            #expect(!line.isEmpty)
        }
        for line in copy.lines.dropFirst() + [CamerasEmptyState.notYetLookingNotice] {
            #expect(line.hasSuffix("."), "\(line)")
        }
    }
}
