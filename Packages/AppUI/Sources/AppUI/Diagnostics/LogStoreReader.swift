#if canImport(OSLog)
import Foundation
import OSLog

/// This launch's log lines from the unified log: `OSLogStore(scope: .currentProcessIdentifier)`, filtered to the app's
/// subsystem. The current process only gives this launch's entries; earlier launches come from `RollingLogFile`. Compiled
/// only where OSLog exists (the Mac and CI's Xcode job); the archive's logic is tested on Linux through `LogEntrySource`.
///
/// Entries are read with their composed message; the bench lines are logged public, so they are there in full. Private
/// interpolations would read `<private>`.
public struct LogStoreReader: LogEntrySource {
    public let subsystem: String

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "net.shamil.shutter-bridge") {
        self.subsystem = subsystem
    }

    public func entries() async throws -> [DiagnosticsLogEntry] {
        let subsystem = subsystem
        // The store can take a while on a long launch: off the caller's executor.
        return try await Task.detached(priority: .utility) { try Self.read(subsystem: subsystem) }.value
    }

    private static func read(subsystem: String) throws -> [DiagnosticsLogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let sequence = try store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0),
                                            matching: NSPredicate(format: "subsystem == %@", subsystem))
        var result: [DiagnosticsLogEntry] = []
        for entry in sequence {
            guard let log = entry as? OSLogEntryLog, log.subsystem == subsystem else { continue }
            result.append(DiagnosticsLogEntry(date: log.date, category: log.category, level: level(of: log),
                                              message: log.composedMessage))
        }
        return result
    }

    private static func level(of entry: OSLogEntryLog) -> DiagnosticsLogEntry.Level {
        switch entry.level {
        case .debug: .debug
        case .info: .info
        case .error: .error
        case .fault: .fault
        default: .notice
        }
    }
}
#endif
