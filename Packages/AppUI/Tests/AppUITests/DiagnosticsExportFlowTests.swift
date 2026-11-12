import Catalogue
import Foundation
import Synchronization
import Testing
@testable import AppUI

// Diagnostics wiring (I8): the log's levels through each destination, the Settings model's export flow with a fake exporter,
// and the real exporter over a fake log source and an in-memory catalogue (a temporary folder, emptied afterwards). The row
// and the share sheet are CI only. Waits are bounded (`eventually` polls for about two seconds).

// MARK: - Levels

/// A log written before levels existed: it has only `note(_:)`.
private final class LegacyLog: BenchLog, Sendable {
    private let stored = Mutex<[String]>([])
    var lines: [String] { stored.withLock { $0 } }
    func note(_ line: String) { stored.withLock { $0.append(line) } }
}

@Suite("Diagnostics: the log's levels")
struct BenchLogLevelTests {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_794_000_000 + seconds) }

    @Test func aPlainNoteIsANoticeAndALegacyLogStillGetsEveryLine() {
        let log = LeveledLog()
        log.note("a")
        log.note("b", level: .error)
        #expect(log.entries == [.init(line: "a", level: .notice), .init(line: "b", level: .error)])
        // A log with only `note(_:)` keeps working: the level is dropped, the line is not.
        let legacy = LegacyLog()
        (legacy as any BenchLog).note("failed", level: .error)
        (legacy as any BenchLog).note("fine")
        #expect(legacy.lines == ["failed", "fine"])
    }

    @Test func theTeeSendsEachLineToEveryLogAtItsLevel() {
        let one = LeveledLog(), two = LeveledLog(), legacy = LegacyLog()
        let tee = TeeBenchLog([one, two, legacy])
        tee.note("a")
        tee.note("b", level: .error)
        for log in [one, two] { #expect(log.entries == [.init(line: "a", level: .notice), .init(line: "b", level: .error)]) }
        #expect(legacy.lines == ["a", "b"])
    }

    @Test func theRollingFileKeepsTheLevelAndTheArchiveShowsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("levels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = RollingLogFile(directory: folder, launchStarted: at(0), now: { at(1) })
        file.note("engine: paused (the camera was removed)")
        file.note("engine: failed A.JPG: the camera was busy", level: .error)
        #expect(file.currentLaunch().entries.map(\.level) == [.notice, .error])
        let launch = file.currentLaunch()
        let text = DiagnosticsArchive.render(
            header: DiagnosticsHeader(appVersion: "1", appBuild: "1", systemVersion: "27.0", deviceClass: "iPhone",
                                      exportedAt: at(2)),
            launches: [launch], redactor: DiagnosticsRedactor())
        #expect(text.contains("Z notice [browse] engine: paused (the camera was removed)"))
        #expect(text.contains("Z error [browse] engine: failed A.JPG: the camera was busy"))
    }
}

// MARK: - The settings model's flow

/// An exporter whose export can be held until the test lets it go, and that records what was discarded.
private final class FakeExporter: DiagnosticsExporting, Sendable {
    private struct State {
        var made = 0
        var discarded: [DiagnosticsExport] = []
        var fails = false
        var holds = false
        var waiting: CheckedContinuation<Void, Never>?
        var started = false
    }

    private let state = Mutex(State())

    var made: Int { state.withLock { $0.made } }
    var discarded: [DiagnosticsExport] { state.withLock { $0.discarded } }
    var started: Bool { state.withLock { $0.started } }

    func set(fails: Bool? = nil, holds: Bool? = nil) {
        state.withLock {
            if let fails { $0.fails = fails }
            if let holds { $0.holds = holds }
        }
    }

    func release() {
        let waiting = state.withLock { s -> CheckedContinuation<Void, Never>? in
            defer { s.waiting = nil }
            return s.waiting
        }
        waiting?.resume()
    }

    struct Failed: Error {}

