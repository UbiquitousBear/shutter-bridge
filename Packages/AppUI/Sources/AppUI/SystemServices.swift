#if canImport(UIKit) && canImport(OSLog) && canImport(UniformTypeIdentifiers) && canImport(CoreImage) && canImport(ImageIO)
import Foundation
import OSLog
import UIKit
import UniformTypeIdentifiers

/// Puts the JPEG on the general pasteboard as `public.jpeg` data, so Messages, Notes, Mail and the rest paste a
/// photo, not a file.
public struct SystemJPEGClipboard: JPEGClipboard {
    public init() {}

    public func copyJPEG(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        UIPasteboard.general.setData(data, forPasteboardType: UTType.jpeg.identifier)
    }
}

/// The bench lines in the unified log, so Shamil can read them in Console or from a sysdiagnose: subsystem the app's
/// bundle identifier, category "browse". Logged at the default (notice) level, which is kept on disk, or at the error
/// level for a real failure (`BenchLogLevel`), and public: the lines hold file names, sizes and times only, never file
/// contents or a camera's identifiers.
public struct OSLogBenchLog: BenchLog {
    public static let category = "browse"
    private let logger: Logger

    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "net.shamil.shutter-bridge") {
        logger = Logger(subsystem: subsystem, category: Self.category)
    }

    public func note(_ line: String) {
        note(line, level: .notice)
    }

    public func note(_ line: String, level: BenchLogLevel) {
        switch level {
        case .notice: logger.notice("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
    }
}

extension BrowseServices {
    /// What the app uses: Core Image and ImageIO, the general pasteboard, the caches folder and `log` (OSLog by default;
    /// the app passes OSLog and the rolling file together).
    public static func system(log: any BenchLog = OSLogBenchLog()) -> BrowseServices {
        BrowseServices(maker: CoreImageJPEGMaker(), clipboard: SystemJPEGClipboard(), scratch: .inCaches(), log: log)
    }
}
#endif
