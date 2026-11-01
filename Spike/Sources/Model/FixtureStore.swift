import Foundation

/// Where captured camera bytes go on the phone, laid out exactly like the repo's `Fixtures/a7c2/` folder:
///
///     Documents/fixtures/a7c2/<usb|ptpip|ble>/<name>     e.g. usb/deviceinfo.bin, ptpip/objectinfo-arw.bin
///     Documents/fixtures/a7c2/<link>/FIRMWARE            "ILCE-7CM2 2.00" from GetDeviceInfo
///
/// Documents is visible in the Files app (UIFileSharingEnabled), and the Log tab shares the whole folder as a
/// zip, so the folder can be copied straight over `Fixtures/a7c2/` on the Mac; `make fixtures` then copies the
/// files the unit tests need into PTPKit.
///
/// Naming (keep in step with Fixtures/README.md and PTPKit's fixture tests): `deviceinfo.bin`,
/// `storageinfo.bin`, `storageids.bin`, `objecthandles.bin`, `objectinfo-<ext>.bin` (arw, jpg, hif, mp4),
/// `event-<name>.bin` (USB: one PTP event container; PTP/IP: one whole Event packet), `<what>.sha256` text,
/// `advert-<on|asleep|off>.json` for BLE.
///
/// Never write a Wi-Fi password, SSID passphrase or QR payload here.
@MainActor
enum FixtureStore {
    enum Link: String, CaseIterable, Sendable {
        case usb, ptpip, ble
    }

    static var root: URL {
        URL.documentsDirectory.appending(path: "fixtures/a7c2", directoryHint: .isDirectory)
    }

    static func folder(_ link: Link) -> URL {
        root.appending(path: link.rawValue, directoryHint: .isDirectory)
    }

    /// Saves `data` as `<link>/<name>`, replacing an earlier capture of the same name, and logs it.
    @discardableResult
    static func save(_ data: Data, link: Link, name: String, log: SpikeLog?) -> URL? {
        let dir = folder(link)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: name)
            try data.write(to: url, options: .atomic)
            log?.note("fixture saved: \(link.rawValue)/\(name) (\(data.count) bytes)")
            return url
        } catch {
            log?.warn("could not save fixture \(link.rawValue)/\(name): \(error)")
            return nil
        }
    }

    @discardableResult
    static func saveText(_ text: String, link: Link, name: String, log: SpikeLog?) -> URL? {
        save(Data(text.utf8), link: link, name: name, log: log)
    }

    /// Records the camera model and firmware the fixtures in `link` came from (Fixtures/README.md asks for it).
    static func recordFirmware(model: String, version: String, link: Link, log: SpikeLog?) {
        saveText("\(model) \(version)\n", link: link, name: "FIRMWARE", log: log)
    }

    /// Every captured file, relative to `root`, for the Log tab.
    static func inventory() -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = root.standardizedFileURL.path(percentEncoded: false)
        var out: [String] = []
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            out.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent)
        }
        return out.sorted()
    }

    /// Zips the fixtures folder for sharing, using the file coordinator's `.forUploading` option (the system's own
    /// zip, no third-party code). The zip lands in the temporary directory.
    static func zipArchive() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileNoSuchFile))
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinationError) { zipped in
            let dest = FileManager.default.temporaryDirectory.appending(path: "a7c2-fixtures-\(Int(Date().timeIntervalSince1970)).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipped, to: dest)
                result = .success(dest)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func clear(log: SpikeLog?) {
        try? FileManager.default.removeItem(at: root)
        log?.note("fixtures cleared")
    }
}
