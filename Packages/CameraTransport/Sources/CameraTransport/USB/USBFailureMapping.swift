import Foundation

/// Every ImageCaptureCore failure, mapped to a `CameraLinkFailure` and so to one of the engine's four outcomes
/// (backlog section 2, *Errors*; decision 4). Pure, so it is unit-tested on Linux; `USBLink` passes in the error's
/// domain and code and whether the camera has gone.
///
/// The rules, in order:
/// 1. **The camera has gone** (`didRemove`, from the device or the browser): `disconnected`, so retry on reconnect,
///    whatever the code. A cable pull pauses the job without failing the file in flight (decision 4); the spike's
///    MSC pull failed the file in flight with -9934 *before* the removal arrived, and in MTP `didRemove` came 30 ms
///    after a failed read, so `classify` waits a moment (`removalGrace(for:)`) for a removal before it classifies a
///    failed call: every call but the link's own close.
/// 2. **The phone is full** (Cocoa's out-of-space or POSIX `ENOSPC`, on the error or anywhere in its chain of
///    underlying errors): `phoneStorageFull`, stop the job.
/// 3. **ImageCaptureCore's own codes**, by the table below.
/// 4. **Anything else**: per operation (`fallback`).
///
/// A stalled download is not a failure (decision 4): downloads have no timeout, because the same request survived a
/// 632 s suspension while the spike's 60 s limit failed three files. Only opening (60 s) and thumbnails (10 s) time
/// out, as `noAnswer`.
enum USBFailureMapping {
    /// What the link was doing. `storageInfo` is the card's free space through the PTP pass-through (I17,
    /// `CardFreeSpace`), whose failure leaves the free space unknown and fails nothing else.
    enum Operation: String, Sendable, Hashable, CaseIterable {
        case open, list, thumbnail, download, close, storageInfo
    }

    /// How long a failed download waits for a removal before it is classified (`unverified`). In MTP `didRemove`
    /// came 30 ms after a failed read; in the MSC pull the gap between the -9934 and `didRemove` wasn't logged (the
    /// file was requested 2.5 s before the removal arrived), so this is a guess to check on the bench in week 1.
    static let removalGrace: Duration = .seconds(3)

    /// The same for a failed open or thumbnail (`unverified`): shorter, so a real failure isn't held long, and still
    /// well above MTP's 30 ms gap. A thumbnail has already freed its slot when it waits.
    static let shortRemovalGrace: Duration = .seconds(1)

    /// How long a failed call waits for a removal before it is classified; nil for the link's own close, whose
    /// result doesn't matter.
    static func removalGrace(for operation: Operation) -> Duration? {
        switch operation {
        case .download: removalGrace
        case .open, .list, .thumbnail, .storageInfo: shortRemovalGrace
        case .close: nil
        }
    }