    func makeExport() async throws -> DiagnosticsExport {
        let holds = state.withLock { s -> Bool in
            s.started = true
            return s.holds
        }
        if holds {
            await withCheckedContinuation { c in
                let resumeNow = state.withLock { s -> Bool in
                    if !s.holds { return true }
                    s.waiting = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        }
        return try state.withLock { s in
            if s.fails { throw Failed() }
            s.made += 1
            return DiagnosticsExport(fileURL: URL(fileURLWithPath: "/tmp/fake-export-\(s.made)/diagnostics.txt"))
        }
    }

    func discard(_ export: DiagnosticsExport) { state.withLock { $0.discarded.append(export) } }
}

@MainActor
@Suite("Settings: the diagnostics export flow", .timeLimit(.minutes(1)))
struct SettingsExportFlowTests {
    @Test func withoutAnExporterThereIsNoRow() async {
        let model = SettingsModel()
        #expect(!model.offersDiagnosticsExport)
        await model.exportDiagnostics()
        #expect(model.exportState == .idle)
    }

    @Test func anExportBecomesReadyAndTheFolderGoesWhenTheSheetCloses() async {
        let exporter = FakeExporter()
        let model = SettingsModel(diagnostics: exporter)
        #expect(model.offersDiagnosticsExport)
        await model.exportDiagnostics()
        guard case let .ready(export) = model.exportState else { Issue.record("not ready: \(model.exportState)"); return }
        #expect(model.isExporting)
        #expect(exporter.discarded.isEmpty)
        model.exportFinished()
        #expect(exporter.discarded == [export])
        #expect(model.exportState == .idle)
        #expect(!model.isExporting)
        // Another export is allowed afterwards.
        await model.exportDiagnostics()
        #expect(exporter.made == 2)
    }

    @Test func aFailedExportSaysSoAndCanBeTriedAgain() async {
        let exporter = FakeExporter()
        exporter.set(fails: true)
        let model = SettingsModel(diagnostics: exporter)
        await model.exportDiagnostics()
        #expect(model.exportState == .failed(DiagnosticsWording.failed))
        #expect(!model.isExporting)
        exporter.set(fails: false)
        await model.exportDiagnostics()
        if case .ready = model.exportState {} else { Issue.record("expected ready, got \(model.exportState)") }
    }

    @Test func aShareSheetThatCouldNotBeShownRemovesTheFileAndSaysSo() async {
        let exporter = FakeExporter()
        let model = SettingsModel(diagnostics: exporter)
        await model.exportDiagnostics()
        guard case let .ready(export) = model.exportState else { Issue.record("not ready"); return }
        model.exportCouldNotBePresented()
        #expect(exporter.discarded == [export])
        #expect(model.exportState == .failed(DiagnosticsWording.couldNotShare))
    }

    @Test func aSecondTapWhileTheFileIsBeingMadeOrShownDoesNothing() async {
        let exporter = FakeExporter()
        exporter.set(holds: true)
        let model = SettingsModel(diagnostics: exporter)
        let first = Task { await model.exportDiagnostics() }
        #expect(await eventually { model.exportState == .preparing && exporter.started })
        #expect(model.isExporting)
        await model.exportDiagnostics() // returns at once: one is in progress
        exporter.set(holds: false)
        exporter.release()
        await first.value
        #expect(exporter.made == 1)
        await model.exportDiagnostics() // the file is waiting for the share sheet
        #expect(exporter.made == 1)
    }

    @Test func leavingSettingsWhileTheFileIsBeingMadeDiscardsItWhenItIsDone() async {
        let exporter = FakeExporter()
        exporter.set(holds: true)
        let model = SettingsModel(diagnostics: exporter)
        let run = Task { await model.exportDiagnostics() }
        #expect(await eventually { exporter.started })
        model.settingsClosed()
        #expect(model.exportState == .idle)
        exporter.set(holds: false)
        exporter.release()
        await run.value
        #expect(model.exportState == .idle)
        #expect(exporter.discarded.count == 1)
    }

    @Test func leavingSettingsWithAReadyFileRemovesIt() async {
        let exporter = FakeExporter()
        let model = SettingsModel(diagnostics: exporter)
        await model.exportDiagnostics()
        model.settingsClosed()
        #expect(exporter.discarded.count == 1)
        #expect(model.exportState == .idle)
    }

    @Test func theRowSaysWhatIsInTheFileAndThatNothingIsSent() {
        #expect(DiagnosticsWording.footer.contains("sent nowhere"))
        #expect(DiagnosticsWording.footer.contains("removed"))
        #expect(DiagnosticsWording.accessibilityHint.contains("Nothing is sent until you choose"))
        #expect(DiagnosticsWording.rowTitle == "Export Diagnostics…")
    }
}

// MARK: - The real exporter

@Suite("Diagnostics: the exporter")
struct DiagnosticsExporterTests {
    private let serial = "7654321"
    private let network = "DIRECT-Qx7k:ILCE-7CM2"
    private let guid = UUID(uuidString: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A")!
    private let peripheral = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private struct FakeSource: LogEntrySource {
        var entries: [DiagnosticsLogEntry]
        func entries() async throws -> [DiagnosticsLogEntry] { entries }
    }

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_794_000_000 + seconds) }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exporter-tests-\(UUID().uuidString)")
    }

