import Foundation
import Observation
import ImageCaptureCore
import CryptoKit
import PTPKit

/// Days 2–5: everything we do with one ICCameraDevice over USB-C.
///
/// Every public method logs what it measured; nothing here is production code. Expect to adjust delegate
/// signatures against the iOS 27 SDK on day 1 — the ImageCaptureCore Swift overlay has shifted names before.
@Observable
@MainActor
final class CameraSession: NSObject {
    let device: ICCameraDevice
    let log: SpikeLog

    private(set) var isOpen = false
    private(set) var catalogComplete = false
    private(set) var files: [ICCameraFile] = []
    private(set) var deviceInfo: PTPDeviceInfo?
    private var tx = PTPTransactionCounter()
    private var readyContinuation: CheckedContinuation<Void, Never>?

    init(device: ICCameraDevice, log: SpikeLog) {
        self.device = device
        self.log = log
        super.init()
        device.delegate = self
        // Events arrive here as raw PTP event containers (day 4: press the shutter and watch for 0x4002).
        device.ptpEventHandler = { [weak self] data in
            Task { @MainActor in self?.handleEvent(data) }
        }
    }

    // MARK: Day 2 — session and catalogue

    func open() async {
        do {
            try await log.timed("usb.openSession") {
                try await device.requestOpenSession(options: nil)
            }
            isOpen = true
            log.note("Session open. Waiting for the complete content catalog…")
            await log.timed("usb.catalog.complete") {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    if catalogComplete { c.resume() } else { readyContinuation = c }
                }
            }
            refreshFiles()
        } catch {
            log.error("openSession failed: \(error)")
        }
    }

    func close() async {
        do {
            try await device.requestCloseSession(options: nil)
            isOpen = false
            log.note("Session closed")
        } catch {
            log.error("closeSession failed: \(error)")
        }
    }

    func refreshFiles() {
        let items = device.mediaFiles ?? []
        files = items.compactMap { $0 as? ICCameraFile }
        log.measure("usb.catalog.count", Double(files.count), "files")
        let byExt = Dictionary(grouping: files) { ($0.name as NSString?)?.pathExtension.uppercased() ?? "?" }
        for (ext, group) in byExt.sorted(by: { $0.key < $1.key }) {
            let bytes = group.reduce(0) { $0 + Int($1.fileSize) }
            log.note("  \(ext): \(group.count) files, \(bytes / 1_000_000) MB")
        }
        if let newest = files.max(by: { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }) {
            log.note("  newest: \(newest.name ?? "?") \(newest.creationDate.map { "\($0)" } ?? "no date") handle=\(String(format: "0x%08X", newest.ptpObjectHandle))")
        }
    }

    // MARK: Day 2 — thumbnails

    func timeThumbnails(count: Int = 50) async {
        let sample = Array(files.prefix(count))
        guard !sample.isEmpty else { log.warn("No files to thumbnail"); return }
        var total = 0.0
        var failures = 0
        for file in sample {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let data = try await thumbnailData(for: file)
                let elapsed = clock.now - start
                total += seconds(elapsed)
                if file === sample.first { log.note("first thumbnail: \(data.count) bytes, \(data.hexDump(limit: 8))") }
            } catch {
                failures += 1
            }
        }
        log.measure("usb.thumb.avg", total / Double(sample.count) * 1000, "ms", context: "\(sample.count) files, \(failures) failures")
    }

    private func thumbnailData(for file: ICCameraFile) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            file.requestThumbnailData(options: nil) { data, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
    }

    // MARK: Day 3 — downloads and throughput

    /// Downloads `files` one after another (or `parallel` at a time) into the temp directory and records MB/s.
    func download(_ selection: [ICCameraFile], parallel: Int = 1) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spike-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clock = ContinuousClock()
        let start = clock.now
        var bytes = 0
        await withTaskGroup(of: Int.self) { group in
            var iterator = selection.makeIterator()
            var inFlight = 0
            func enqueue() {
                guard let file = iterator.next() else { return }
                inFlight += 1
                group.addTask { @MainActor in
                    await self.downloadOne(file, to: dir)
                }
            }
            for _ in 0 ..< max(1, parallel) { enqueue() }
            for await done in group {
                bytes += done
                inFlight -= 1
                enqueue()
            }
        }
        let elapsed = seconds(clock.now - start)
        log.throughput("usb.download.throughput", bytes: bytes, seconds: elapsed, context: "\(selection.count) files, parallel=\(parallel)")
    }

    private func downloadOne(_ file: ICCameraFile, to dir: URL) async -> Int {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let name: String = try await withCheckedThrowingContinuation { c in
                let options: [ICDownloadOption: Any] = [
                    .downloadsDirectoryURL: dir,
                    .overwrite: true,
                ]
                _ = file.requestDownload(options: options) { filename, error in
                    if let error { c.resume(throwing: error) } else { c.resume(returning: filename ?? file.name ?? "?") }
                }
            }
            let elapsed = seconds(clock.now - start)
            let size = Int(file.fileSize)
            log.throughput("usb.download.file", bytes: size, seconds: elapsed, context: name)
            return size
        } catch {
            log.error("download \(file.name ?? "?") failed: \(error)")
            return 0
        }
    }

    // MARK: Day 4 — partial reads, two ways

    /// ImageCaptureCore's own byte-range read. If this works at full speed, we may not need PTP pass-through at all.
    func readPartialViaICC(_ file: ICCameraFile, chunk: Int = 4 * 1024 * 1024) async {
        let size = Int(file.fileSize)
        var offset = 0
        var hasher = SHA256()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            while offset < size {
                let length = min(chunk, size - offset)
                let data: Data = try await withCheckedThrowingContinuation { c in
                    file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                        if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
                    }
                }
                guard !data.isEmpty else { log.error("requestReadData returned no bytes at \(offset)"); break }
                hasher.update(data: data)
                offset += data.count
            }
            let elapsed = seconds(clock.now - start)
            log.throughput("usb.readData.throughput", bytes: offset, seconds: elapsed, context: file.name ?? "?")
            log.note("SHA-256 via requestReadData: \(hasher.finalize().compactMap { String(format: "%02x", $0) }.joined())")
        } catch {
            log.error("requestReadData failed at offset \(offset): \(error)")
        }
    }

    /// Raw PTP through requestSendPTPCommand. Day 4 question: are the two Data values (data phase, response
    /// container) in that order? Decode both and log; adjust `decodePassThrough` if the SDK disagrees.
    func send(_ command: PTPContainer) async throws -> (response: PTPContainer, data: Data) {
        let (a, b) = try await device.requestSendPTPCommand(command.encode(), outData: nil)
        return try decodePassThrough(first: a, second: b, for: command)
    }

    private func decodePassThrough(first: Data, second: Data, for command: PTPContainer) throws -> (PTPContainer, Data) {
        // Try the documented reading first: second = response container, first = data phase.
        if let (resp, _) = try? PTPContainer.decode(second), resp.type == .response {
            return (resp, first)
        }
        if let (resp, _) = try? PTPContainer.decode(first), resp.type == .response {
            log.warn("requestSendPTPCommand returned (response, data) — opposite of the assumed order. Note for the findings page.")
            return (resp, second)
        }
        // Some stacks return the data phase as a full data container; peel it.
        let all = (try? PTPContainer.decodeAll(first + second)) ?? []
        if let resp = all.first(where: { $0.type == .response }) {
            let payload = all.first(where: { $0.type == .data })?.payload ?? Data()
            return (resp, payload)
        }
        log.error("Could not find a response container. first=\(first.hexDump()) second=\(second.hexDump())")
        throw PTPDecodingError.unknownContainerType(0)
    }

    func fetchDeviceInfo() async {
        do {
            let (resp, data) = try await send(PTPCommand.getDeviceInfo(tx: tx.take()))
            log.note("GetDeviceInfo response: \(resp.responseCode) data=\(data.count) bytes")
            let info = try PTPDeviceInfo.decode(data)
            deviceInfo = info
            log.note("  \(info.manufacturer) \(info.model) fw=\(info.deviceVersion) serial=\(info.serialNumber) vendorExt=\(info.vendorExtension.map { "\($0)" } ?? String(info.vendorExtensionID))")
            log.note("  ops: \(info.operationsSupported.map { PTPOperationCode(rawValue: $0).description }.joined(separator: ", "))")
            log.note("  events: \(info.eventsSupported.map { PTPEventCode(rawValue: $0).description }.joined(separator: ", "))")
            log.note("  GetPartialObject=\(info.supports(.getPartialObject)) GetPartialObject64=\(info.supports(.getPartialObject64)) ObjectAdded=\(info.emits(.objectAdded))")
            saveFixture(data, name: "a7c2-deviceinfo.bin")
        } catch {
            log.error("GetDeviceInfo failed: \(error)")
        }
    }

    func fetchObjectInfo(_ file: ICCameraFile) async {
        do {
            let (resp, data) = try await send(PTPCommand.getObjectInfo(PTPObjectHandle(rawValue: file.ptpObjectHandle), tx: tx.take()))
            log.note("GetObjectInfo \(file.name ?? "?"): \(resp.responseCode), \(data.count) bytes")
            let info = try PTPObjectInfo.decode(data)
            log.note("  format=\(info.objectFormat) size=\(info.objectCompressedSize) \(info.imagePixWidth)x\(info.imagePixHeight) capture=\(info.captureDateRaw) thumb=\(info.thumbFormat) \(info.thumbCompressedSize)B")
            saveFixture(data, name: "a7c2-objectinfo-\(info.fileExtension.lowercased()).bin")
        } catch {
            log.error("GetObjectInfo failed: \(error)")
        }
    }

    /// Reassembles a whole file with GetPartialObject and checks it against requestReadData / the card copy.
    func readPartialViaPTP(_ file: ICCameraFile, chunk: UInt32 = 4 * 1024 * 1024) async {
        let size = UInt32(clamping: Int(file.fileSize))
        var offset: UInt32 = 0
        var hasher = SHA256()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            while offset < size {
                let length = min(chunk, size - offset)
                let (resp, data) = try await send(PTPCommand.getPartialObject(PTPObjectHandle(rawValue: file.ptpObjectHandle), offset: offset, length: length, tx: tx.take()))
                guard resp.responseCode.isOK else { log.error("GetPartialObject at \(offset): \(resp.responseCode)"); return }
                guard !data.isEmpty else { log.error("GetPartialObject returned no data at \(offset)"); return }
                hasher.update(data: data)
                offset += UInt32(data.count)
            }
            let elapsed = seconds(clock.now - start)
            log.throughput("usb.getPartialObject.throughput", bytes: Int(offset), seconds: elapsed, context: file.name ?? "?")
            log.note("SHA-256 via GetPartialObject: \(hasher.finalize().compactMap { String(format: "%02x", $0) }.joined())")
        } catch {
            log.error("GetPartialObject failed at \(offset): \(error)")
        }
    }

    // MARK: Events

    private func handleEvent(_ data: Data) {
        if let (event, _) = try? PTPContainer.decode(data) {
            log.note("PTP event: \(event.eventCode) params=\(event.parameters.map { String(format: "0x%08X", $0) })")
            if event.eventCode == .objectAdded { saveFixture(data, name: "a7c2-event-objectadded.bin") }
        } else {
            log.note("PTP event (raw): \(data.hexDump())")
        }
    }

    // MARK: Helpers

    private func saveFixture(_ data: Data, name: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            log.note("fixture saved: \(url.lastPathComponent) (\(data.count) bytes) — share it from the Log tab into Fixtures/a7c2/usb/")
        } catch {
            log.warn("could not save fixture \(name): \(error)")
        }
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

extension CameraSession: @preconcurrency ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        log.note("didOpenSession error=\(error.map { "\($0)" } ?? "nil")")
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        log.note("didCloseSession error=\(error.map { "\($0)" } ?? "nil")")
        isOpen = false
    }

    func didRemove(_ device: ICDevice) {
        log.warn("device removed mid-session (cable pulled?)")
        isOpen = false
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        catalogComplete = true
        readyContinuation?.resume()
        readyContinuation = nil
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        log.note("didAdd \(items.count) items (catalog \(Int(camera.contentCatalogPercentCompleted))%)")
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        log.note("didRemove \(items.count) items")
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        log.note("didRename \(items.count) items")
    }

    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: (any Error)?) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        log.note("capabilities changed: \(camera.capabilities.joined(separator: ", "))")
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        handleEvent(eventData)
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log.note("access restriction removed")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log.warn("access restriction enabled — unlock the camera / phone")
    }
}
