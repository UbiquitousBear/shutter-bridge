import CameraTransport
import Foundation

/// Width and height in pixels.
public struct PixelSize: Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
    public var description: String { "\(width)x\(height)" }
}

/// Copy or share.
public enum JPEGPurpose: String, Sendable, Hashable, CaseIterable {
    case copy
    case share
}

/// What a `JPEGMaking` did, for the UI (the fallback message) and the bench log.
public struct JPEGMakingReport: Sendable, Hashable {
    /// True when the RAW couldn't be decoded and the largest preview embedded in the file was used instead.
    public var usedEmbeddedPreview: Bool
    public var outputPixelSize: PixelSize
    /// From opening the input to the JPEG being written.
    public var seconds: Double
    /// The largest image embedded in a RAW (its preview), on every RAW: the one used when the fallback ran, and
    /// for the bench check otherwise. Nil for a HEIF, or when the RAW embeds none.
    public var largestPreviewPixelSize: PixelSize?
    /// Short facts for the log only, such as "CIRAWFilter(imageURL:) returned nil". Never file contents.
    public var notes: [String]

    public init(usedEmbeddedPreview: Bool, outputPixelSize: PixelSize, seconds: Double,
                largestPreviewPixelSize: PixelSize? = nil, notes: [String] = []) {
        self.usedEmbeddedPreview = usedEmbeddedPreview
        self.outputPixelSize = outputPixelSize
        self.seconds = seconds
        self.largestPreviewPixelSize = largestPreviewPixelSize
        self.notes = notes
    }
}

/// Why a JPEG couldn't be made. The detail is for the log.
public struct JPEGMakingFailure: Error, Sendable, Hashable {
    public var detail: String
    public init(_ detail: String) { self.detail = detail }
}

/// Turns a fetched RAW or HEIF into a JPEG on disk. The real one is `CoreImageJPEGMaker` (Core Image and ImageIO,
/// behind `#if canImport`); tests use a fake.
public protocol JPEGMaking: Sendable {
    /// Writes a JPEG of `input` at `output`. `conversion` is `.renderRAW` or `.reencodeHEIF`. Runs off the main actor.
    func makeJPEG(from input: URL, conversion: JPEGConversion, to output: URL) async throws(JPEGMakingFailure)
        -> JPEGMakingReport

    /// The pixel size of an image file, for the log of a JPG used as it is; nil if it can't be read.
    func pixelSize(ofImageAt url: URL) -> PixelSize?
}

/// Puts a JPEG on the clipboard. The real one writes `public.jpeg` data to `UIPasteboard.general`.
@MainActor
public protocol JPEGClipboard {
    func copyJPEG(at url: URL) throws
}

/// How serious a bench line is. Almost every line is a `notice`; a real failure is an `error`, so the unified log's
/// error filter, and the count of error-level entries that the bench sheet's definition of done reads, show failures and
/// nothing else (backlog section 6; I8). Pauses, stalls that recover and skips stay at `notice`.
public enum BenchLogLevel: Sendable, Hashable {
    case notice
    case error
}

/// Where the bench lines go: OSLog in the app (`OSLogBenchLog`), the rolling file (`RollingLogFile`), an array in tests.
/// Lines never hold file contents.
///
/// `note(_:)` is a notice. `note(_:level:)` says how serious the line is; a log that can't tell levels apart keeps its
/// one level through the default, which forwards to `note(_:)`, so a log written before levels existed still works.
public protocol BenchLog: Sendable {
    func note(_ line: String)
    func note(_ line: String, level: BenchLogLevel)
}

extension BenchLog {
    public func note(_ line: String, level: BenchLogLevel) { note(line) }
}

/// Sends every line to each of its logs, at the level it came with: the unified log and the rolling file in the app.
public struct TeeBenchLog: BenchLog {
    private let logs: [any BenchLog]

    public init(_ logs: [any BenchLog]) {
        self.logs = logs
    }

    public func note(_ line: String) {
        for log in logs { log.note(line) }
    }

    public func note(_ line: String, level: BenchLogLevel) {
        for log in logs { log.note(line, level: level) }
    }
}

/// A log that drops everything.
public struct SilentBenchLog: BenchLog {
    public init() {}
    public func note(_ line: String) {}
    public func note(_ line: String, level: BenchLogLevel) {}
}

/// Why a *Copy as JPEG* or *Share as JPEG…* didn't finish.
public enum JPEGActionFailure: Error, Sendable, Hashable {
    /// The person cancelled, or left Browse.
    case cancelled
    /// The link failed to fetch the file.
    case link(CameraLinkFailure)
    /// The RAW or HEIF couldn't be made into a JPEG.
    case conversion(detail: String)
    /// The temporary folder couldn't be made or written.
    case storage(detail: String)
    /// The clipboard refused the JPEG.
    case clipboard(detail: String)
    /// The share sheet couldn't be shown.
    case shareUnavailable
}

/// A finished JPEG, still in its action folder.
public struct JPEGOutput: Sendable, Hashable {
    public var url: URL
    public var path: JPEGPath
    public var record: JPEGBenchRecord

    /// True when the camera's embedded preview stands in for a render; the UI says so.
    public var isEmbeddedPreview: Bool { path == .previewFallback }
}

/// Where an action is, for its progress line.
public enum JPEGStage: Sendable, Hashable {
    case fetching(written: UInt64, total: UInt64)
    case converting(JPEGConversion)
}

