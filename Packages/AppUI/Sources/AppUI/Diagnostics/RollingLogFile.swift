import Foundation
import Synchronization

/// The app's own log lines kept on the phone for the last few launches (decision D8, recommendation (b)), so a problem
/// seen before a relaunch can still be exported. One file per launch in a folder under Caches; at most `maxLaunches`
/// launches and `maxBytes` in all (the oldest launch goes first, and a single launch past the budget loses its oldest
/// lines). Caches, so the system may empty it and nothing is backed up. The file stays on the phone until the person
/// shares an export; nothing here reads it except `DiagnosticsArchive`.
///
/// Writing never throws and never blocks the caller for long: a failed write drops the line. The lines are the app's own
/// bench lines, which hold names, sizes and times only; the archive redacts them again when it is made, with the values
/// the app knows are private by then.
public final class RollingLogFile: Sendable, BenchLog {
    public static let folderName = "Diagnostics"
    public static let defaultMaxLaunches = 3
    /// 5 MB, in all, across the launches.
    public static let defaultMaxBytes = 5 * 1_024 * 1_024
    /// A longer message is cut to this many characters, so one line can't use the budget.
    static let maxMessageCharacters = 4_000

    /// When this launch began (the time its file was made).
    public let launchStarted: Date

    private let directory: URL
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let state: Mutex<State>

    private struct StoredFile {
        var url: URL
        var started: Date
        var size: Int
    }

    private struct State {
        /// Earlier launches, oldest first.
        var earlier: [StoredFile]
        var current: StoredFile
        var directoryReady = false
    }

    /// Starts a launch: finds the earlier launches' files, removes the oldest so that this one makes `maxLaunches`, and
    /// leaves this launch's file to be made by its first line.
    public init(directory: URL, maxLaunches: Int = defaultMaxLaunches, maxBytes: Int = defaultMaxBytes,
                launchStarted: Date = Date(), now: @escaping @Sendable () -> Date = { Date() }) {
        let directory = directory.standardizedFileURL
        self.directory = directory
        self.maxBytes = max(1_024, maxBytes)
        self.launchStarted = launchStarted
        self.now = now
        var earlier = Self.storedFiles(in: directory)
        let keep = max(0, maxLaunches - 1)
        while earlier.count > keep {
            try? FileManager.default.removeItem(at: earlier.removeFirst().url)
        }
        let current = StoredFile(url: directory.appendingPathComponent(Self.fileName(started: launchStarted)),
                                 started: launchStarted, size: 0)
        state = Mutex(State(earlier: earlier, current: current))
    }

    /// `Library/Caches/Diagnostics` in the app's container.
    public static func inCaches(launchStarted: Date = Date()) -> RollingLogFile {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RollingLogFile(directory: caches.appendingPathComponent(folderName, isDirectory: true),
                              launchStarted: launchStarted)
    }

    // MARK: Writing

    /// `BenchLog`: a bench line at the notice level, in the bench's category.
    public func note(_ line: String) {
        append(DiagnosticsLogEntry(date: now(), category: "browse", level: .notice, message: line))
    }

    /// Adds one entry to this launch's file, first making room within the budget.
    public func append(_ entry: DiagnosticsLogEntry) {
        var message = entry.message
        if message.count > Self.maxMessageCharacters { message = String(message.prefix(Self.maxMessageCharacters)) + "…" }
        let line = Self.encode(DiagnosticsLogEntry(date: entry.date, category: entry.category, level: entry.level,
                                                   message: message))
        let data = Data(line.utf8)
        state.withLock { state in
            if !state.directoryReady {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                state.directoryReady = true
            }
            // Make room: the oldest earlier launch first.
            var total = state.earlier.reduce(0) { $0 + $1.size } + state.current.size
            while total + data.count > maxBytes, !state.earlier.isEmpty {
                let removed = state.earlier.removeFirst()
                try? FileManager.default.removeItem(at: removed.url)
                total -= removed.size
            }
            // This launch alone is over: keep its newest lines, up to half the budget, so the cut isn't made on every line.
            if total + data.count > maxBytes, state.current.size > 0 {
                state.current.size = Self.trim(state.current.url, toAtMost: max(0, maxBytes / 2 - data.count))
            }
            if Self.write(data, to: state.current.url) {
                state.current.size += data.count
            } else {
                // The system may have emptied Caches since the folder was made: make it again and write once more. The
                // files it held are gone, so what is left is what is on disk now.
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if Self.write(data, to: state.current.url) {
                    state.earlier = Self.storedFiles(in: directory).filter { $0.url != state.current.url }
                    state.current.size = Self.size(of: state.current.url)
                }
            }
        }
    }

