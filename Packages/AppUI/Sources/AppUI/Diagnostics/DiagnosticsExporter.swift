import Catalogue
import Foundation
import Synchronization

// Settings › Export Diagnostics… (backlog section 6; I8): builds the plain-text archive (`DiagnosticsArchive`) from what the app
// knows, writes it to a temporary folder of its own, and hands the file to the share sheet; the folder is emptied afterwards,
// as `JPEGScratch` does for a JPEG. Nothing here makes a network call. Plain Swift, tested on Linux with a fake log source and
// an in-memory catalogue; the unified log's reader (`LogStoreReader`) and the share sheet (`SharePresenter`) are the Apple half.

/// One export, written and waiting to be shared: its file, in a folder that `DiagnosticsExporting.discard(_:)` removes.
public struct DiagnosticsExport: Sendable, Hashable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }
}

/// Makes and discards exports: `DiagnosticsExporter` in the app, a fake in tests.
public protocol DiagnosticsExporting: Sendable {
    /// Builds the archive and writes it to a new temporary folder.
    func makeExport() async throws -> DiagnosticsExport
    /// Removes the export's folder, whether it was shared or not. Safe to call twice.
    func discard(_ export: DiagnosticsExport)
}

/// The facts of the app and the phone that the archive's header holds. No name, identifier or model of the phone: its class.
public struct DiagnosticsAppInfo: Sendable, Hashable {
    public var appVersion: String
    public var appBuild: String
    public var systemVersion: String
    public var deviceClass: String

    public init(appVersion: String, appBuild: String, systemVersion: String, deviceClass: String = "iPhone") {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.systemVersion = systemVersion
        self.deviceClass = deviceClass
    }

    /// From the main bundle and the system ("1.0", "19", "27.0").
    public static func current() -> DiagnosticsAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsAppInfo(appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                                  appBuild: info["CFBundleVersion"] as? String ?? "unknown",
                                  systemVersion: "\(version.majorVersion).\(version.minorVersion)")
    }
}

/// The firmware version the app last read from a camera this launch (Wi-Fi's DeviceInfo, in the words the log uses), kept
/// for the archive's header. The read carries no camera key, so the header uses it only when one camera is known.
public final class CameraFirmwareNotes: Sendable {
    private let value = Mutex<String?>(nil)

    public init() {}

    public func note(_ firmware: String) { value.withLock { $0 = firmware } }

    public var latest: String? { value.withLock { $0 } }
}

/// What the catalogue says that the header and the redactor need: the cameras' models, the link last used, and every value
/// the redactor must remove wherever it appears.
struct DiagnosticsFacts: Sendable {
    var cameras: [DiagnosticsHeader.Camera] = []
    var lastLink: String?
    var privateValues: [String] = []

    /// Reads the cameras; a catalogue that can't be read gives nothing (the archive says "Camera: none known").
    static func read(from catalogue: (any CatalogueStore)?, firmware: String?) async -> DiagnosticsFacts {
        guard let catalogue, let records = try? await catalogue.cameras() else { return DiagnosticsFacts() }
        let withModel = records.filter { !$0.model.isEmpty }
        // The firmware read has no camera attached, so it is placed only where it can't be wrong.
        let known = withModel.count == 1 ? firmware : nil
        var facts = DiagnosticsFacts()
        facts.cameras = withModel.map { .init(model: $0.model, firmware: known) }
        if let latest = records.max(by: { $0.lastSeen < $1.lastSeen }), latest.lastSeen != .distantPast {
            facts.lastLink = latest.preferredCarrier == .wifi ? "Wi-Fi" : "USB"
        }
        for record in records {
            if let ssid = record.wifiSSID { facts.privateValues.append(ssid) }
            if let ip = record.lastIP { facts.privateValues.append(ip) }
            if let guid = record.ptpipGUID { facts.privateValues.append(guid.uuidString) }
            if let id = record.bluetoothPeripheralID { facts.privateValues.append(id.uuidString) }
            // A name the person gave the camera; not when it only repeats the model, which the header names.
            if !record.friendlyName.isEmpty, record.friendlyName.caseInsensitiveCompare(record.model) != .orderedSame {
                facts.privateValues.append(record.friendlyName)
            }
        }
        return facts
    }
}