/// Fetch, then convert (or not): one action's work, without the clipboard or share sheet. Pure apart from the file
/// system, so it runs on Linux against a fake link and a fake maker.
public struct JPEGPipeline: Sendable {
    public let link: any CameraLink
    public let maker: any JPEGMaking

    public init(link: any CameraLink, maker: any JPEGMaking) {
        self.link = link
        self.maker = maker
    }

    /// Fetches `source.fetched` into `folder.download` through the link (to disk, never into memory), then leaves
    /// the JPEG at `folder.outputFile(forPressedName:)`. The caller removes the folder whatever the outcome (after
    /// the share sheet closes, for a share).
    public func run(
        _ source: JPEGSource,
        purpose: JPEGPurpose,
        in folder: JPEGScratch.ActionFolder,
        progress: @escaping @Sendable (JPEGStage) -> Void
    ) async -> Result<JPEGOutput, JPEGActionFailure> {
        let total = source.fetched.size
        progress(.fetching(written: 0, total: total))
        let fetchStart = ContinuousClock.now
        let downloaded: URL
        do throws(CameraLinkFailure) {
            downloaded = try await link.bytes(of: source.fetched.id, into: folder.download) { written in
                progress(.fetching(written: written, total: total))
            }
        } catch {
            // The link reports a cancel as `busy` with the detail "cancelled"; the task says which it was.
            return .failure(Task.isCancelled ? .cancelled : .link(error))
        }
        if Task.isCancelled { return .failure(.cancelled) }
        let fetchSeconds = Self.seconds(ContinuousClock.now - fetchStart)
        let fetchedBytes = Self.fileSize(downloaded) ?? total

        let output = folder.outputFile(forPressedName: source.pressed.name)
        var record = JPEGBenchRecord(
            path: JPEGPath(source.kind, usedEmbeddedPreview: false), purpose: purpose,
            pressedName: source.pressed.name, fetchedName: source.fetched.name,
            fetchedBytes: fetchedBytes, fetchSeconds: fetchSeconds
        )
        switch source.conversion {
        case .asIs:
            do {
                try FileManager.default.moveItem(at: downloaded, to: output)
            } catch {
                return .failure(.storage(detail: "move: \(type(of: error))"))
            }
            record.outputPixelSize = maker.pixelSize(ofImageAt: output)
        case .renderRAW, .reencodeHEIF:
            progress(.converting(source.conversion))
            let report: JPEGMakingReport
            do throws(JPEGMakingFailure) {
                report = try await maker.makeJPEG(from: downloaded, conversion: source.conversion, to: output)
            } catch {
                return .failure(Task.isCancelled ? .cancelled : .conversion(detail: error.detail))
            }
            if Task.isCancelled { return .failure(.cancelled) }
            try? FileManager.default.removeItem(at: downloaded)   // the camera's file isn't needed any more
            record.path = JPEGPath(source.kind, usedEmbeddedPreview: report.usedEmbeddedPreview)
            record.renderSeconds = report.seconds
            record.outputPixelSize = report.outputPixelSize
            record.largestPreviewPixelSize = report.largestPreviewPixelSize
            record.notes = report.notes
        }
        record.outputBytes = Self.fileSize(output)
        return .success(JPEGOutput(url: output, path: record.path, record: record))
    }

    static func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// What the week-1 bench check reads from the log (backlog section 6): the path taken, the fetch and render times,
/// the output's pixel size and, on every RAW, the largest embedded preview's. File names, sizes and times
/// only; never file contents.
public struct JPEGBenchRecord: Sendable, Hashable {
    public var path: JPEGPath
    public var purpose: JPEGPurpose
    public var pressedName: String
    public var fetchedName: String
    public var fetchedBytes: UInt64
    public var fetchSeconds: Double
    public var renderSeconds: Double?
    public var outputPixelSize: PixelSize?
    public var largestPreviewPixelSize: PixelSize?
    public var outputBytes: UInt64?
    public var notes: [String] = []

    public init(path: JPEGPath, purpose: JPEGPurpose, pressedName: String, fetchedName: String,
                fetchedBytes: UInt64, fetchSeconds: Double) {
        self.path = path
        self.purpose = purpose
        self.pressedName = pressedName
        self.fetchedName = fetchedName
        self.fetchedBytes = fetchedBytes
        self.fetchSeconds = fetchSeconds
    }

    /// One line for Console: `copy-as-jpeg path=raw-render purpose=copy pressed=DSC00001.ARW …`.
    public var logLine: String {
        var parts = [
            "copy-as-jpeg", "path=\(path.rawValue)", "purpose=\(purpose.rawValue)",
            "pressed=\(pressedName)", "fetched=\(fetchedName)",
            "fetched-bytes=\(fetchedBytes)", "fetch-s=\(Self.format(fetchSeconds))",
        ]
        if let renderSeconds { parts.append("render-s=\(Self.format(renderSeconds))") }
        if let outputPixelSize { parts.append("output-px=\(outputPixelSize)") }
        if let outputBytes { parts.append("output-bytes=\(outputBytes)") }
        if let largestPreviewPixelSize { parts.append("largest-preview-px=\(largestPreviewPixelSize)") }
        for note in notes { parts.append("note=\"\(note)\"") }
        return parts.joined(separator: " ")
    }

    static func format(_ seconds: Double) -> String {
        let hundredths = (seconds * 100).rounded()
        guard hundredths.isFinite else { return "?" }
        let whole = Int(hundredths) / 100
        let fraction = abs(Int(hundredths) % 100)
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}
