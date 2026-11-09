import PTPKit

/// Every failure `IPLink` meets, mapped to a `CameraLinkFailure` and so to one of the engine's four outcomes (backlog
/// Iteration 3, section 1: every command has a time limit, and a timeout means "retry on reconnect", never a wait
/// forever). Pure, so it is tested on Linux. Details name codes and stages only, never an address, a serial or a
/// hardware ID.
enum IPFailureMapping {
    /// What the link was doing, for the detail and for the per-operation rules.
    enum Operation: String, Sendable, Hashable, CaseIterable {
        case open, list, info, thumbnail, download
    }

    /// A failure of the PTP/IP connection. Anything that ended the connection is `disconnected` (pause, carry on when
    /// the camera is back), except the camera refusing it, which no retry fixes until its settings change.
    static func failure(_ failure: PTPIPConnectionFailure, during operation: Operation) -> CameraLinkFailure {
        let detail = "\(operation.rawValue): PTP/IP \(failure)"
        switch failure {
        case .refused:
            return CameraLinkFailure(.refused, detail: detail)
        case .busy:
            // The link runs one transaction at a time, so this means a bug, but it is transient whatever the cause.
            return CameraLinkFailure(.busy, detail: detail)
        case .timedOut, .linkLost, .closed, .protocolViolation, .aborted, .sinkFailed, .cancelled,
             .cancelledBeforeStart, .notConnected, .alreadyUsed, .invalidCommand:
            return CameraLinkFailure(.disconnected, detail: detail)
        }
    }

    /// A non-OK response to one of the link's own operations.
    ///
    /// - Parameters:
    ///   - cardRemoved: StoreRemoved has come and StoreAdded hasn't since (or a check of the storages just found the
    ///     card gone), so InvalidObjectHandle means the card, not the file: `cardUnavailable`, never `itemNotFound`,
    ///     which would skip every file still queued (the spike's 82-files bug, 3 Nov).
    static func failure(_ code: PTPResponseCode, during operation: Operation, cardRemoved: Bool) -> CameraLinkFailure {
        let detail = "\(operation.rawValue): \(code)"
        return CameraLinkFailure(kind(for: code, during: operation, cardRemoved: cardRemoved), detail: detail)
    }

    static func kind(for code: PTPResponseCode, during operation: Operation, cardRemoved: Bool) -> CameraLinkFailure.Kind {
        switch code {
        case .storeNotAvailable:
            // Measured on 3 Nov after StoreRemoved, and for a plain session's GetStorageIDs: the card is not offered.
            return .cardUnavailable
        case .invalidObjectHandle:
            return cardRemoved ? .cardUnavailable : .itemNotFound
        case .deviceBusy:
            return .busy
        case .incompleteTransfer, .transactionCancelled:
            // The camera stopped the data phase short with the session still up: try the same call again.
            return .noAnswer
        case .sessionNotOpen:
            // The camera forgot the session (it restarted its responder under us): reopen.
            return .disconnected
        case .operationNotSupported:
            return operation == .thumbnail ? .unreadableItem : .modeListsNoFiles
        default:
            switch operation {
            case .open: return .refused
            case .list: return .modeListsNoFiles
            case .info, .thumbnail, .download: return .unreadableItem
            }
        }
    }

    /// The operation `IPLink` would send isn't in the camera's DeviceInfo (decision 6: send only what it lists). The
    /// α7C II lists every one the link uses over PTP/IP; another body might not.
    static func notListed(_ code: PTPOperationCode, during operation: Operation) -> CameraLinkFailure {
        let detail = "\(operation.rawValue): \(code) is not in the camera's DeviceInfo"
        return CameraLinkFailure(operation == .thumbnail ? .unreadableItem : .modeListsNoFiles, detail: detail)
    }

    /// How a whole-card session failed to open, from `SonySessionRunner`'s stop. A link failure keeps the
    /// connection's own failure (`connectionFailure`), so a refusal stays `.refused`.
    static func failure(_ stop: SonySessionRunner.Failure, connectionFailure: PTPIPConnectionFailure?) -> CameraLinkFailure {
        switch stop {
        case let .linkFailed(operation):
            if let connectionFailure {
                var mapped = failure(connectionFailure, during: .open)
                mapped.detail = "open: \(operation): PTP/IP \(connectionFailure)"
                return mapped
            }
            return CameraLinkFailure(.disconnected, detail: "open: \(operation): the link failed")
        case let .stepFailed(operation, code):
            // SDIO_OpenSession and its OpenSession fallback both refused, or GetDeviceInfo failed: the camera won't
            // give this initiator a session.
            let answer = code.map { "\($0)" } ?? "no usable answer"
            return CameraLinkFailure(.refused, detail: "open: \(operation): \(answer)")
        case let .unsupported(capabilities):
            // Not a Sony body, or no 0x9210/0x9212: the camera can't offer its card this way. The description leaves
            // out the serial.
            return CameraLinkFailure(.modeListsNoFiles, detail: "open: no whole-card session (\(capabilities))")
        case .outOfOrder:
            return CameraLinkFailure(.disconnected, detail: "open: the session plan went out of order")
        }
    }
}
