import Catalogue
import Foundation
import Testing
@testable import AppUI

/// A staged file for the cull tests. `at` is the capture time as `YYYYMMDDThhmmss`.
func cullFile(_ name: String, at date: String = "20261105T140000", size: UInt64 = 1_000, camera: String = "cam-a",
              folder: String = "100MSDCF") -> CullFile {
    CullFile(
        identity: ObjectIdentity(camera: CameraKey(rawValue: camera), folder: folder, filename: name,
                                 captureDate: CaptureDate(rawValue: date)!, size: size),
        url: URL(fileURLWithPath: "/staging/\(camera)/\(name)"))
}

/// Single JPG units `DSC00001.JPG`, `DSC00002.JPG`…, a second apart, as `CullUnit`s.
func cullUnits(_ count: Int, ext: String = "JPG") -> [CullUnit] {
    (0 ..< count).map { $0 + 1 }.map { n in
        let name = String(format: "DSC%05d.", n) + ext
        let time = String(format: "20261105T14%02d%02d", n / 60, n % 60)
        return CullUnit(.single(cullFile(name, at: time)))
    }
}

/// Collects what the session saves, in order, and can be slow or fail.
final class RecordingMarkWriter: CullMarkWriting, @unchecked Sendable {
    struct Write: Equatable {
        var mark: CullMark
        var keys: [ObjectIdentity.ContentKey]
    }

    struct Refused: Error {}

    private let lock = NSLock()
    private var recorded: [Write] = []
    private var delays: [Duration] = []
    private var failures = 0

    var writes: [Write] { lock.withLock { recorded } }
    /// The next write waits this long before it is recorded (first in, first used).
    func delayNext(_ duration: Duration) { lock.withLock { delays.append(duration) } }
    func failNext(_ count: Int = 1) { lock.withLock { failures += count } }

    func write(_ mark: CullMark, for keys: [ObjectIdentity.ContentKey]) async throws {
        let (delay, fail) = lock.withLock { () -> (Duration?, Bool) in
            let d = delays.isEmpty ? nil : delays.removeFirst()
            let f = failures > 0
            if f { failures -= 1 }
            return (d, f)
        }
        if let delay { try await Task.sleep(for: delay) }
        if fail { throw Refused() }
        lock.withLock { recorded.append(Write(mark: mark, keys: keys)) }
    }
}

/// A preview loader the test drives. Each load is named by its file's name; it waits for `release(_:)` unless
/// `autoRelease` is on, and can fail, or ignore cancellation.
final class FakeLoader: PreviewLoading, @unchecked Sendable {
    typealias Image = String

    enum Mode { case plain, standInThenFinal }

    private let lock = NSLock()
    private var startedNames: [String] = []
    private var cancelledNames: [String] = []
    private var deliveredNames: [String] = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var failing: Set<String> = []
    private var auto = false
    private var cost = 1_000
    private var ignoreCancel = false
    private var mode = Mode.plain
    private var full: PixelSize?
    private var detailCalls: [DetailCall] = []

    /// One `loadDetail` call.
    struct DetailCall: Equatable {
        var name: String
        var region: LoupeRegion
        var maxPixelSize: Int
    }

    var detailRequests: [DetailCall] { lock.withLock { detailCalls } }
    /// The original's size each final preview carries (`LoadedPreview.fullPixelSize`); nil, the default, for none.
    var fullPixelSize: PixelSize? {
        get { lock.withLock { full } }
        set { lock.withLock { full = newValue } }
    }

    var started: [String] { lock.withLock { startedNames } }
    var cancelled: [String] { lock.withLock { cancelledNames } }
    var delivered: [String] { lock.withLock { deliveredNames } }
    var autoRelease: Bool {
        get { lock.withLock { auto } }
        set { lock.withLock { auto = newValue } }
    }
    var byteCost: Int {
        get { lock.withLock { cost } }
        set { lock.withLock { cost = newValue } }
    }
    var ignoresCancellation: Bool {
        get { lock.withLock { ignoreCancel } }
        set { lock.withLock { ignoreCancel = newValue } }
    }
    var loadMode: Mode {
        get { lock.withLock { mode } }
        set { lock.withLock { mode = newValue } }
    }
    func fail(_ name: String) { lock.withLock { _ = failing.insert(name) } }
    func stopFailing(_ name: String) { lock.withLock { _ = failing.remove(name) } }

