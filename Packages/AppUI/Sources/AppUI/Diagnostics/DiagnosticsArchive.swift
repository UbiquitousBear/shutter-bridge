import Foundation

/// One line of the app's own log, as the export holds it. The unified log's entries (`OSLogStore`) and the rolling file's
/// lines both become these, so the archive treats them alike.
public struct DiagnosticsLogEntry: Sendable, Hashable {
    /// The unified log's levels, as far as the app uses them; an unknown level reads as `notice`.
    public enum Level: String, Sendable, Hashable, CaseIterable {
        case debug, info, notice, error, fault
    }

    public var date: Date
    /// The logger's category ("browse" for the bench lines).
    public var category: String
    public var level: Level
    public var message: String

    public init(date: Date, category: String, level: Level = .notice, message: String) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }
}

/// Where the current launch's log lines come from: the unified log in the app (`LogStoreReader`), a fake in tests.
public protocol LogEntrySource: Sendable {
    func entries() async throws -> [DiagnosticsLogEntry]
}

/// The lines of one launch of the app. The current launch is the one being exported.
public struct DiagnosticsLaunch: Sendable, Hashable {
    /// When the launch began, when known.
    public var started: Date?
    public var isCurrent: Bool
    public var entries: [DiagnosticsLogEntry]

    public init(started: Date?, isCurrent: Bool, entries: [DiagnosticsLogEntry]) {
        self.started = started
        self.isCurrent = isCurrent
        self.entries = entries
    }
}

/// What the archive says before the log: versions, the cameras the app knows with their firmware, the link last used.
/// The caller fills it from what the app already holds; it carries no serial number, and the redactor sees it anyway.
public struct DiagnosticsHeader: Sendable, Hashable {
    /// A camera the app knows: its model ("ILCE-7CM2") and the firmware version last read from it, in the words the log
    /// uses (`PTPFirmwareVersion`'s string); nil when it has not been read (a camera only ever seen over USB mass storage
    /// never gives one).
    public struct Camera: Sendable, Hashable {
        public var model: String
        public var firmware: String?

        public init(model: String, firmware: String?) {
            self.model = model
            self.firmware = firmware
        }
    }

    /// "1.0" and "19", from the bundle.
    public var appVersion: String
    public var appBuild: String
    /// "27.0".
    public var systemVersion: String
    /// The phone's class, never its name or identifier: "iPhone".
    public var deviceClass: String
    public var cameras: [Camera]
    /// The link the app last used, in words ("Wi-Fi", "USB"); nil when it hasn't imported.
    public var lastLink: String?
    public var exportedAt: Date

    public init(appVersion: String, appBuild: String, systemVersion: String, deviceClass: String, cameras: [Camera] = [],
                lastLink: String? = nil, exportedAt: Date) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.systemVersion = systemVersion
        self.deviceClass = deviceClass
        self.cameras = cameras
        self.lastLink = lastLink
        self.exportedAt = exportedAt
    }
}

/// The plain-text diagnostics file (backlog section 6): a header, then the log entries launch by launch and within each
/// launch oldest first, every line redacted. An app on iOS can't write a `.logarchive`, so this is text.
public enum DiagnosticsArchive {
    /// How the archive opens. Said once, so a person reading the file knows what it holds and that it stayed on the phone.
    static let preamble = "Shutter Bridge diagnostics. This file holds the app's own log lines, with network names, serial "
        + "numbers, identifiers and addresses removed. It was written on the phone and sent nowhere; it leaves only if you share it."

    /// The text of the archive. The whole text goes through `redactor`, header and log alike.
    public static func render(header: DiagnosticsHeader, launches: [DiagnosticsLaunch],
                              redactor: DiagnosticsRedactor) -> String {
        var lines: [String] = [preamble, ""]
        lines.append("Exported: \(timestamp(header.exportedAt))")
        lines.append("App: \(header.appVersion) (\(header.appBuild))")
        lines.append("iOS: \(header.systemVersion)")
        lines.append("Phone: \(header.deviceClass)")
        if header.cameras.isEmpty {
            lines.append("Camera: none known")
        }
        for camera in header.cameras {
            lines.append("Camera: \(camera.model), firmware \(camera.firmware ?? "not read")")
        }
        lines.append("Last link: \(header.lastLink ?? "none yet")")
        // Oldest launch first; the current launch is always last.
        let ordered = launches.enumerated().sorted { lhs, rhs in
            if lhs.element.isCurrent != rhs.element.isCurrent { return !lhs.element.isCurrent }
            switch (lhs.element.started, rhs.element.started) {
            case let (a?, b?) where a != b: return a < b
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        if ordered.isEmpty {
            lines.append("")
            lines.append("No log lines were available.")
        }
        for launch in ordered {
            lines.append("")
            let when = launch.started.map { ", started \(timestamp($0))" } ?? ""
            lines.append(launch.isCurrent ? "=== This launch\(when) ===" : "=== An earlier launch\(when) ===")
            if launch.entries.isEmpty { lines.append("(no lines)") }
            // Stable: lines with the same time stay in the order they were given.
            let entries = launch.entries.enumerated().sorted { lhs, rhs in
                lhs.element.date != rhs.element.date ? lhs.element.date < rhs.element.date : lhs.offset < rhs.offset
            }.map(\.element)
            for entry in entries {
                // A message with line breaks keeps them, indented, so one entry never looks like several.
                let message = entry.message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\n    ")
                lines.append("\(timestamp(entry.date)) \(entry.level.rawValue) [\(entry.category)] \(message)")
            }
        }
        return redactor.redact(lines.joined(separator: "\n")) + "\n"
    }

    /// The archive from its sources: the earlier launches from the rolling file and this launch from `current` (the unified
    /// log). When `current` gives nothing or fails, this launch's lines in the rolling file stand in. A source that
    /// throws never fails the export; the archive says the lines couldn't be read.
    public static func build(header: DiagnosticsHeader, current: (any LogEntrySource)?, rollingFile: RollingLogFile?,
                             redactor: DiagnosticsRedactor) async -> String {
        var launches = rollingFile?.earlierLaunches() ?? []
        var entries: [DiagnosticsLogEntry] = []
        var unreadable = false
        if let current {
            do { entries = try await current.entries() } catch { unreadable = true }
        }
        let started = rollingFile?.launchStarted
        if entries.isEmpty, let stored = rollingFile?.currentLaunch().entries { entries = stored }
        if unreadable, entries.isEmpty {
            entries = [DiagnosticsLogEntry(date: header.exportedAt, category: "diagnostics",
                                           message: "This launch's log lines could not be read from the system log.")]
        }
        launches.append(DiagnosticsLaunch(started: started, isCurrent: true, entries: entries))
        return render(header: header, launches: launches, redactor: redactor)
    }

    /// "2026-11-11T09:30:00.123Z": UTC, to the millisecond, the same on every phone.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
