import Foundation

// Whether staged files in iCloud Drive have uploaded (staging PR 7, bench S10). The values, the error classification
// and the reading protocol are pure Foundation, tested on Linux; the reader over the files' URL resource values
// (`UbiquitousUploadReader`) is iOS only, compiled only by CI.

/// An uploading error as iOS reported it: its domain and code, and those of the error under it, if any. Never a
/// message, a file name or a path, so it can go in the bench log as it is (`description`).
public struct UploadErrorSeen: Sendable, Hashable, CustomStringConvertible {
    public var domain: String
    public var code: Int
    /// `NSUnderlyingErrorKey`'s domain and code, when there was an error under it.
    public var underlyingDomain: String?
    public var underlyingCode: Int?

    public init(domain: String, code: Int, underlyingDomain: String? = nil, underlyingCode: Int? = nil) {
        self.domain = domain
        self.code = code
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
    }

    /// "NSCocoaErrorDomain 4354", or "BRCloudDocsErrorDomain 35 over NSCocoaErrorDomain 4354" with an error under it.
    public var description: String {
        guard let underlyingDomain, let underlyingCode else { return "\(domain) \(code)" }
        return "\(domain) \(code) over \(underlyingDomain) \(underlyingCode)"
    }
}

/// Why iCloud Drive hasn't uploaded a staged file, from the file's `ubiquitousItemUploadingError`.
public enum UploadProblem: Sendable, Hashable {
    /// The person's iCloud storage is full (`NSUbiquitousFileNotUploadedDueToQuotaError`, 4354), with the error as it
    /// was reported, so the bench log can settle which domain iOS uses for it (S10).
    case quotaFull(seen: UploadErrorSeen)
    /// iCloud's servers can't be reached just now (`NSUbiquitousFileUbiquityServerNotAvailable`, 4355): the file is
    /// waiting, not refused.
    case serverUnavailable
    /// Any other error, by its domain and code (the top error's).
    case other(domain: String, code: Int)

    /// `NSUbiquitousFileNotUploadedDueToQuotaError` (`CocoaError.Code.ubiquitousFileNotUploadedDueToQuota`).
    public static let quotaCode = 4354
    /// `NSUbiquitousFileUbiquityServerNotAvailable` (`CocoaError.Code.ubiquitousFileUbiquityServerNotAvailable`).
    public static let serverUnavailableCode = 4355
    /// The domain the bench sheet names for the quota error. Apple's headers put the ubiquitous-file codes in
    /// `NSCocoaErrorDomain`; this literal is matched too, since Linux Foundation has no symbol for it.
    public static let ubiquitousFileErrorDomain = "NSUbiquitousFileErrorDomain"

    /// The problem an uploading error describes: quota full when the error, or the error under it, is 4354 in
    /// `NSCocoaErrorDomain` or `NSUbiquitousFileErrorDomain` (with both errors' domains and codes as seen); server
    /// unavailable likewise for 4355; otherwise the top error's domain and code.
    ///
    /// `unverified` (bench S10): that iOS 27 sets exactly this domain and code on a staged file in the app's own
    /// container when the quota is full. If it reports the quota some other way, the problem reads as `.other`, and
    /// the app says the files couldn't upload yet rather than why.
    public static func classify(domain: String, code: Int, underlying: (domain: String, code: Int)?) -> UploadProblem {
        func matches(_ domain: String, _ code: Int, _ wanted: Int) -> Bool {
            code == wanted && (domain == NSCocoaErrorDomain || domain == ubiquitousFileErrorDomain)
        }
        if matches(domain, code, quotaCode) || underlying.map({ matches($0.domain, $0.code, quotaCode) }) == true {
            return .quotaFull(seen: UploadErrorSeen(domain: domain, code: code, underlyingDomain: underlying?.domain,
                                                    underlyingCode: underlying?.code))
        }
        if matches(domain, code, serverUnavailableCode) { return .serverUnavailable }
        if let underlying, matches(underlying.domain, underlying.code, serverUnavailableCode) {
            return .serverUnavailable
        }
        return .other(domain: domain, code: code)
    }

    /// The problem `error` describes (`classify(domain:code:underlying:)` over it and its `NSUnderlyingErrorKey`).
    public static func classify(_ error: any Error) -> UploadProblem {
        let ns = error as NSError
        let underlying = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { (domain: $0.domain, code: $0.code) }
        return classify(domain: ns.domain, code: ns.code, underlying: underlying)
    }
}

/// Where one staged file in iCloud Drive is in its upload, as read from its metadata.
public enum StagedUploadState: Sendable, Hashable {
    case uploaded
    case uploading
    /// Not uploaded and not uploading yet, with no error.
    case waiting
    case failed(UploadProblem)
    /// The file isn't an iCloud item (iOS says it isn't ubiquitous).
    case notInICloud
    /// Its metadata couldn't be read (gone, or no reader on this platform).
    case unreadable
}

/// Reads a staged file's upload state from its metadata, never downloading, coordinating or opening it.
/// `UbiquitousUploadReader` on iOS; `NoStagedUploadReading` elsewhere, and fakes in tests.
public protocol StagedUploadReading: Sendable {
    func uploadState(of url: URL) -> StagedUploadState
}

/// Reads nothing: every file is `.unreadable`. For Linux, previews and tests.
public struct NoStagedUploadReading: StagedUploadReading {
    public init() {}
    public func uploadState(of url: URL) -> StagedUploadState { .unreadable }
}

#if os(iOS)
/// Reads a staged file's upload state from its URL resource values (`isUbiquitousItem`, `ubiquitousItemIsUploaded`,
/// `ubiquitousItemIsUploading`, `ubiquitousItemUploadingError`), through a fresh URL with no cached values, so each
/// read is current. Metadata only: it never downloads, coordinates or opens the file. A file iOS evicted and shows as
/// a ".NAME.icloud" placeholder (before iOS 17) is uploaded by definition. Compiled only by CI's Xcode job; checked on
/// the bench with the iCloud quota full (S10).
public struct UbiquitousUploadReader: StagedUploadReading {
    public init() {}

    public func uploadState(of url: URL) -> StagedUploadState {
        let path = url.path(percentEncoded: false)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent("." + url.lastPathComponent + ".icloud", isDirectory: false)
            return fm.fileExists(atPath: placeholder.path(percentEncoded: false)) ? .uploaded : .unreadable
        }
        var fresh = URL(fileURLWithPath: path, isDirectory: false)
        fresh.removeAllCachedResourceValues()
        let values: URLResourceValues
        do {
            values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                                        .ubiquitousItemIsUploadingKey,
                                                        .ubiquitousItemUploadingErrorKey])
        } catch {
            return .unreadable
        }
        guard values.isUbiquitousItem == true else { return .notInICloud }
        if let error = values.ubiquitousItemUploadingError { return .failed(UploadProblem.classify(error)) }
        if values.ubiquitousItemIsUploaded == true { return .uploaded }
        if values.ubiquitousItemIsUploading == true { return .uploading }
        return .waiting
    }
}
#endif
