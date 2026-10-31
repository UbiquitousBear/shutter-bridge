import Foundation
import Observation
import OSLog

/// One place for everything the spike observes. The Log tab shows it; "Export" writes it as JSON so the
/// numbers can be pasted into the measurements table on day 10.
@Observable
@MainActor
final class SpikeLog {
    struct Entry: Identifiable, Codable {
        let id: UUID
        let at: Date
        let level: String
        let text: String
    }

    struct Measurement: Identifiable, Codable {
        let id: UUID
        let at: Date
        let name: String
        let value: Double
        let unit: String
        let context: String
    }

    private(set) var entries: [Entry] = []
    private(set) var measurements: [Measurement] = []

    private let os = Logger(subsystem: "com.ubiquitousbear.shutterbridge.spike", category: "spike")

    func note(_ text: String) { append("info", text); os.info("\(text, privacy: .public)") }
    func warn(_ text: String) { append("warn", text); os.warning("\(text, privacy: .public)") }
    func error(_ text: String) { append("error", text); os.error("\(text, privacy: .public)") }

    func measure(_ name: String, _ value: Double, _ unit: String, context: String = "") {
        measurements.append(Measurement(id: UUID(), at: Date(), name: name, value: value, unit: unit, context: context))
        note(String(format: "%@ = %.2f %@ %@", name, value, unit, context))
    }

    /// Times a block and records it as a measurement. Returns the block's result.
    func timed<T>(_ name: String, context: String = "", _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await body()
        let seconds = Double((clock.now - start).components.seconds) + Double((clock.now - start).components.attoseconds) / 1e18
        measure(name, seconds, "s", context: context)
        return result
    }

    /// Records throughput for a transfer of `bytes` that took `seconds`.
    func throughput(_ name: String, bytes: Int, seconds: Double, context: String = "") {
        guard seconds > 0 else { return }
        measure(name, Double(bytes) / seconds / 1_000_000, "MB/s", context: context)
    }

    func export() throws -> URL {
        struct Export: Codable { let exportedAt: Date; let entries: [Entry]; let measurements: [Measurement] }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(Export(exportedAt: Date(), entries: entries, measurements: measurements))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spike-log-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url)
        return url
    }

    func clear() { entries.removeAll(); measurements.removeAll() }

    private func append(_ level: String, _ text: String) {
        entries.append(Entry(id: UUID(), at: Date(), level: level, text: text))
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
    }
}

extension Data {
    /// "1A 2B 3C …" for the first `limit` bytes; what we paste into the findings page.
    func hexDump(limit: Int = 64) -> String {
        let shown = prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > limit ? shown + " … (\(count) bytes)" : shown
    }
}
