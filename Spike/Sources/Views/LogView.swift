import SwiftUI

struct LogView: View {
    @Environment(SpikeLog.self) private var log
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Measurements (\(log.measurements.count))") {
                    ForEach(log.measurements.suffix(30).reversed()) { m in
                        LabeledContent(m.name, value: String(format: "%.2f %@", m.value, m.unit))
                    }
                }
                Section("Entries (\(log.entries.count))") {
                    ForEach(log.entries.suffix(200).reversed()) { e in
                        Text(e.text).font(.caption.monospaced()).foregroundStyle(e.level == "error" ? .red : e.level == "warn" ? .orange : .primary)
                    }
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Clear") { log.clear() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let exportURL { ShareLink(item: exportURL) { Label("Share", systemImage: "square.and.arrow.up") } }
                    else { Button("Export") { exportURL = try? log.export() } }
                }
            }
        }
    }
}
