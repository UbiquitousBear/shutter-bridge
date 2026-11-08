/// The cameras USB discovery has attached (backlog section 2, *Discover*). ImageCaptureCore can list the same camera
/// twice (the spike, after a stalled session: "if the camera is then listed twice, tap the lower row"), and both
/// devices carry the same UUID, which is the descriptor ID. So each ID stands for its most recently added device:
/// that is the one offered and the one `USBCameraBrowser.link(for:)` opens. An older device with the same ID stays
/// known but unoffered; if the newer one goes first, the older is offered again (`appeared`), and `disappeared` is
/// reported only when no device with that ID is left. The browser keys its links by device, so a removal reaches only
/// the link on the device that went. Pure, so it is unit-tested on Linux.
struct USBAttachedCameras: Sendable {
    private struct Entry: Sendable {
        var descriptor: CameraDescriptor
        let order: UInt64
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var current: [CameraDescriptor.ID: ObjectIdentifier] = [:]
    private var arrivals: UInt64 = 0

    /// One descriptor per camera: each ID's current device.
    var cameras: [CameraDescriptor] { current.values.compactMap { entries[$0]?.descriptor } }

    /// The device an ID stands for now: the most recently added one still attached.
    func device(for id: CameraDescriptor.ID) -> ObjectIdentifier? { current[id] }

    func descriptor(of device: ObjectIdentifier) -> CameraDescriptor? { entries[device]?.descriptor }

    /// A device arrived: it becomes the one its ID stands for, reported as `appeared` (an update if the ID was
    /// already offered for an older device).
    mutating func add(_ device: ObjectIdentifier, _ descriptor: CameraDescriptor) -> [USBDiscoveryEvent] {
        guard entries[device] == nil else { return [] }
        arrivals += 1
        entries[device] = Entry(descriptor: descriptor, order: arrivals)
        current[descriptor.id] = device
        return [.appeared(descriptor)]
    }

    /// A device went. Nothing to report if its ID stood for a newer device; otherwise the newest device left with
    /// that ID is offered again (`appeared`), or, with none left, the camera has gone (`disappeared`).
    mutating func remove(_ device: ObjectIdentifier) -> [USBDiscoveryEvent] {
        guard let gone = entries.removeValue(forKey: device) else { return [] }
        let id = gone.descriptor.id
        guard current[id] == device else { return [] }
        let left = entries.filter { $0.value.descriptor.id == id }.max { $0.value.order < $1.value.order }
        guard let next = left else {
            current[id] = nil
            return [.disappeared(id)]
        }
        current[id] = next.key
        return [.appeared(next.value.descriptor)]
    }

    /// ImageCaptureCore renamed a device: an `appeared` for it, as an update, if it is the one offered.
    mutating func rename(_ device: ObjectIdentifier, to name: String?) -> [USBDiscoveryEvent] {
        guard var entry = entries[device] else { return [] }
        entry.descriptor.name = name ?? entry.descriptor.name
        entries[device] = entry
        return current[entry.descriptor.id] == device ? [.appeared(entry.descriptor)] : []
    }

    /// Browsing stopped: every camera offered is reported gone.
    mutating func removeAll() -> [USBDiscoveryEvent] {
        let events = current.keys.map { USBDiscoveryEvent.disappeared($0) }
        entries.removeAll()
        current.removeAll()
        return events
    }
}
