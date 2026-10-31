import Foundation
import Observation
import ImageCaptureCore

/// Day 1: does ImageCaptureCore see the α7C II at all, and in which USB mode?
///
/// ImageCaptureCore delivers delegate callbacks on the main thread; the class is main-actor isolated and
/// the conformance is marked @preconcurrency so the isolated methods can satisfy the Objective-C protocol.
@Observable
@MainActor
final class DeviceBrowser: NSObject {
    private let browser = ICDeviceBrowser()
    private(set) var cameras: [ICCameraDevice] = []
    private(set) var authorization: String = "not requested"
    private(set) var isBrowsing = false
    var log: SpikeLog?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() async {
        // iOS 14+: contents access is what we need to list and download files; control access is for tethering.
        let contents = await browser.requestContentsAuthorization()
        let control = await browser.requestControlAuthorization()
        authorization = "contents=\(describe(contents)) control=\(describe(control))"
        log?.note("ImageCaptureCore authorization: \(authorization)")
        if contents == .notDetermined {
            log?.warn("requestContentsAuthorization returned notDetermined without a prompt — the iOS 26.1 beta regression. Record the iOS 27 build number.")
        }
        browser.start()
        isBrowsing = browser.isBrowsing
        log?.note("ICDeviceBrowser started (browsing=\(browser.isBrowsing)). Plug the camera in now.")
    }

    func stop() {
        browser.stop()
        isBrowsing = false
        cameras.removeAll()
    }

    private func describe(_ s: ICAuthorizationStatus) -> String {
        switch s {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown(\(s.rawValue))"
        }
    }

    private func describeCapabilities(_ device: ICDevice) -> String {
        device.capabilities.joined(separator: ", ")
    }
}

extension DeviceBrowser: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        log?.note("didAdd: \(device.name ?? "?") transport=\(device.transportType ?? "?") type=\(device.type.rawValue) caps=[\(describeCapabilities(device))] serial=\(device.serialNumberString ?? "-") uuid=\(device.uuidString ?? "-")")
        if let camera = device as? ICCameraDevice {
            cameras.append(camera)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        log?.note("didRemove: \(device.name ?? "?")")
        cameras.removeAll { $0 === device }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {
        log?.note("deviceDidChangeName: \(device.name ?? "?")")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, requestsSelect device: ICDevice?) {
        log?.note("requestsSelect: \(device?.name ?? "nil")")
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        log?.note("deviceBrowserDidEnumerateLocalDevices")
    }
}
