import Foundation
import Observation
import ImageCaptureCore

/// Day 1: does ImageCaptureCore see the α7C II at all, and in which USB mode?
///
/// ImageCaptureCore delivers delegate callbacks on the main thread; the class is main-actor isolated and
/// the conformance is marked @preconcurrency so the isolated methods can satisfy the Objective-C protocol.
/// Device and OS context (iOS build, phone model) is logged by the Log tab, not here.
@Observable
@MainActor
final class DeviceBrowser: NSObject {
    /// What `browsedDeviceTypeMask` is set to before `start()` (iOS 15.2+). The documentation (written for macOS)
    /// says to OR a device-type mask with a location mask; on iOS only local (USB) devices exist. If no camera
    /// appears with the default, stop browsing, pick another choice and start again: the log records which works.
    enum MaskChoice: String, CaseIterable, Identifiable {
        case cameraLocal = "Cameras, local"
        case camera = "Cameras"
        case systemDefault = "System default"
        var id: String { rawValue }
    }

    private let browser = ICDeviceBrowser()
    private(set) var cameras: [ICCameraDevice] = []
    private(set) var authorization: String = "not requested"
    private(set) var isBrowsing = false
    private(set) var maskDescription = "not set"
    var maskChoice: MaskChoice = .cameraLocal
    var log: SpikeLog?
    @ObservationIgnored private var loggedSerialNote = false

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() async {
        guard !isBrowsing else { log?.note("ICDeviceBrowser is already browsing"); return }
        // iOS 14+: contents access is what we need to list and download files; control access covers PTP
        // pass-through and tethering. Both are requested so day 4 is not blocked by a missing prompt.
        let contents: ICAuthorizationStatus = await withCheckedContinuation { (c: CheckedContinuation<ICAuthorizationStatus, Never>) in
            browser.requestContentsAuthorization { status in c.resume(returning: status) }
        }
        let control: ICAuthorizationStatus = await withCheckedContinuation { (c: CheckedContinuation<ICAuthorizationStatus, Never>) in
            browser.requestControlAuthorization { status in c.resume(returning: status) }
        }
        authorization = "contents=\(describe(contents)) control=\(describe(control))"
        log?.note("ImageCaptureCore authorization: \(authorization)")
        if contents == .notDetermined {
            log?.warn("requestContentsAuthorization returned notDetermined without a prompt (the iOS 26.1 beta regression). Note the iOS build in the findings.")
        }
        if contents == .denied || contents == .restricted {
            log?.error("Contents access is \(describe(contents)): allow it in Settings → Privacy & Security → Camera for SB Spike, then start again.")
        }
        applyMask()
        browser.start()
        isBrowsing = browser.isBrowsing
        log?.note("ICDeviceBrowser started (isBrowsing=\(browser.isBrowsing), isSuspended=\(browser.isSuspended)). Plug the camera in now.")
    }

    func stop() {
        browser.stop()
        isBrowsing = browser.isBrowsing
        cameras.removeAll()
        log?.note("ICDeviceBrowser stopped")
    }

    private func applyMask() {
        let before = browser.browsedDeviceTypeMask.rawValue
        switch maskChoice {
        case .cameraLocal:
            let raw = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
            if let mask = ICDeviceTypeMask(rawValue: raw) {
                browser.browsedDeviceTypeMask = mask
            } else {
                browser.browsedDeviceTypeMask = .camera
            }
        case .camera:
            browser.browsedDeviceTypeMask = .camera
        case .systemDefault:
            break
        }
        let after = browser.browsedDeviceTypeMask.rawValue
        maskDescription = "0x" + String(after, radix: 16)
        log?.note("browsedDeviceTypeMask: 0x\(String(before, radix: 16)) before → 0x\(String(after, radix: 16)) (\(maskChoice.rawValue))")
    }

    private func describe(_ s: ICAuthorizationStatus) -> String {
        // ICAuthorizationStatus is a string-backed struct on iOS, not an enum, so compare rather than switch.
        if s == .authorized { return "authorized" }
        if s == .denied { return "denied" }
        if s == .restricted { return "restricted" }
        if s == .notDetermined { return "notDetermined" }
        return s.rawValue
    }

    private func hex4(_ v: Int32) -> String { String(format: "%04X", v) }
}

extension DeviceBrowser: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let caps = device.capabilities
        let acceptsPTP = caps.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        log?.note("didAdd: \(device.name ?? "?") kind=\(device.productKind ?? "?") transport=\(device.transportType ?? "?") type=0x\(String(device.type.rawValue, radix: 16)) usb=\(hex4(device.usbVendorID)):\(hex4(device.usbProductID)) uuid=\(device.uuidString ?? "-") moreComing=\(moreComing)")
        log?.note("  capabilities (\(caps.count)): \(caps.isEmpty ? "none reported yet" : caps.joined(separator: ", "))")
        log?.note("  acceptsPTPCommands=\(acceptsPTP ? "yes" : "no") (cameraDeviceCanAcceptPTPCommands; day 4 needs yes)")
        if !loggedSerialNote {
            loggedSerialNote = true
            log?.note("  serial: ICDevice.serialNumberString is macOS-only; the Wired tab reads the camera serial from GetDeviceInfo")
        }
        if let camera = device as? ICCameraDevice {
            if !cameras.contains(where: { $0 === camera }) { cameras.append(camera) }
        } else {
            log?.note("  (not an ICCameraDevice; ignored)")
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        log?.note("browser didRemove: \(device.name ?? "?") uuid=\(device.uuidString ?? "-")")
        cameras.removeAll { $0 === device }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {
        log?.note("deviceDidChangeName: \(device.name ?? "?")")
    }

    // Day 5: ImageCaptureCore suspends the browser when the app leaves the foreground (iOS 14+). The timing of
    // these against the Lifecycle lines in the log is what the findings page needs.
    func deviceBrowserWillSuspendOperations(_ browser: ICDeviceBrowser) {
        log?.note("ICDeviceBrowser will suspend operations")
    }

    func deviceBrowserDidSuspendOperations(_ browser: ICDeviceBrowser) {
        log?.note("ICDeviceBrowser did suspend operations")
    }

    func deviceBrowserDidCancelSuspendOperations(_ browser: ICDeviceBrowser) {
        log?.note("ICDeviceBrowser cancelled suspending operations")
    }

    func deviceBrowserDidResumeOperations(_ browser: ICDeviceBrowser) {
        log?.note("ICDeviceBrowser resumed operations")
    }
}
