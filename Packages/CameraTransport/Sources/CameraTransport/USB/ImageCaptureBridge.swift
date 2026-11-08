#if canImport(ImageCaptureCore) && os(iOS)
import CoreGraphics   // CGImage in cameraDevice(_:didReceiveThumbnail:for:error:)
import Foundation
import ImageCaptureCore

// The bridge between ImageCaptureCore's Objective-C delegates and the two actors that own its objects
// (`USBCameraBrowser` and `USBLink`). Compiled only for iOS (CI's Xcode 27 build); Linux and the macOS `swift test`
// skip it, since the macOS ImageCaptureCore differs and the app is iPhone only.
//
// Concurrency, in short: the delegates hold nothing but an `AsyncStream` continuation, so they are honestly
// `Sendable`; each callback turns what it was told into a `Sendable` signal and yields it, in order, to its actor,
// which consumes the stream on its own executor and owns every piece of state. The delegate methods are
// `nonisolated` because ImageCaptureCore calls them on its own schedule (on the main thread in the spike, but nothing
// promises it), so no actor-isolation check can trap if that changes.

/// An ImageCaptureCore object handed on without being used on the way. `@unchecked Sendable`, for two hops:
/// - **Browser delegate to `USBCameraBrowser`**: `deviceBrowser(_:didAdd:moreComing:)` may be called on any thread,
///   and yields the device in this box. That is safe only because the callback gives the object up as soon as it
///   yields it: it reads nothing from it and keeps no reference, so from then on only the browser's executor uses it.
///   Any change there must keep it that way (read nothing off the device in the callback; do it in the actor).
/// - **`USBCameraBrowser` to a `USBLink`**: both actors run on the main actor's executor (see
///   `USBLink.unownedExecutor`), so the device is only ever touched on that one serial executor, as the spike used it.
///
/// The box itself does nothing with the object.
struct ICObject<Object: AnyObject>: @unchecked Sendable {
    let object: Object
}

/// What a camera's device delegate reports to its `USBLink`.
enum USBDeviceSignal: Sendable {
    /// `didRemove(_:)`: the camera went away.
    case removed
    /// `device(_:didCloseSessionWithError:)`: the session ended (the link's own close, or under it).
    case sessionClosed
    /// `deviceDidBecomeReady(withCompleteContentCatalog:)`.
    case catalogueComplete
    /// `cameraDevice(_:didAdd:)`: how many items, for the week-1 check of whether MSC delivers files as they arrive.
    case itemsAdded(Int)
    /// `cameraDevice(_:didRemove:)`: which items left the card, by object identity.
    case itemsRemoved([ObjectIdentifier])
}

/// The device delegate one `USBLink` installs on its `ICCameraDevice`.
final class USBDeviceDelegate: NSObject, ICCameraDeviceDelegate, Sendable {
    private let signals: AsyncStream<USBDeviceSignal>.Continuation

    nonisolated init(_ signals: AsyncStream<USBDeviceSignal>.Continuation) {
        self.signals = signals
        super.init()
    }

    // ICDeviceDelegate
    nonisolated func didRemove(_ device: ICDevice) { signals.yield(.removed) }
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) { signals.yield(.sessionClosed) }
    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {}
    nonisolated func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {}

    // ICCameraDeviceDelegate
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        signals.yield(.catalogueComplete)
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        signals.yield(.itemsAdded(items.count))
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        signals.yield(.itemsRemoved(items.map { ObjectIdentifier($0) }))
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem,
                                  error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem, error: (any Error)?) {}
    /// No camera events reach the phone over USB in either mode (findings); the link ignores any that do.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// What the browser delegate reports to `USBCameraBrowser`.
enum USBBrowserSignal: Sendable {
    case added(ICObject<ICDevice>)
    case removed(ObjectIdentifier)
    case renamed(ObjectIdentifier)
    /// Will suspend, did suspend, cancelled suspending, resumed operations (backlog section 2, *Lifecycle*).
    case lifecycle(CameraLinkEvent)
}

/// The browser delegate `USBCameraBrowser` installs on its `ICDeviceBrowser`.
final class USBBrowserDelegate: NSObject, ICDeviceBrowserDelegate, Sendable {
    private let signals: AsyncStream<USBBrowserSignal>.Continuation

    nonisolated init(_ signals: AsyncStream<USBBrowserSignal>.Continuation) {
        self.signals = signals
        super.init()
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        signals.yield(.added(ICObject(object: device)))
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        signals.yield(.removed(ObjectIdentifier(device)))
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {
        signals.yield(.renamed(ObjectIdentifier(device)))
    }
    nonisolated func deviceBrowserWillSuspendOperations(_ browser: ICDeviceBrowser) {
        signals.yield(.lifecycle(.willSuspend))
    }
    nonisolated func deviceBrowserDidSuspendOperations(_ browser: ICDeviceBrowser) {
        signals.yield(.lifecycle(.didSuspend))
    }
    nonisolated func deviceBrowserDidCancelSuspendOperations(_ browser: ICDeviceBrowser) {
        signals.yield(.lifecycle(.cancelledSuspending))
    }
    nonisolated func deviceBrowserDidResumeOperations(_ browser: ICDeviceBrowser) {
        signals.yield(.lifecycle(.resumedOperations))
    }
}

/// How an ImageCaptureCore request ended, in `Sendable` form, before the link classifies it.
enum USBRequestOutcome: Sendable {
    case done
    case data(Data)
    /// `requestDownload`'s completion string: a file name inside the requested folder on the bench.
    case downloaded(String?)
    /// `outOfSpace`: the error or one underneath it (`NSUnderlyingErrorKey`) said the phone is full.
    case frameworkError(domain: String, code: Int, outOfSpace: Bool)
    case failed(CameraLinkFailure)

    /// Read inside the completion handler, so no non-`Sendable` error crosses into the actor. The underlying chain
    /// is read here too, as ImageCaptureCore may wrap a full disk in its own "download failed".
    static func error(_ error: any Error) -> USBRequestOutcome {
        let ns = error as NSError
        return .frameworkError(domain: ns.domain, code: ns.code, outOfSpace: USBFailureMapping.isOutOfSpace(error))
    }
}

extension USBContentsAccess {
    /// `ICAuthorizationStatus` is a string-backed struct on iOS, not an enum, so it is compared, not switched on
    /// (as the spike did).
    init(_ status: ICAuthorizationStatus) {
        if status == .authorized { self = .authorised }
        else if status == .denied { self = .denied }
        else if status == .restricted { self = .restricted }
        else { self = .notDetermined }
    }
}
#endif
