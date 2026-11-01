import Foundation
import PTPKit

// Resume over USB (spike-plan measurements row "Resume after link drop verified", USB column).
//
// The pure half of the test: what is persisted, where the bytes go, and how a `.part` file is extended. The
// ImageCaptureCore half (the GetPartialObject loop, finding the object again after a re-plug, the SHA check)
// lives in CameraSession's "Resume over USB" section. This file imports only Foundation and PTPKit so it can be
// typechecked on Linux.
//
// Flow on the bench:
//   1. "Start resumable read": newest ARW → Caches/Imports/<camera serial>/<filename>.part, paced so there is
//      time to pull the cable. State is saved at every 16 MiB checkpoint and on every error.
//   2. Pull the cable mid-read. The loop stops on the error / didRemove and saves the offset it reached.
//   3. Re-plug, open a new session, "Resume read": the object is found again by identity (handles are not stable
//      across sessions), PTPPartialRead.resumeOffset decides where to continue, and the finished `.part` is
//      compared with a requestReadData SHA-256 of the same file.

/// What "Resume read" needs after a cable pull. Persisted as JSON in UserDefaults.
struct USBResumeState: Codable, Equatable {
    /// (camera serial, filename, capture date, size): the key the object is found by after a re-plug.
    var identity: PTPObjectIdentity
    /// Bytes known to be on disk in the `.part` file when this was saved.
    var offset: UInt64
    /// The `.part` file, relative to the Caches directory (the app container path can change between launches).
    var partPath: String
    var savedAt: Date
    /// Why it was saved: "started", "checkpoint", "error: …", "complete".
    var reason: String
    /// The CameraSession that saved it. A cable pull always means a new CameraSession; Stop, a timeout or a PTP
    /// error do not, so a resume in the same one is not a link-drop resume. Optional so older saves still decode.
    var sessionID: UUID?

    var percent: Double { identity.size == 0 ? 0 : Double(offset) / Double(identity.size) * 100 }

    var summary: String {
        String(format: "%@ at %.1f of %.1f MB (%.0f%%), %@",
               identity.filename as NSString, Double(offset) / 1_000_000, Double(identity.size) / 1_000_000, percent,
               reason as NSString)
    }
}

enum USBResumeStore {
    static let defaultsKey = "usb.resume.state"

    static func load(_ defaults: UserDefaults = .standard) -> USBResumeState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(USBResumeState.self, from: data)
    }

    static func save(_ state: USBResumeState, _ defaults: UserDefaults = .standard) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(state), forKey: defaultsKey)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

enum USBResumePaths {
    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// "Imports/<serial>/<filename>.part", relative to Caches.
    static func relativePartPath(serial: String, filename: String) -> String {
        "Imports/\(sanitised(serial))/\(sanitised(filename)).part"
    }

    static func url(relative: String) -> URL {
        caches.appendingPathComponent(relative, isDirectory: false)
    }

    /// Keeps a camera-supplied string from escaping its folder.
    static func sanitised(_ component: String) -> String {
        var out = ""
        for ch in component {
            if ch == "/" || ch == "\\" || ch == ":" || ch == "\0" { out.append("_") } else { out.append(ch) }
        }
        while out.hasPrefix(".") { out = "_" + out.dropFirst() }
        return out.isEmpty ? "unknown" : out
    }
}

/// Appends bytes to a `.part` file from a known offset. The file is truncated to that offset first, so bytes
/// written after the last saved checkpoint (and never recorded) are discarded rather than duplicated.
final class PartFileWriter {
    let url: URL
    private let handle: FileHandle
    private(set) var offset: UInt64
    private var closed = false

    init(url: URL, startingAt offset: UInt64) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: offset)
        let end = try handle.seekToEnd()
        self.offset = end
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// Makes the bytes written so far durable before their offset is persisted.
    func flush() throws {
        try handle.synchronize()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? handle.synchronize()
        try? handle.close()
    }

    deinit { close() }

    /// Size of a file on disk, or nil if it does not exist.
    static func sizeOnDisk(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }
}
