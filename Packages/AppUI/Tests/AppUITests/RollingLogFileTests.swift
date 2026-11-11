import Foundation
import Testing
@testable import AppUI

// The rolling log file: the last three launches, at most 5 MB (a small budget in these tests), one line per entry
// whatever the message holds. Files in a temporary folder; no waits.

@Suite("Diagnostics: the rolling log file")
struct RollingLogFileTests {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_794_000_000 + seconds) }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rolling-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func theDefaultsAreThreeLaunchesAndFiveMegabytes() {
        #expect(RollingLogFile.defaultMaxLaunches == 3)
        #expect(RollingLogFile.defaultMaxBytes == 5 * 1_024 * 1_024)
    }

    @Test func entriesRoundTripWithEverythingAMessageCanHold() throws {
        try withFolder { folder in
            let file = RollingLogFile(directory: folder, launchStarted: at(0))
            let entries = [
                DiagnosticsLogEntry(date: at(1.234), category: "browse", level: .notice, message: "plain"),
                DiagnosticsLogEntry(date: at(2), category: "a\tb", level: .error,
                                    message: "tab\there, back\\slash, line\nbreak, carriage\rreturn, crlf\r\nend, \\n literal"),
                DiagnosticsLogEntry(date: at(3), category: "browse", level: .fault, message: "ünïcödé ✓ 日本語"),
                DiagnosticsLogEntry(date: at(4), category: "browse", level: .debug, message: ""),
            ]
            for entry in entries { file.append(entry) }
            let read = file.currentLaunch().entries
            #expect(read.count == entries.count)
            for (given, got) in zip(entries, read) {
                #expect(got.level == given.level)
                #expect(got.category == given.category)
                #expect(abs(got.date.timeIntervalSince(given.date)) < 0.001)
                #expect(got.message == given.message.replacingOccurrences(of: "\r\n", with: "\n"))
            }
            // On disk, one line per entry.
            let text = try String(contentsOf: folder.appendingPathComponent(files(in: folder)[0]), encoding: .utf8)
            #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == entries.count + 1)
        }
    }

    @Test func patternsAreRedactedBeforeALineReachesDisk() throws {
        try withFolder { folder in
            let file = RollingLogFile(directory: folder, launchStarted: at(0))
            let identifier = "5a4b3c2d-1e0f-4a1b-9c8d-7e6f5a4b3c2d"
            file.note("peer \(identifier) at 10.1.2.3 and ::ffff:198.51.100.7, camera 192.168.122.1, 4.1 s")
            let text = try String(contentsOf: folder.appendingPathComponent(files(in: folder)[0]), encoding: .utf8)
            for forbidden in [identifier, "10.1.2.3", "198.51.100", "ffff"] {
                #expect(!text.contains(forbidden), "\"\(forbidden)\" reached the file:\n\(text)")
            }
            #expect(text.contains("camera 192.168.122.1, 4.1 s"))
            #expect(file.currentLaunch().entries.first?.message.contains(DiagnosticsRedactor.identifierMark) == true)
        }
    }

    @Test func aLaunchIsMadeByItsFirstLineNotByStartingIt() throws {
        try withFolder { folder in
            let file = RollingLogFile(directory: folder, launchStarted: at(0))
            #expect(files(in: folder).isEmpty)
            #expect(file.currentLaunch().entries.isEmpty)
            file.note("a bench line")
            #expect(files(in: folder).count == 1)
            let entry = file.currentLaunch().entries.first
            #expect(entry?.message == "a bench line")
            #expect(entry?.category == "browse")
            #expect(entry?.level == .notice)
        }
    }

    @Test func onlyTheLastThreeLaunchesAreKept() throws {
        try withFolder { folder in
            for launch in 0..<5 {
                let file = RollingLogFile(directory: folder, launchStarted: at(Double(launch) * 100))
                file.append(.init(date: at(Double(launch) * 100 + 1), category: "browse", message: "launch \(launch)"))
            }
            // The fifth launch's start removed the oldest so that, with itself, three are kept.
            let sixth = RollingLogFile(directory: folder, launchStarted: at(500))
            let earlier = sixth.earlierLaunches()
            #expect(earlier.map { $0.entries.first?.message } == ["launch 3", "launch 4"].map(Optional.init))
            #expect(earlier.allSatisfy { !$0.isCurrent })
            #expect(sixth.currentLaunch().isCurrent)
            #expect(files(in: folder).count == 2)
            sixth.note("launch 5")
            #expect(files(in: folder).count == 3)
            // Oldest first, with their start times.
            #expect(earlier.map(\.started) == [at(300), at(400)])
        }
    }

    @Test func foreignFilesInTheFolderAreLeftAlone() throws {
        try withFolder { folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
            try Data("x".utf8).write(to: folder.appendingPathComponent("launch-bad.log"))
            for launch in 0..<4 {
                let file = RollingLogFile(directory: folder, launchStarted: at(Double(launch)))
                file.note("launch \(launch)")
            }
            #expect(files(in: folder).contains("notes.txt"))
            #expect(files(in: folder).contains("launch-bad.log"))
        }
    }

    @Test func twoLaunchesStartedInTheSameMillisecondStayApart() throws {
        try withFolder { folder in
            let first = RollingLogFile(directory: folder, launchStarted: at(0))
            first.note("one")
            let second = RollingLogFile(directory: folder, launchStarted: at(0))
            second.note("two")
            #expect(files(in: folder).count == 2)
            #expect(second.earlierLaunches().first?.entries.first?.message == "one")
            #expect(second.currentLaunch().entries.first?.message == "two")
        }
    }

    @Test func theBudgetDropsTheOldestLaunchFirst() throws {
        try withFolder { folder in
            let message = String(repeating: "x", count: 200)
            // About 250 bytes a line; a 2 KiB budget holds about eight.
            for launch in 0..<2 {
                let file = RollingLogFile(directory: folder, maxBytes: 2_048, launchStarted: at(Double(launch) * 100))
                for line in 0..<4 { file.append(.init(date: at(Double(launch) * 100 + Double(line)), category: "b", message: message)) }
            }
            let third = RollingLogFile(directory: folder, maxBytes: 2_048, launchStarted: at(200))
            #expect(third.earlierLaunches().count == 2)
            for line in 0..<6 { third.append(.init(date: at(200 + Double(line)), category: "b", message: message)) }
            #expect(third.totalBytes <= 2_048)
            // Room came from the oldest launch, not from this one.
            #expect(third.earlierLaunches().count < 2)
            #expect(third.currentLaunch().entries.count == 6)
        }
    }

    @Test func aSingleLaunchOverTheBudgetKeepsItsNewestLinesAndStaysInside() throws {
        try withFolder { folder in
            let file = RollingLogFile(directory: folder, maxBytes: 2_048, launchStarted: at(0))
            for line in 0..<100 {
                file.append(.init(date: at(Double(line)), category: "b", message: "line \(line) " + String(repeating: "y", count: 100)))
                #expect(file.totalBytes <= 2_048)
            }
            let kept = file.currentLaunch().entries
            #expect(!kept.isEmpty)
            #expect(kept.last?.message.hasPrefix("line 99 ") == true)
            // Whole lines, consecutive, the oldest gone.
            let numbers = kept.compactMap { $0.message.split(separator: " ").dropFirst().first.flatMap { Int($0) } }
            #expect(numbers.count == kept.count)
            #expect(numbers == Array(numbers[0]...99))
            #expect(numbers[0] > 0)
            // The size the file reports is the size on disk.
            let onDisk = try FileManager.default.attributesOfItem(
                atPath: folder.appendingPathComponent(files(in: folder)[0]).path)[.size] as? Int
            #expect(onDisk == file.totalBytes)
        }
    }

    @Test func aHugeMessageIsCutSoOneLineCannotUseTheBudget() throws {
        try withFolder { folder in
            let file = RollingLogFile(directory: folder, launchStarted: at(0))
            file.append(.init(date: at(0), category: "b", message: String(repeating: "z", count: 100_000)))
            let message = try #require(file.currentLaunch().entries.first?.message)
            #expect(message.count == RollingLogFile.maxMessageCharacters + 1)
            #expect(message.hasSuffix("…"))
        }
    }

    @Test func aLaunchStartedAfterTheSystemEmptiedTheFolderStartsAgain() throws {
        try withFolder { folder in
            let file = RollingLogFile(directory: folder, launchStarted: at(0))
            file.note("before")
            try FileManager.default.removeItem(at: folder)
            file.note("after")
            #expect(file.currentLaunch().entries.map(\.message) == ["after"])
        }
    }

    @Test func aCorruptLineIsSkippedNotFatal() throws {
        try withFolder { folder in
            let file = RollingLogFile(directory: folder, launchStarted: at(0))
            file.note("good one")
            let url = folder.appendingPathComponent(files(in: folder)[0])
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("not a line\n\u{1}\u{2}\n".utf8))
            try handle.close()
            file.note("good two")
            #expect(file.currentLaunch().entries.map(\.message) == ["good one", "good two"])
        }
    }
}