    private func catalogue(cameras: Int = 1) async -> InMemoryCatalogue {
        let catalogue = InMemoryCatalogue()
        for i in 0 ..< cameras {
            await catalogue.upsertCamera(CameraRecord(
                key: CameraKey(rawValue: "key-\(i)"), model: "ILCE-7CM2", friendlyName: "Shamil's camera \(serial)",
                lastSeen: at(Double(i)), preferredCarrier: i == 0 ? .wifi : .usb, wifiSSID: network, lastIP: "192.168.1.77",
                ptpipGUID: guid, bluetoothPeripheralID: peripheral))
        }
        return catalogue
    }

    @Test func anExportHasTheHeaderTheLogAndNoPrivateValue() async throws {
        let scratch = folder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let notes = CameraFirmwareNotes()
        notes.note("2.01 (vendor extension 0x00000011)")
        let hostile = "joined \(network) with \(guid.uuidString) peripheral \(peripheral.uuidString) at 192.168.1.77 "
            + "and 192.168.122.1, the camera is called Shamil's camera \(serial), hardware 001A2B3C4D5E"
        let exporter = DiagnosticsExporter(
            scratch: scratch, info: DiagnosticsAppInfo(appVersion: "1.0", appBuild: "19", systemVersion: "27.0"),
            catalogue: await catalogue(), firmware: notes,
            current: FakeSource(entries: [.init(date: at(5), category: "browse", level: .error, message: hostile),
                                          .init(date: at(4), category: "browse", message: "engine: continued")]),
            rollingFile: nil, now: { at(10) })
        let export = try await exporter.makeExport()
        let text = try String(contentsOf: export.fileURL, encoding: .utf8)
        #expect(text.contains("App: 1.0 (19)"))
        #expect(text.contains("iOS: 27.0"))
        #expect(text.contains("Phone: iPhone"))
        #expect(text.contains("Camera: ILCE-7CM2, firmware 2.01 (vendor extension 0x00000011)"))
        #expect(text.contains("Last link: Wi-Fi"))
        #expect(text.contains("Exported: 2026-11-06T21:20:10.000Z"))
        #expect(text.contains("192.168.122.1"))
        for forbidden in [network, guid.uuidString, peripheral.uuidString, "192.168.1.77", serial, "Shamil", "001A2B3C4D5E"] {
            #expect(!text.localizedStandardContains(forbidden), "\"\(forbidden)\" is in the export")
        }
        // Oldest first, and the error keeps its level.
        let continued = try #require(text.range(of: "engine: continued"))
        let failed = try #require(text.range(of: " error [browse] joined"))
        #expect(continued.lowerBound < failed.lowerBound)
        #expect(export.fileURL.lastPathComponent == "ShutterBridge-diagnostics-20261106-212010.txt")
        // One file in a folder of its own under the scratch folder.
        #expect(export.fileURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
            == scratch.standardizedFileURL.path)
    }

    /// D11: an MSC or MTP row named after a body's model (`CameraNaming`) isn't a private name, so the header's model
    /// isn't redacted; a name the person gave stays private.
    @Test func aRowNamedAfterAModelDoesNotRedactTheHeader() async {
        let catalogue = InMemoryCatalogue(cameras: [
            CameraRecord(key: CameraKey(rawValue: "wifi-serial:a"), model: "ILCE-7CM2", preferredCarrier: .wifi),
            CameraRecord(key: CameraKey(rawValue: "usb-msc-name:b"), friendlyName: "ILCE-7CM2"),
            CameraRecord(key: CameraKey(rawValue: "usb-device:c"), friendlyName: "Shamil's camera"),
        ])
        let facts = await DiagnosticsFacts.read(from: catalogue, firmware: nil)
        #expect(facts.cameras.map(\.model) == ["ILCE-7CM2"])
        #expect(facts.privateValues == ["Shamil's camera"])
    }

    @Test func discardEmptiesTheFolderAndTouchesNothingElse() async throws {
        let scratch = folder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let exporter = DiagnosticsExporter(scratch: scratch, info: .init(appVersion: "1", appBuild: "1", systemVersion: "27.0"),
                                           catalogue: nil, current: FakeSource(entries: []), rollingFile: nil)
        let export = try await exporter.makeExport()
        #expect(FileManager.default.fileExists(atPath: export.fileURL.path))
        exporter.discard(export)
        #expect(!FileManager.default.fileExists(atPath: export.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: export.fileURL.deletingLastPathComponent().path))
        exporter.discard(export) // twice is fine
        // A file that isn't in one of its folders is left alone.
        let outside = scratch.deletingLastPathComponent().appendingPathComponent("keep-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        exporter.discard(DiagnosticsExport(fileURL: outside))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func leftoversFromACrashAreRemoved() async throws {
        let scratch = folder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let exporter = DiagnosticsExporter(scratch: scratch, info: .init(appVersion: "1", appBuild: "1", systemVersion: "27.0"),
                                           catalogue: nil, current: FakeSource(entries: []), rollingFile: nil)
        _ = try await exporter.makeExport()
        _ = try await exporter.makeExport()
        #expect(exporter.removeLeftovers() == 2)
        #expect(exporter.removeLeftovers() == 0)
    }

    @Test func firmwareIsPlacedOnlyWhenItCannotBeWrongAndNoCameraIsSaidSo() async throws {
        let scratch = folder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let notes = CameraFirmwareNotes()
        notes.note("2.01 (vendor extension 0x00000011)")
        func text(cameras: Int, catalogue: (any CatalogueStore)?) async throws -> String {
            let exporter = DiagnosticsExporter(
                scratch: scratch, info: .init(appVersion: "1", appBuild: "1", systemVersion: "27.0"), catalogue: catalogue,
                firmware: notes, current: FakeSource(entries: []), rollingFile: nil)
            let export = try await exporter.makeExport()
            defer { exporter.discard(export) }
            return try String(contentsOf: export.fileURL, encoding: .utf8)
        }
        let two = try await text(cameras: 2, catalogue: await catalogue(cameras: 2))
        #expect(two.components(separatedBy: "Camera: ILCE-7CM2, firmware not read").count == 3)
        #expect(!two.contains("2.01"))
        let none = try await text(cameras: 0, catalogue: nil)
        #expect(none.contains("Camera: none known"))
        #expect(none.contains("Last link: none yet"))
    }
}
