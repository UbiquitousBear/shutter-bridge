import Foundation
import Testing
@testable import AppUI

// The archive's header and order, its redaction over a whole stream, and its sources (a fake reader for the unified log, a
// real rolling file in a temporary folder). No waits: nothing here is asynchronous but the fake reader's call.

@Suite("Diagnostics: the archive")
struct DiagnosticsArchiveTests {
    private let serial = "7654321"
    private let network = "DIRECT-Qx7k:ILCE-7CM2"
    private let password = "Fake-Pass-8813"
    private let guid = "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A"

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_794_000_000 + seconds) }

    private var header: DiagnosticsHeader {
        DiagnosticsHeader(appVersion: "1.0", appBuild: "19", systemVersion: "27.0", deviceClass: "iPhone",
                          cameras: [.init(model: "ILCE-7CM2", firmware: "2.01 (vendor extension 0x00000011)")],
                          lastLink: "Wi-Fi", exportedAt: at(100))
    }

    private var redactor: DiagnosticsRedactor {
        DiagnosticsRedactor(privateValues: [serial, network, password, guid])
    }

    @Test func theHeaderSaysWhatTheFileHoldsAndWhereItCameFrom() {
        let text = DiagnosticsArchive.render(header: header, launches: [], redactor: redactor)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == DiagnosticsArchive.preamble)
        #expect(lines.contains("Exported: 2026-11-06T21:21:40.000Z"))
        #expect(lines.contains("App: 1.0 (19)"))
        #expect(lines.contains("iOS: 27.0"))
        #expect(lines.contains("Phone: iPhone"))
        #expect(lines.contains("Camera: ILCE-7CM2, firmware 2.01 (vendor extension 0x00000011)"))
        #expect(lines.contains("Last link: Wi-Fi"))
        #expect(lines.contains("No log lines were available."))
        #expect(text.hasSuffix("\n"))
        #expect(DiagnosticsArchive.preamble.contains("sent nowhere"))
    }

    @Test func aCameraWithoutAFirmwareAndNoCameraAtAllAreSaidSo() {
        var h = header
        h.cameras = [.init(model: "ILCE-7CM2", firmware: nil)]
        h.lastLink = nil
        let one = DiagnosticsArchive.render(header: h, launches: [], redactor: redactor)
        #expect(one.contains("Camera: ILCE-7CM2, firmware not read"))
        #expect(one.contains("Last link: none yet"))
        h.cameras = []
        #expect(DiagnosticsArchive.render(header: h, launches: [], redactor: redactor).contains("Camera: none known"))
    }

    @Test func launchesAreOldestFirstWithThisLaunchLastAndEntriesOldestFirstWithinEach() {
        let earlier = DiagnosticsLaunch(started: at(-3_600), isCurrent: false, entries: [
            .init(date: at(-3_500), category: "browse", message: "earlier two"),
            .init(date: at(-3_590), category: "browse", message: "earlier one"),
        ])
        let older = DiagnosticsLaunch(started: at(-7_200), isCurrent: false, entries: [
            .init(date: at(-7_100), category: "browse", message: "older one"),
        ])
        let current = DiagnosticsLaunch(started: at(0), isCurrent: true, entries: [
            .init(date: at(10), category: "browse", level: .error, message: "now two"),
            .init(date: at(5), category: "browse", message: "now one"),
            .init(date: at(5), category: "browse", message: "now one, same time, after"),
        ])
        // Given in a scrambled order: this launch first.
        let text = DiagnosticsArchive.render(header: header, launches: [current, earlier, older], redactor: redactor)
        let order = ["older one", "earlier one", "earlier two", "now one,", "now two"]
        var from = text.startIndex
        for fragment in order {
            let found = text.range(of: fragment, range: from..<text.endIndex)
            #expect(found != nil, "\"\(fragment)\" missing or out of order in:\n\(text)")
            if let found { from = found.upperBound }
        }
        let now = text.range(of: "now one\n")
        let after = text.range(of: "now one, same time, after")
        #expect(now != nil && after != nil && now!.lowerBound < after!.lowerBound)
        #expect(text.components(separatedBy: "=== An earlier launch").count == 3)
        #expect(text.components(separatedBy: "=== This launch").count == 2)
        #expect(text.contains("2026-11-06T21:20:10.000Z error [browse] now two"))
        #expect(text.contains("2026-11-06T21:20:05.000Z notice [browse] now one\n"))
    }

    @Test func aMessageWithLineBreaksStaysOneEntry() {
        let launch = DiagnosticsLaunch(started: nil, isCurrent: true, entries: [
            .init(date: at(1), category: "browse", message: "first\nsecond\r\nthird"),
        ])
        let text = DiagnosticsArchive.render(header: header, launches: [launch], redactor: redactor)
        #expect(text.contains("[browse] first\n    second\n    third\n"))
    }

    @Test func aWholeStreamWithEveryKindOfPrivateValueComesOutWithNoneOfThem() {
        var h = header
        // Even a header filled in carelessly is redacted.
        h.cameras = [.init(model: "ILCE-7CM2 \(serial)", firmware: "2.01 at 10.0.0.9")]
        h.lastLink = "Wi-Fi \(network)"
        let messages = [
            "serial \(serial)", "joined \(network) with \(password)", "guid \(guid.lowercased())",
            "hardware A1B2C3D4E5F6 mac a1:b2:c3:d4:e5:f6", "from 192.168.1.20 to \(DiagnosticsRedactor.cameraGateway)",
            "peripheral 5A4B3C2D-1E0F-4A1B-9C8D-7E6F5A4B3C2D", "v6 fe80::1c2d:3e4f:5a6b:7c8d",
        ]
        let entries = messages.enumerated().map { index, message in
            DiagnosticsLogEntry(date: at(Double(index)), category: "browse\(network)", message: message)
        }
        let text = DiagnosticsArchive.render(
            header: h, launches: [.init(started: at(0), isCurrent: true, entries: entries)], redactor: redactor)
        for forbidden in [serial, network, password, guid, guid.lowercased(), "A1B2C3D4E5F6", "a1:b2:c3", "192.168.1.20",
                          "10.0.0.9", "5A4B3C2D", "fe80", "Qx7k", "8813"] {
            #expect(!text.contains(forbidden), "\"\(forbidden)\" survived in:\n\(text)")
        }
        #expect(text.contains("from \(DiagnosticsRedactor.addressMark) to 192.168.122.1"))
        #expect(text.contains("ILCE-7CM2"))
    }

    // MARK: Sources

    private struct FakeSource: LogEntrySource {
        var result: Result<[DiagnosticsLogEntry], FakeFailure>
        func entries() async throws -> [DiagnosticsLogEntry] { try result.get() }
    }

    private struct FakeFailure: Error {}

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func buildJoinsTheEarlierLaunchesFromTheFileWithThisLaunchFromTheReader() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = RollingLogFile(directory: folder, launchStarted: at(-7_200))
        first.append(.init(date: at(-7_100), category: "browse", message: "from the first launch"))
        let second = RollingLogFile(directory: folder, launchStarted: at(0))
        second.append(.init(date: at(1), category: "browse", message: "also in the file"))
        let source = FakeSource(result: .success([.init(date: at(2), category: "browse", message: "from the log store")]))
        let text = await DiagnosticsArchive.build(header: header, current: source, rollingFile: second, redactor: redactor)
        #expect(text.contains("from the first launch"))
        #expect(text.contains("from the log store"))
        // This launch comes from the reader alone: its lines in the file would show it twice.
        #expect(!text.contains("also in the file"))
        #expect(text.range(of: "from the first launch")!.lowerBound < text.range(of: "from the log store")!.lowerBound)
    }

    @Test func buildFallsBackToTheFileWhenTheReaderFailsOrIsEmpty() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = RollingLogFile(directory: folder, launchStarted: at(0))
        file.append(.init(date: at(1), category: "browse", message: "kept in the file"))
        let failing = await DiagnosticsArchive.build(header: header, current: FakeSource(result: .failure(FakeFailure())),
                                                     rollingFile: file, redactor: redactor)
        #expect(failing.contains("kept in the file"))
        let empty = await DiagnosticsArchive.build(header: header, current: FakeSource(result: .success([])),
                                                   rollingFile: file, redactor: redactor)
        #expect(empty.contains("kept in the file"))
    }

    @Test func buildSaysSoWhenNothingCanBeRead() async {
        let text = await DiagnosticsArchive.build(
            header: header, current: FakeSource(result: .failure(FakeFailure())), rollingFile: nil, redactor: redactor)
        #expect(text.contains("could not be read from the system log"))
        let none = await DiagnosticsArchive.build(header: header, current: nil, rollingFile: nil, redactor: redactor)
        #expect(none.contains("(no lines)"))
    }
}