    func release(_ name: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released.insert(name)
            return waiting.removeValue(forKey: name)
        }
        continuation?.resume()
    }

    func load(_ source: PreviewSource, maxPixelSize: Int,
              deliver: @Sendable (LoadedPreview<String>) async -> Void) async throws {
        let name = source.file?.identity.filename ?? "none"
        let (cost, mode, full) = lock.withLock { () -> (Int, Mode, PixelSize?) in
            startedNames.append(name)
            return (self.cost, self.mode, self.full)
        }
        func loaded(_ quality: PreviewQuality) -> LoadedPreview<String> {
            LoadedPreview(image: name, pixelSize: PixelSize(width: 10, height: 10), quality: quality, byteCost: cost,
                          fullPixelSize: quality == .final ? full : nil)
        }
        if mode == .standInThenFinal { await deliver(loaded(.standIn)) }
        try await waitForRelease(name)
        if lock.withLock({ failing.contains(name) }) { throw PreviewLoadingFailure("scripted") }
        if !lock.withLock({ ignoreCancel }) { try Task.checkCancellation() }
        await deliver(loaded(.final))
        lock.withLock { deliveredNames.append(name) }
    }

    /// Answers at once with "<name>@detail", the region's pixels as the test sees them.
    func loadDetail(_ source: PreviewSource, region: LoupeRegion, maxPixelSize: Int) async throws -> LoadedPreview<String> {
        let name = source.file?.identity.filename ?? "none"
        lock.withLock { detailCalls.append(DetailCall(name: name, region: region, maxPixelSize: maxPixelSize)) }
        try Task.checkCancellation()
        return LoadedPreview(image: name + "@detail", pixelSize: PixelSize(width: 10, height: 10), quality: .final)
    }

    private func waitForRelease(_ name: String) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if auto || released.contains(name) || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting[name] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                cancelledNames.append(name)
                return waiting.removeValue(forKey: name)
            }
            continuation?.resume()
        }
    }
}

/// Which files are evicted, and downloads the test drives: each waits for `finish(_:)` unless `autoFinish` is on.
final class FakeAvailability: StagedFileAvailability, @unchecked Sendable {
    private let lock = NSLock()
    private var evicted: Set<String>
    private var startedNames: [String] = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<String> = []
    private var auto = false
    private var failing: Set<String> = []
    private var reported: Double?

    init(evicted: Set<String>) { self.evicted = evicted }

    var started: [String] { lock.withLock { startedNames } }
    var autoFinish: Bool {
        get { lock.withLock { auto } }
        set { lock.withLock { auto = newValue } }
    }
    func fail(_ name: String) { lock.withLock { _ = failing.insert(name) } }
    /// Every download tells its progress this fraction as it starts.
    func reportOnStart(_ fraction: Double) { lock.withLock { reported = fraction } }

    func isLocal(_ file: CullFile) -> Bool { lock.withLock { !evicted.contains(file.identity.filename) } }

    func finish(_ name: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            finished.insert(name)
            return waiting.removeValue(forKey: name)
        }
        continuation?.resume()
    }

    func download(_ file: CullFile, progress: @Sendable (Double?) -> Void) async throws {
        let name = file.identity.filename
        lock.withLock { startedNames.append(name) }
        if let fraction = lock.withLock({ reported }) { progress(fraction) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if auto || finished.contains(name) || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting[name] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            let continuation = lock.withLock { waiting.removeValue(forKey: name) }
            continuation?.resume()
        }
        try Task.checkCancellation()
        if lock.withLock({ failing.contains(name) }) { throw PreviewLoadingFailure("scripted") }
        lock.withLock { _ = evicted.remove(name) }
    }
}
