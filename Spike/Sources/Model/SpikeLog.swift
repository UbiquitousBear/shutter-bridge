import Foundation
import Observation
import OSLog

/// One place for everything the spike observes. The Log tab shows it; "Export" writes it as JSON and "Copy
/// measurements table" renders docs/spike-plan.md's table from it on day 10.
///
/// Persistent: a Bluetooth wake-up or a BGContinuedProcessingTask run can relaunch the app with no UI, and the
/// system can kill it while suspended, so every entry and measurement is also appended as one JSON line to
/// Documents/spike-log.jsonl and reloaded at the next launch (the last `entryLimit` entries and
/// `measurementLimit` measurements). The file is compacted when it carries too many dropped lines. Everything is
/// still mirrored to OSLog (subsystem net.shamil.shutter-bridge.spike) for Console.app.
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

    /// The app's one log. SwiftUI and the app delegate share it, because a Bluetooth relaunch runs the app
    /// delegate without ever building the UI.
    static let shared = SpikeLog()

    /// Documents/spike-log.jsonl (visible in the Files app, next to the fixtures folder).
    nonisolated static var defaultFileURL: URL {
        URL.documentsDirectory.appending(path: "spike-log.jsonl")
    }

    static let entryLimit = 2000
    static let measurementLimit = 10_000
    /// Dropped lines tolerated in the file before it is rewritten from memory.
    static let compactionSlack = 2000

    private(set) var entries: [Entry] = []
    private(set) var measurements: [Measurement] = []
    /// How many of `entries` / `measurements` came from earlier launches.
    private(set) var restoredEntryCount = 0
    private(set) var restoredMeasurementCount = 0
    /// The last problem writing the file (shown on the Log tab); nil while persistence works.
    private(set) var persistenceProblem: String?

    private let fileURL: URL?
    private let os = Logger(subsystem: "net.shamil.shutter-bridge.spike", category: "spike")
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private var linesInFile = 0
    /// True when the file existed but could not be read (device locked since boot): never compact then, or the
    /// rewrite would drop what is on disk.
    @ObservationIgnored private var fileUnreadable = false
    /// Lines that could not be written yet (file locked); flushed before the next successful write.
    @ObservationIgnored private var unwritten: [Data] = []
    /// The file ended mid-line (the app was killed during a write): start the next append on a fresh line.
    @ObservationIgnored private var fileEndsMidLine = false
    @ObservationIgnored private let encoder = JSONEncoder()
    /// Restored records LogScrubber changed, to report in one log line with the next append.
    @ObservationIgnored private var scrubNotePending = 0
    /// Rewrite the file after the next successful write (restored records were scrubbed after a late read).
    @ObservationIgnored private var compactAfterWrite = false

    /// One JSON line in the file: exactly one of `e` / `m` is set.
    private struct Record: Codable {
        var e: Entry?
        var m: Measurement?
    }

    /// `SpikeLog()` persists to Documents/spike-log.jsonl; pass nil for a log that lives in memory only.
    init(persistTo fileURL: URL? = SpikeLog.defaultFileURL) {
        self.fileURL = fileURL
        loadPersisted()
    }

    func note(_ text: String) { append("info", text); os.info("\(text, privacy: .public)") }
    func warn(_ text: String) { append("warn", text); os.warning("\(text, privacy: .public)") }
    func error(_ text: String) { append("error", text); os.error("\(text, privacy: .public)") }

    func measure(_ name: String, _ value: Double, _ unit: String, context: String = "") {
        let m = Measurement(id: UUID(), at: Date(), name: name, value: value, unit: unit, context: context)
        measurements.append(m)
        if measurements.count > Self.measurementLimit { measurements.removeFirst(measurements.count - Self.measurementLimit) }
        persist(Record(e: nil, m: m))
        note(String(format: "%@ = %.2f %@ %@", name, value, unit, context))
    }

    /// Records a yes/no result (value 1 or 0, unit "bool"), e.g. `usb.getPartialObject.supported`.
    func flag(_ name: String, _ value: Bool, context: String = "") {
        measure(name, value ? 1 : 0, "bool", context: context)
    }

    /// Times a block and records it as a measurement. Returns the block's result.
    func timed<T>(_ name: String, context: String = "", _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await body()
        measure(name, (clock.now - start).inSeconds, "s", context: context)
        return result
    }

    /// Records throughput for a transfer of `bytes` that took `seconds`.
    func throughput(_ name: String, bytes: Int, seconds: Double, context: String = "") {
        guard seconds > 0 else { return }
        measure(name, Double(bytes) / seconds / 1_000_000, "MB/s", context: context)
    }

    /// The latest measurement recorded under `name`, if any.
    func latest(_ name: String) -> Measurement? {
        measurements.last { $0.name == name }
    }

    /// Called once per process launch (app delegate): a separator line with the device context, so the log
    /// shows where each launch (including Bluetooth relaunches) begins and on what build.
    func noteLaunch(_ detail: String = "") {
        var line = "── launch · \(DeviceContext.current().summary)"
        if !detail.isEmpty { line += " · \(detail)" }
        if restoredEntryCount > 0 || restoredMeasurementCount > 0 {
            line += " · restored \(restoredEntryCount) entries and \(restoredMeasurementCount) measurements from earlier launches"
        }
        note(line)
    }

    /// Entries as plain text to paste into a chat or the findings page, oldest first, one per line:
    /// "23:01:15.820 WARN text". The device line comes first. Texts go through LogScrubber again in case an
    /// older entry slipped past it.
    func plainText(_ entries: some Collection<Entry>, device: DeviceContext) -> String {
        var lines = ["Spike log, \(entries.count) entries · \(device.summary)"]
        for e in entries {
            let level = e.level == "info" ? "" : " " + e.level.uppercased()
            lines.append("\(Self.lineTimeFormatter.string(from: e.at))\(level) \(LogScrubber.scrub(e.text))")
        }
        return lines.joined(separator: "\n")
    }

    /// The entries from the latest "▶ Open session" on (a test run), or every entry if there is none.
    var entriesSinceLastOpen: ArraySlice<Entry> {
        guard let start = entries.lastIndex(where: { $0.text == "▶ Open session" }) else { return entries[...] }
        return entries[start...]
    }

    private static let lineTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM HH:mm:ss.SSS"
        return f
    }()

    /// JSON with the device context first (keys are sorted: device, entries, exportedAt, measurements).
    func export() throws -> URL {
        struct Export: Codable {
            let device: DeviceContext
            let exportedAt: Date
            let entries: [Entry]
            let measurements: [Measurement]
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(Export(device: DeviceContext.current(), exportedAt: Date(), entries: entries, measurements: measurements))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spike-log-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url)
        return url
    }

    /// Empties the log in memory and on disk (the JSON Lines file is deleted).
    func clear() {
        entries.removeAll()
        measurements.removeAll()
        restoredEntryCount = 0
        restoredMeasurementCount = 0
        try? handle?.close()
        handle = nil
        unwritten.removeAll()
        linesInFile = 0
        fileUnreadable = false
        persistenceProblem = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        note("log cleared · \(DeviceContext.current().summary)")
    }

    private func append(_ level: String, _ text: String) {
        let e = Entry(id: UUID(), at: Date(), level: level, text: text)
        entries.append(e)
        if entries.count > Self.entryLimit { entries.removeFirst(entries.count - Self.entryLimit) }
        persist(Record(e: e, m: nil))
        if scrubNotePending > 0 {
            let count = scrubNotePending
            scrubNotePending = 0
            note("spike log: removed the camera serial or device UUID from \(count) restored entries and measurement contexts written by an earlier build; \(fileURL?.lastPathComponent ?? "the log file") rewritten")
        }
    }

    // MARK: - Persistence (append-only JSON Lines)

    private func loadPersisted() {
        guard let fileURL else { return }
        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            fileUnreadable = true
            reportPersistence("could not read \(fileURL.lastPathComponent) (device locked since boot?): \(error)")
            return
        }
        fileEndsMidLine = data.last.map { $0 != 0x0A } ?? false
        let decoder = JSONDecoder()
        var loadedEntries: [Entry] = []
        var loadedMeasurements: [Measurement] = []
        var lines = 0
        var unreadableLines = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            lines += 1
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else {
                unreadableLines += 1
                continue
            }
            if let e = record.e { loadedEntries.append(e) }
            if let m = record.m { loadedMeasurements.append(m) }
        }
        let scrubbedCount = Self.scrub(&loadedEntries, &loadedMeasurements)
        entries = Array(loadedEntries.suffix(Self.entryLimit))
        measurements = Array(loadedMeasurements.suffix(Self.measurementLimit))
        restoredEntryCount = entries.count
        restoredMeasurementCount = measurements.count
        linesInFile = lines
        if unreadableLines > 0 {
            os.warning("spike log: skipped \(unreadableLines) unreadable lines (a write cut short by a kill?)")
        }
        if scrubbedCount > 0 {
            // Rewrite the file too (it is in Documents, visible in the Files app, and survives app updates): with the
            // first write of this launch, which also logs the count.
            compactAfterWrite = true
            scrubNotePending = scrubbedCount
        } else if linesInFile > entries.count + measurements.count + Self.compactionSlack {
            compact()
        }
    }

    /// Runs LogScrubber over restored entry texts and measurement contexts; returns how many records changed.
    private static func scrub(_ entries: inout [Entry], _ measurements: inout [Measurement]) -> Int {
        var changed = 0
        for i in entries.indices {
            let e = entries[i]
            let text = LogScrubber.scrub(e.text)
            if text != e.text {
                entries[i] = Entry(id: e.id, at: e.at, level: e.level, text: text)
                changed += 1
            }
        }
        for i in measurements.indices {
            let m = measurements[i]
            let context = LogScrubber.scrub(m.context)
            if context != m.context {
                measurements[i] = Measurement(id: m.id, at: m.at, name: m.name, value: m.value, unit: m.unit, context: context)
                changed += 1
            }
        }
        return changed
    }

    private func persist(_ record: Record) {
        guard fileURL != nil else { return }
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        if handle == nil { openHandle() }
        guard let handle else {
            unwritten.append(line)
            if unwritten.count > Self.entryLimit { unwritten.removeFirst(unwritten.count - Self.entryLimit) }
            return
        }
        do {
            if !unwritten.isEmpty {
                for pending in unwritten { try handle.write(contentsOf: pending) }
                linesInFile += unwritten.count
                unwritten.removeAll()
            }
            try handle.write(contentsOf: line)
            linesInFile += 1
            if persistenceProblem != nil { persistenceProblem = nil }
        } catch {
            reportPersistence("write failed: \(error)")
            try? handle.close()
            self.handle = nil
            unwritten.append(line)
            return
        }
        if compactAfterWrite || (!fileUnreadable && linesInFile > entries.count + measurements.count + Self.compactionSlack) {
            compactAfterWrite = false
            compact()
        }
    }

    private func openHandle() {
        guard let fileURL else { return }
        let fm = FileManager.default
        let path = fileURL.path(percentEncoded: false)
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            // Writable while the phone is locked (after the first unlock since boot): the day-5 and day-6 tests
            // log from the background with the screen locked.
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            #else
            let attributes: [FileAttributeKey: Any] = [:]
            #endif
            guard fm.createFile(atPath: path, contents: nil, attributes: attributes) else {
                reportPersistence("could not create \(fileURL.lastPathComponent)")
                return
            }
            linesInFile = 0
        }
        // The file could not be read at launch (locked since boot): load it now that it is accessible, before the
        // unwritten lines are flushed, so the Log tab and the measurements table include the earlier launches.
        if fileUnreadable, let data = try? Data(contentsOf: fileURL) { mergePersisted(data) }
        do {
            let h = try FileHandle(forWritingTo: fileURL)
            let size = try h.seekToEnd()
            if fileEndsMidLine, size > 0 { try h.write(contentsOf: Data([0x0A])) }
            fileEndsMidLine = false
            handle = h
        } catch {
            reportPersistence("could not open \(fileURL.lastPathComponent): \(error)")
        }
    }

    /// Puts the file's records in front of what this process logged before the file became readable.
    private func mergePersisted(_ data: Data) {
        fileUnreadable = false
        fileEndsMidLine = data.last.map { $0 != 0x0A } ?? false
        let decoder = JSONDecoder()
        var oldEntries: [Entry] = []
        var oldMeasurements: [Measurement] = []
        var lines = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            lines += 1
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else { continue }
            if let e = record.e { oldEntries.append(e) }
            if let m = record.m { oldMeasurements.append(m) }
        }
        let scrubbedCount = Self.scrub(&oldEntries, &oldMeasurements)
        // Anything already written by this process is in memory too: keep the in-memory copy.
        let entryIDs = Set(entries.map(\.id)), measurementIDs = Set(measurements.map(\.id))
        oldEntries.removeAll { entryIDs.contains($0.id) }
        oldMeasurements.removeAll { measurementIDs.contains($0.id) }
        let newEntryCount = entries.count, newMeasurementCount = measurements.count
        entries = Array((oldEntries + entries).suffix(Self.entryLimit))
        measurements = Array((oldMeasurements + measurements).suffix(Self.measurementLimit))
        restoredEntryCount = max(0, entries.count - newEntryCount)
        restoredMeasurementCount = max(0, measurements.count - newMeasurementCount)
        linesInFile = lines
        os.info("spike log: read \(lines) lines from the file once it became readable; restored \(self.restoredEntryCount) entries and \(self.restoredMeasurementCount) measurements")
        if scrubbedCount > 0 {
            // The file still has the unscrubbed lines. persist (which called openHandle, which called this) rewrites
            // it from memory once its pending lines are written; compacting here would write those lines twice.
            compactAfterWrite = true
            scrubNotePending = scrubbedCount
        }
    }

    /// Rewrites the file from memory, dropping lines that fell off the in-memory limits.
    private func compact() {
        guard let fileURL, !fileUnreadable else { return }
        try? handle?.close()
        handle = nil
        var out = Data()
        for e in entries {
            if let d = try? encoder.encode(Record(e: e, m: nil)) { out.append(d); out.append(0x0A) }
        }
        for m in measurements {
            if let d = try? encoder.encode(Record(e: nil, m: m)) { out.append(d); out.append(0x0A) }
        }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        do {
            try out.write(to: fileURL, options: options)
            linesInFile = entries.count + measurements.count
        } catch {
            reportPersistence("compaction failed: \(error)")
        }
    }

    /// OSLog only: logging a persistence failure through `append` would recurse.
    private func reportPersistence(_ problem: String) {
        if persistenceProblem != problem { os.error("spike log persistence: \(problem, privacy: .public)") }
        persistenceProblem = problem
    }
}