    /// A framework error, classified after giving a removal its grace (`removalGrace(for:)`): `isRemoved` is asked
    /// every 50 ms until it says yes, the grace runs out or the caller cancels.
    static func classify(
        domain: String, code: Int, outOfSpace: Bool = false, operation: Operation,
        isRemoved: @Sendable () async -> Bool
    ) async -> CameraLinkFailure {
        if let grace = removalGrace(for: operation), !(await isRemoved()) {
            let clock = ContinuousClock()
            let deadline = clock.now + grace
            while clock.now < deadline, !Task.isCancelled, !(await isRemoved()) {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return failure(domain: domain, code: code, operation: operation, deviceRemoved: await isRemoved(),
                       outOfSpace: outOfSpace)
    }

    /// Why a request is refused before it is sent, or nil if it may go: the camera has gone, or the link is closed
    /// (except for the close's own request). A thumbnail that waited for a slot while the link closed ends here as
    /// `disconnected` instead of reaching ImageCaptureCore on a closed session.
    static func refusal(_ operation: Operation, removed: Bool, closed: Bool) -> CameraLinkFailure? {
        if removed { return CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the camera has gone") }
        if closed && operation != .close {
            return CameraLinkFailure(.disconnected, detail: "\(operation.rawValue): the link is closed")
        }
        return nil
    }

    /// The longest an open waits for ImageCaptureCore (the spike's limit; opens took 0.00–0.04 s).
    static let openTimeout: Duration = .seconds(60)

    /// The longest a thumbnail waits (the spike's limit; they took 15–650 ms). A thumbnail that doesn't come is
    /// `noAnswer`, so retry now; it never blocks the two-in-flight queue for long.
    static let thumbnailTimeout: Duration = .seconds(10)

    /// ImageCaptureCore's codes (`ICReturnCode` and the connection codes in its headers). Only **-9934** has been
    /// seen (the MSC cable pull, 4 Nov); the other values are from the SDK headers as documented and are
    /// `unverified` against the iOS 27 SDK until they are compared on the Mac (week 1).
    enum Code {
        static let communicationTimedOut = -9923           // unverified
        static let failedToOpenSession = -9927             // unverified
        static let downloadFailed = -9934                  // seen: the file in flight at the MSC cable pull
        static let failedToCompletePassThrough = -9936     // unverified
        static let downloadCanceled = -9937                // unverified
        static let deviceIsPasscodeLocked = -9943          // unverified
        static let deviceIsBusyEnumerating = -9954         // unverified
        static let commandGeneralFailure = -9955           // unverified
        static let failedToCompleteTransfer = -9956        // unverified
        static let failedToSendData = -9957                // unverified
        static let sessionNotOpened = -9958                // unverified
        static let connectionClosedSessionSuddenly = -21351 // unverified
        static let connectionEjectedSuddenly = -21352       // unverified
    }

    static let cocoaOutOfSpace = 640   // NSFileWriteOutOfSpaceError
    static let posixNoSpace = 28       // ENOSPC

    /// A framework error, classified. `outOfSpace`: an error underneath it said the phone is full (`isOutOfSpace`).
    static func failure(
        domain: String, code: Int, operation: Operation, deviceRemoved: Bool, outOfSpace: Bool = false
    ) -> CameraLinkFailure {
        let detail = "\(operation.rawValue): \(shortDomain(domain)) \(code)"
        if deviceRemoved { return CameraLinkFailure(.disconnected, detail: detail) }
        if outOfSpace || isOutOfSpace(domain: domain, code: code) {
            return CameraLinkFailure(.phoneStorageFull, detail: outOfSpace ? detail + " (phone full)" : detail)
        }
        return CameraLinkFailure(kind(forCode: code, operation: operation) ?? fallback(operation), detail: detail)
    }

    static func isOutOfSpace(domain: String, code: Int) -> Bool {
        (domain == NSCocoaErrorDomain && code == cocoaOutOfSpace) || (domain == NSPOSIXErrorDomain && code == posixNoSpace)
    }

    /// True if the error, or any error in its `NSUnderlyingErrorKey` chain, says the phone is full. ImageCaptureCore
    /// reports a failed download in its own domain (-9934 is its "download failed"), so a full disk may only show
    /// underneath. `unverified`: a full phone has never been tried.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 8 {
            if isOutOfSpace(domain: ns.domain, code: ns.code) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// The kind ImageCaptureCore's code implies, or nil when the code isn't in the table.
    static func kind(forCode code: Int, operation: Operation) -> CameraLinkFailure.Kind? {
        switch code {
        case Code.communicationTimedOut, Code.failedToCompletePassThrough:
            return .noAnswer
        case Code.sessionNotOpened, Code.connectionClosedSessionSuddenly, Code.connectionEjectedSuddenly:
            // The session is gone under the call: the link has to be opened again, as after a replug.
            return .disconnected
        case Code.deviceIsPasscodeLocked:
            return .notAuthorised
        case Code.downloadFailed, Code.downloadCanceled, Code.failedToOpenSession, Code.deviceIsBusyEnumerating,
             Code.commandGeneralFailure, Code.failedToCompleteTransfer, Code.failedToSendData:
            // With the camera still attached, a failed download is retried; the engine caps the retries and only
            // then fails the file (decision 4). A cancel is the engine's own (it ignores the result) or a session
            // ending, which the removal rule above catches first.
            return .busy
        default:
            return nil
        }
    }

    /// For a code the table doesn't know: a missing thumbnail leaves a placeholder (skip it), anything else is
    /// retried and the engine's retry cap decides.
    static func fallback(_ operation: Operation) -> CameraLinkFailure.Kind {
        switch operation {
        case .thumbnail: .unreadableItem
        case .open, .list, .download, .close, .storageInfo: .busy
        }
    }

    /// A call that got no answer in its time limit.
    static func timedOut(_ operation: Operation, after limit: Duration) -> CameraLinkFailure {
        CameraLinkFailure(.noAnswer, detail: "\(operation.rawValue): no answer in \(limit.components.seconds) s")
    }

    /// A call the caller cancelled. There is no kind for it: it comes back as `busy` with the detail "cancelled",
    /// and the engine, which cancelled it, ignores the result.
    static func cancelled(_ operation: Operation) -> CameraLinkFailure {
        CameraLinkFailure(.busy, detail: "\(operation.rawValue): cancelled")
    }

    /// For the log: "ImageCaptureCore" rather than a reverse-DNS domain, so details read like the findings.
    static func shortDomain(_ domain: String) -> String {
        domain.localizedCaseInsensitiveContains("imagecapture") ? "ImageCaptureCore" : domain
    }
}