    // MARK: Reading

    /// The earlier launches' entries, oldest launch first. A file that can't be read is skipped.
    public func earlierLaunches() -> [DiagnosticsLaunch] {
        state.withLock { $0.earlier }.map { file in
            DiagnosticsLaunch(started: file.started, isCurrent: false, entries: Self.entries(in: file.url))
        }
    }

    /// This launch's entries as the file holds them.
    public func currentLaunch() -> DiagnosticsLaunch {
        let file = state.withLock { $0.current }
        return DiagnosticsLaunch(started: file.started, isCurrent: true, entries: Self.entries(in: file.url))
    }

    /// Bytes on disk across every launch kept (for tests and the budget).
    public var totalBytes: Int {
        state.withLock { $0.earlier.reduce(0) { $0 + $1.size } + $0.current.size }
    }

    // MARK: Files

    private static let prefix = "launch-"
    private static let suffix = ".log"

    /// "launch-<milliseconds since 1970, 15 digits>-<8 characters>.log": sorts by time, and two launches in the same
    /// millisecond (tests) stay apart.
    static func fileName(started: Date) -> String {
        let milliseconds = max(0, Int((started.timeIntervalSince1970 * 1_000).rounded()))
        let digits = String(milliseconds)
        let padded = String(repeating: "0", count: max(0, 15 - digits.count)) + digits
        return "\(prefix)\(padded)-\(UUID().uuidString.prefix(8))\(suffix)"
    }

    private static func storedFiles(in directory: URL) -> [StoredFile] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [StoredFile] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let digits = name.dropFirst(prefix.count).prefix(15)
            guard digits.count == 15, let milliseconds = Int(digits) else { continue }
            files.append(StoredFile(url: url, started: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
                                    size: size(of: url)))
        }
        return files.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
            return true
        } catch {
            return false
        }
    }

    /// Rewrites the file with its newest whole lines that fit `limit` bytes; returns the new size.
    private static func trim(_ url: URL, toAtMost limit: Int) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        var start = data.endIndex
        var size = 0
        // Walk back over lines (each ends in a newline) until the next one wouldn't fit.
        var lineEnd = data.endIndex
        while lineEnd > data.startIndex {
            let beforeNewline = data.index(before: lineEnd)
            let lineStart = data[data.startIndex..<beforeNewline].lastIndex(of: 0x0A).map { data.index(after: $0) }
                ?? data.startIndex
            let lineSize = lineEnd - lineStart
            if size + lineSize > limit { break }
            size += lineSize
            start = lineStart
            lineEnd = lineStart
        }
        let kept = Data(data[start..<data.endIndex])
        do { try kept.write(to: url) } catch { return data.count }
        return kept.count
    }

    private static func entries(in url: URL) -> [DiagnosticsLogEntry] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { decode(String($0)) }
    }

    // MARK: Lines

    /// "<milliseconds since 1970> TAB <level> TAB <category> TAB <message> LF", with backslash, tab, carriage return and
    /// line feed in the category and message written as \\, \t, \r and \n so a line is always one line.
    static func encode(_ entry: DiagnosticsLogEntry) -> String {
        let milliseconds = Int((entry.date.timeIntervalSince1970 * 1_000).rounded())
        return "\(milliseconds)\t\(entry.level.rawValue)\t\(escape(entry.category))\t\(escape(entry.message))\n"
    }

    static func decode(_ line: String) -> DiagnosticsLogEntry? {
        let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let milliseconds = Int(fields[0]) else { return nil }
        return DiagnosticsLogEntry(date: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
                                   category: unescape(String(fields[2])),
                                   level: DiagnosticsLogEntry.Level(rawValue: String(fields[1])) ?? .notice,
                                   message: unescape(String(fields[3])))
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n", "\r\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out
    }

    private static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }
}
