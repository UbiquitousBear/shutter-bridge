import Foundation

/// Staged downloads use complete-until-first-unlock file protection, never `complete` (decision 9): a `complete` file
/// can't be read about 10 s after the phone locks, and Photos then fails the save with `PHPhotosErrorDomain` 3302
/// (spike, K1), while a complete-until-first-unlock file saved 26 s after the lock in 0.1 s.
///
/// Whoever creates the staging folder calls `prepareDirectory(_:)`, so files created in it inherit the class; the
/// Photos destination also checks each file before a save. Data protection exists on iOS only: elsewhere (Linux,
/// macOS tests) these do nothing.
public enum StagingProtection {
    /// Creates `directory` if needed and gives it complete-until-first-unlock protection.
    public static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: directory.path)
        #endif
    }

    /// Gives one staged file complete-until-first-unlock protection.
    public static func apply(to file: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: file.path)
        #endif
    }

    /// Best effort: if the file is `complete`, lowers it to complete-until-first-unlock. While the phone is locked a
    /// `complete` file can't be changed either, and the save then fails as it would have.
    static func relaxIfComplete(_ file: URL) {
        #if os(iOS)
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let current = attributes?[.protectionKey] as? FileProtectionType, current == .complete {
            try? apply(to: file)
        }
        #endif
    }
}