/// Builds the export: the header from `info`, the catalogue and the firmware notes, the earlier launches from the rolling file
/// and this launch from the unified log, all redacted with the values the catalogue knows are private. The file goes in a
/// folder of its own under `scratch` (a different folder from the rolling file's).
public struct DiagnosticsExporter: DiagnosticsExporting {
    /// The folder under the caches that holds every export's folder.
    public static let folderName = "DiagnosticsExport"

    public let scratch: URL
    private let info: DiagnosticsAppInfo
    private let catalogue: (any CatalogueStore)?
    private let firmware: CameraFirmwareNotes?
    private let current: (any LogEntrySource)?
    private let rollingFile: RollingLogFile?
    private let now: @Sendable () -> Date

    public init(scratch: URL, info: DiagnosticsAppInfo, catalogue: (any CatalogueStore)?,
                firmware: CameraFirmwareNotes? = nil, current: (any LogEntrySource)?, rollingFile: RollingLogFile?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.scratch = scratch.standardizedFileURL
        self.info = info
        self.catalogue = catalogue
        self.firmware = firmware
        self.current = current
        self.rollingFile = rollingFile
        self.now = now
    }

    /// `Library/Caches/DiagnosticsExport` in the app's container.
    public static func scratchInCaches() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(folderName, isDirectory: true)
    }

    public func makeExport() async throws -> DiagnosticsExport {
        let facts = await DiagnosticsFacts.read(from: catalogue, firmware: firmware?.latest)
        let exportedAt = now()
        let header = DiagnosticsHeader(appVersion: info.appVersion, appBuild: info.appBuild,
                                       systemVersion: info.systemVersion, deviceClass: info.deviceClass,
                                       cameras: facts.cameras, lastLink: facts.lastLink, exportedAt: exportedAt)
        let text = await DiagnosticsArchive.build(header: header, current: current, rollingFile: rollingFile,
                                                  redactor: DiagnosticsRedactor(privateValues: facts.privateValues))
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent(Self.fileName(for: exportedAt), isDirectory: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return DiagnosticsExport(fileURL: file)
    }

    /// Removes the export's folder. Does nothing for a file that isn't directly inside a folder of `scratch`, so a wrong URL
    /// can never delete anything else.
    public func discard(_ export: DiagnosticsExport) {
        let folder = export.fileURL.standardizedFileURL.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().path == scratch.path, !folder.lastPathComponent.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every export left from before (a crash or a kill while the share sheet was up), at launch. Returns how many.
    @discardableResult
    public func removeLeftovers() -> Int {
        guard let children = try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        for child in children where (try? FileManager.default.removeItem(at: child)) != nil { removed += 1 }
        return removed
    }

    /// "ShutterBridge-diagnostics-20261111-093000.txt": UTC, no colons or spaces, so it sorts and survives any file system.
    static func fileName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "ShutterBridge-diagnostics-\(c.year ?? 0)\(two(c.month))\(two(c.day))-\(two(c.hour))\(two(c.minute))\(two(c.second)).txt"
    }
}

/// The Settings row's words.
public enum DiagnosticsWording {
    public static let rowTitle = AppText.string("Export Diagnostics…")
    /// Under the row: what is in the file, and that nothing is sent anywhere until the person shares it.
    public static let footer = AppText.string("Exports a text file of this app's own log: what it did, when, and how "
        + "it went, with "
        + "network names, serial numbers, identifiers and addresses removed. It is made on this iPhone and sent "
        + "nowhere "
        + "until you choose where to share it.")
    public static let accessibilityHint = AppText.string("Makes a text file of the app's log and opens the share "
        + "sheet. Nothing is "
        + "sent until you choose where to share it.")
    public static let preparing = AppText.string("Preparing the file…")
    public static let failed = AppText.string("The diagnostics file couldn't be made. Try again.")
    public static let couldNotShare = AppText.string("The share sheet couldn't be shown. Try again.")
}