/// Removes the camera serial (and ImageCaptureCore's device UUID, which appears to embed the USB serial) from log
/// text written by builds 1–3, which printed them in DeviceInfo lines, object identities (`… B @<serial>`), resume
/// paths (`Imports/<serial>/`), serial-mismatch warnings, the SSDP description summary and didAdd/didRemove lines.
/// SpikeLog runs it over every restored entry and measurement context at launch. What build 4 writes passes
/// through unchanged (`serial present …`, `@camera-key(…)`, `Imports/sn-…/`, `uuid=sn-…`), so it is idempotent.
/// Foundation only.
enum LogScrubber {
    private static let rules: [(NSRegularExpression, String)] = [
        // DeviceInfo, builds 1–3: "firmware 2.00, serial 4012345" (USB) and "…, serial 4012345; PTP 1.00…" (Wi-Fi).
        (#"(firmware [^,;]*, serial )(?!present \(|\(empty\)|\(redacted\))[^;\n]+"#, "$1(redacted)"),
        // The first USB build: "fw=2.00 serial=4012345 vendorExt=…".
        (#"\bserial=(?!\(redacted\))\S+"#, "serial=(redacted)"),
        // Old resume mismatch warnings, USB and Wi-Fi.
        (#"Camera serial .*? is not the saved .*?: the identity check"#,
         "The camera's serial differs from the saved read's: the identity check"),
        (#"camera serial is .*?, the saved read is from \S+"#, "the camera's serial differs from the saved read's"),
        // Object identities: "<size>B @<serial>" (build 4: "@camera-key(N chars)"; build 4 prerelease "@serial(N chars)").
        (#"(\d)B @(?!serial\(|camera-key\()[A-Za-z0-9._-]+"#, "$1B @camera-key(redacted)"),
        // Resume paths: "Imports/<serial>/". Build 4 writes "Imports/sn-…/", "Imports/uuid-sn-…/", and the serial-free
        // fallbacks "Imports/uuid-unknown/" (USB) and "Imports/unknown-serial/" (Wi-Fi).
        (#"Imports/(?!sn-|uuid-sn-|uuid-unknown/|unknown-serial/|…/)[^/\s]+/"#, "Imports/…/"),
        // The empty-serial fallback "uuid-<raw device UUID>" anywhere else, such as its warning (after the two rules
        // above, which replace it whole). Build 4 writes "uuid-sn-…" or "uuid-unknown".
        (#"\buuid-(?!sn-|unknown\b|\(redacted\))[0-9A-Za-z-]+"#, "uuid-(redacted)"),
        // DeviceBrowser's didAdd/didRemove, "uuid=<raw>" (build 4 writes "uuid=sn-…" or "uuid=-").
        (#"\buuid=(?!sn-|-(?:\s|$)|\(redacted\))\S+"#, "uuid=(redacted)"),
        // SSDP description summary, builds 1–3: `… · serialNumber <value> · UDN …`, with "-" for no serial. Only that
        // shape: build 4's own lines that mention serialNumber ("no serialNumber in it", "could not zero the
        // serialNumber", "serialNumber present (…)" / "absent") must pass through.
        (#"(?<= · )serialNumber -(?= · UDN )"#, "serialNumber absent"),
        (#"(?<= · )serialNumber (?!present \(|absent(?= · )|\(redacted\)(?= · )|-(?= · ))[^\n]*?(?= · UDN )"#,
         "serialNumber (redacted)"),
    ].map { pattern, template in
        // The patterns are constants: a bad one is a programming error caught the first time the app runs.
        (try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]), template)
    }

    /// Every rule's match contains one of these: a record without any is left alone without running the regexes,
    /// which keeps the scrub cheap on every launch (up to 2,000 entries and 10,000 measurement contexts).
    private static let triggers = ["serial", "uuid", "B @", "Imports/"]

    /// `text` with every serial or device UUID of the old formats replaced.
    static func scrub(_ text: String) -> String {
        guard triggers.contains(where: { text.contains($0) }) else { return text }
        var out = text
        for (regex, template) in rules {
            let range = NSRange(out.startIndex..., in: out)
            guard regex.firstMatch(in: out, range: range) != nil else { continue }
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }
}

extension SpikeLog {
    /// docs/spike-plan.md's measurements table, filled from the latest value of each measurement (day 10).
    func measurementsTableMarkdown(serviceUUID: String?) -> String {
        let samples = measurements.map {
            MeasurementsTable.Sample(name: $0.name, value: $0.value, unit: $0.unit, context: $0.context, at: $0.at)
        }
        return MeasurementsTable.markdown(samples: samples, serviceUUID: serviceUUID, device: DeviceContext.current())
    }
}

extension Duration {
    /// Seconds as a Double, for MB/s and ms arithmetic.
    var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

extension Data {
    /// "1A 2B 3C …" for the first `limit` bytes; what we paste into the findings page.
    func hexDump(limit: Int = 64) -> String {
        let shown = prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > limit ? shown + " … (\(count) bytes)" : shown
    }
}
