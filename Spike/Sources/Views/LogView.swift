import SwiftUI
import UIKit

/// Day 10: everything the spike recorded, kept across launches. "Copy measurements table" renders
/// docs/spike-plan.md's measurements table from the latest value of each measurement; "Export JSON" has every
/// entry and measurement with the device context first; the fixtures zip goes over Fixtures/a7c2/ on the Mac.
struct LogView: View {
    @Environment(SpikeLog.self) private var log
    @AppStorage(ProximityWatcher.Keys.serviceUUID) private var serviceUUID = ""
    @State private var exportURL: URL?
    @State private var tableMarkdown: String?
    @State private var logText: String?
    @State private var fixtures: [String] = []
    @State private var zipURL: URL?
    @State private var device = DeviceContext.current()
    @State private var confirmClearLog = false
    @State private var confirmClearFixtures = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                exportSection
                fixturesSection
                Section("Measurements (\(log.measurements.count)), latest first") {
                    ForEach(recentMeasurements) { m in
                        measurementRow(m)
                    }
                }
                Section("Entries (\(log.entries.count)), latest first") {
                    ForEach(recentEntries) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.timeFormatter.string(from: e.at))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(e.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(color(for: e.level))
                                .textSelection(.enabled)
                        }
                        .contextMenu {
                            Button("Copy this entry") {
                                UIPasteboard.general.string = log.plainText([e], device: device)
                            }
                            Button("Copy from here to the latest") {
                                if let i = log.entries.firstIndex(where: { $0.id == e.id }) {
                                    copyLog(log.entries[i...], what: "from \(Self.timeFormatter.string(from: e.at))")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { confirmClearLog = true }
                }
            }
            .confirmationDialog("Clear the whole log?", isPresented: $confirmClearLog, titleVisibility: .visible) {
                Button("Clear log", role: .destructive) {
                    log.clear()
                    if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
                    exportURL = nil
                    tableMarkdown = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes every entry and measurement on this phone, including the saved log file. Export first if the numbers aren't in the findings yet.")
            }
            .onAppear { refresh() }
        }
        .confirmationDialog("Delete every captured fixture?", isPresented: $confirmClearFixtures, titleVisibility: .visible) {
            Button("Clear fixtures", role: .destructive) {
                FixtureStore.clear(log: log)
                if let zipURL { try? FileManager.default.removeItem(at: zipURL) }
                zipURL = nil
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes Documents/fixtures on this phone. Share the zip first if it hasn't reached the Mac.")
        }
    }

    // MARK: - Sections

    private var deviceSection: some View {
        Section("Device") {
            Text(device.summary).font(.caption)
            if log.restoredEntryCount > 0 || log.restoredMeasurementCount > 0 {
                Text("Kept from earlier launches: \(log.restoredEntryCount) entries, \(log.restoredMeasurementCount) measurements")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem = log.persistenceProblem {
                Text("Log file: \(problem)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var exportSection: some View {
        Section("Day 10 · Export") {
            Button("Copy log since the last Open session (\(log.entriesSinceLastOpen.count) entries)") {
                copyLog(log.entriesSinceLastOpen, what: "since the last Open session")
            }
            Button("Copy whole log (\(log.entries.count) entries)") { copyLog(log.entries[...], what: "whole log") }
            if let logText {
                ShareLink("Share copied log as text", item: logText)
            }
            Button("Copy measurements table") { copyTable() }
            if let tableMarkdown {
                ShareLink("Share measurements table", item: tableMarkdown)
            }
            Button("Export JSON") { exportJSON() }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                }
            }
            Text("Copy log puts the entries on the clipboard as text, oldest first, to paste into the chat; touch and hold an entry to copy just that one, or from it to the latest. The table is docs/spike-plan.md's measurements table filled from the latest value of each measurement (— where nothing was recorded), then every measurement and the device. Paste it into the findings page.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var fixturesSection: some View {
        Section("Fixtures (\(fixtures.count))") {
            if fixtures.isEmpty {
                Text("None captured yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(fixtures, id: \.self) { path in
                Text(path).font(.caption.monospaced())
            }
            Button("Refresh list") { refresh() }
            Button("Share fixtures (zip)") { zipFixtures() }
                .disabled(fixtures.isEmpty)
            if let zipURL {
                ShareLink(item: zipURL) {
                    Label("Share \(zipURL.lastPathComponent)", systemImage: "doc.zipper")
                }
            }
            Button("Clear fixtures", role: .destructive) { confirmClearFixtures = true }
                .disabled(fixtures.isEmpty)
            Text("Unzip on the Mac and copy the a7c2 folder over Fixtures/a7c2/, then run make fixtures. Fixtures never contain a Wi-Fi password.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func measurementRow(_ m: SpikeLog.Measurement) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.name).font(.caption.monospaced())
                Spacer()
                Text(MeasurementsTable.format(m.value, unit: m.unit))
                    .font(.caption.bold())
                    .monospacedDigit()
            }
            if !m.context.isEmpty {
                Text(m.context).font(.caption2).foregroundStyle(.secondary)
            }
            Text(Self.timeFormatter.string(from: m.at)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private var recentMeasurements: [SpikeLog.Measurement] { Array(log.measurements.suffix(150).reversed()) }
    private var recentEntries: [SpikeLog.Entry] { Array(log.entries.suffix(300).reversed()) }

    private func refresh() {
        fixtures = FixtureStore.inventory()
        device = DeviceContext.current()
    }

    private func copyLog(_ entries: ArraySlice<SpikeLog.Entry>, what: String) {
        device = DeviceContext.current()
        let text = log.plainText(entries, device: device)
        UIPasteboard.general.string = text
        logText = text
        log.note("log copied to the clipboard (\(what): \(entries.count) entries, \(text.utf8.count / 1000) KB)")
    }

    private func copyTable() {
        let markdown = log.measurementsTableMarkdown(serviceUUID: serviceUUID.isEmpty ? nil : serviceUUID)
        UIPasteboard.general.string = markdown
        tableMarkdown = markdown
        log.note("measurements table copied to the clipboard (\(log.measurements.count) measurements)")
    }

    private func exportJSON() {
        do {
            let url = try log.export()
            // Each export is a new file in tmp: drop the one it replaces so they don't pile up.
            if let old = exportURL, old != url { try? FileManager.default.removeItem(at: old) }
            exportURL = url
            log.note("log exported as \(url.lastPathComponent)")
        } catch {
            log.error("log export failed: \(error)")
        }
    }

    private func zipFixtures() {
        do {
            let url = try FixtureStore.zipArchive()
            if let old = zipURL, old != url { try? FileManager.default.removeItem(at: old) }
            zipURL = url
            // Count what was actually zipped, not the list as it was at the last refresh.
            fixtures = FixtureStore.inventory()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            log.note("fixtures zipped: \(url.lastPathComponent), \(fixtures.count) files, \(size) bytes")
        } catch {
            log.error("could not zip the fixtures: \(error)")
        }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        default: return .primary
        }
    }
}
