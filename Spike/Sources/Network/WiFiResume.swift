import Foundation
import PTPKit

// Day 9: what a resumable PTP/IP read persists, so "Start resumable read" can be cut off by turning Wi-Fi off
// and "Resume read" can carry on from the last checkpoint after a fresh handshake and OpenSession. This mirrors
// the proposal's engine rule (§ Import engine design, resume rules): the object is found again by identity,
// never by handle, and PTPPartialRead.resumeOffset decides whether the saved offset still applies.
//
// Foundation and PTPKit only, so it typechecks on Linux.

/// One partial download in flight. Saved as JSON in UserDefaults at every 16 MiB checkpoint and on error.
struct WiFiResumeRecord: Codable, Equatable, Sendable {
    var identity: PTPObjectIdentity
    /// Bytes on disk that are trusted: everything before this offset was written by whole chunks.
    var offset: UInt64
    /// Relative to the Caches directory: "Imports/<serial>/<filename>.part".
    var partPath: String
    /// SHA-256 of the same object fetched whole with GetObject ("Reference hash"), if one was taken.
    var referenceSHA256: String?
    /// PTPPartialRead.Variant raw value: "standard32" or "extended64".
    var variant: String
    var chunkSize: UInt32
    /// "ap" or "lan": the measurement column this read belongs to.
    var net: String
    /// How many times the read has been resumed. resume.verified is only flagged when this is > 0.
    var resumes: Int
    var savedAt: Date

    var fractionDone: Double { identity.size == 0 ? 0 : Double(offset) / Double(identity.size) }

    var summary: String {
        String(format: "%@ at %.0f %% (%llu of %llu bytes), %ld resume(s), saved %@",
               identity.filename, fractionDone * 100, offset, identity.size, resumes,
               DateFormatter.localizedString(from: savedAt, dateStyle: .none, timeStyle: .medium))
    }
}

/// The whole-file SHA-256 that a reassembled partial read is compared against.
struct WiFiReferenceHash: Codable, Equatable, Sendable {
    var identity: PTPObjectIdentity
    var sha256: String
    var bytes: UInt64
    var savedAt: Date
}

enum WiFiResumeStore {
    static let recordKey = "ptpip.resume.record"
    static let referenceKey = "ptpip.resume.reference"

    // MARK: Records

    static func load() -> WiFiResumeRecord? { decode(WiFiResumeRecord.self, key: recordKey) }

    /// Returns false (and the caller logs it) if the record could not be encoded.
    @discardableResult
    static func save(_ record: WiFiResumeRecord) -> Bool { encode(record, key: recordKey) }

    static func clear() { UserDefaults.standard.removeObject(forKey: recordKey) }

    static func loadReference() -> WiFiReferenceHash? { decode(WiFiReferenceHash.self, key: referenceKey) }

    @discardableResult
    static func saveReference(_ reference: WiFiReferenceHash) -> Bool { encode(reference, key: referenceKey) }

    // MARK: Part files

    /// "Imports/<serial>/<filename>.part", with path separators and leading dots made harmless.
    static func partRelativePath(serial: String, filename: String) -> String {
        "Imports/\(safeComponent(serial))/\(safeComponent(filename)).part"
    }

    static func url(forRelativePath path: String) -> URL {
        cachesDirectory.appending(path: path, directoryHint: .notDirectory)
    }

    /// The app's Caches folder (FileManager form rather than URL.cachesDirectory so this file typechecks on Linux).
    static var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    static func safeComponent(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "unknown" : out
    }

    // MARK: Coding

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }
}

enum WiFiPartFile {
    /// Opens `url` for writing at `offset`, creating the file and its folder if needed and dropping anything
    /// past `offset`: bytes written after the last saved offset (a chunk cut off by the link drop) are not trusted.
    static func open(_ url: URL, at offset: UInt64) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)
        } catch {
            try? handle.close()
            throw error
        }
        return handle
    }

    /// Current size of the file at `url`, or 0 if it doesn't exist.
    static func size(_ url: URL) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()) ?? 0
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
