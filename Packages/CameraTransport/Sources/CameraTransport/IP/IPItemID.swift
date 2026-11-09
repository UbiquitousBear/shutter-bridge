import PTPKit

/// How `IPLink` names a file: its PTP object handle, as "h-" and the handle in lower-case hex ("h-400010a3"), the same
/// spelling `SimulatedCameraLink` uses for a Wi-Fi item. Handles were stable across sessions on the bench (DSC02046.ARW
/// kept 0x400010A3 in every session on 2 Nov; backlog Iteration 3, section 2), which is why the link reports
/// `itemIDsSurviveReopen`. The ID is still a hint: the engine checks name and size before it resumes or skips a file
/// found by it (wireless plan, decision 6).
///
/// Holds nothing private: a handle is a slot on the card, not the camera's serial or hardware ID.
enum IPItemID {
    static let prefix = "h-"

    /// The ID for a handle.
    static func id(for handle: PTPObjectHandle) -> CameraItem.ID {
        CameraItem.ID(rawValue: prefix + String(handle.rawValue, radix: 16))
    }

    /// The handle an ID names, or nil for an ID this link didn't make (another link's, or garbage): one to eight hex
    /// digits after the prefix, nothing else.
    static func handle(of id: CameraItem.ID) -> PTPObjectHandle? {
        let raw = id.rawValue
        guard raw.hasPrefix(prefix) else { return nil }
        let digits = raw.dropFirst(prefix.count)
        guard (1 ... 8).contains(digits.count), digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        return PTPObjectHandle(rawValue: value)
    }
}
