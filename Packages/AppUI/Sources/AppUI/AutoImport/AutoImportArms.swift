import CameraTransport
import Foundation

/// Auto-import's state for each connection (backlog section 14). Pure, so the once rule is tested on Linux.
///
/// - **USB:** a connection runs from discovery listing a camera it didn't list before (`connected(_:)`) to its going
///   (`disconnected(_:)`). Its arm starts `undecided`; the setting is read with the app in front (`decided(_:_:)`), which
///   leaves it `waiting` or ends it. Once Browse has shown the camera (`shown`), leaving Browse before the card is read
///   ends it (`leftBrowse`).
/// - **Wi-Fi:** a connection is one Browse visit: a live camera's ID entering the navigation path gets a `waiting` arm,
///   and its ID leaving the path removes it, so the next visit is a new one.
/// - **Both:** the first live listing with everything in place hands the files over (`ended(.started)`); anything that
///   ended stays ended until the connection ends, so a Reconnect, Try Again or a second Browse starts nothing.
struct AutoImportArms: Sendable, Hashable {
    enum Origin: Sendable, Hashable {
        case usbConnection
        case wiFiVisit
    }

    enum Ended: Sendable, Hashable {
        /// The files were handed over, whatever the engine answered.
        case started
        case off(AutoImportDecision)
        case jobRunning
        case keepersRunning
        case choosingFiles
        /// An "Import new photos" request took the listing.
        case requestTookIt
        /// Browse on the camera was left before the card was read.
        case leftBrowse
    }

    enum State: Sendable, Hashable {
        /// USB: connected; the setting not yet read with the app in front.
        case undecided
        /// The first live listing in front starts it.
        case waiting
        /// A listing is being decided (the catalogue read); another listing waits its turn.
        case deciding
        case ended(Ended)

        var isEnded: Bool {
            if case .ended = self { true } else { false }
        }
    }

    struct Arm: Sendable, Hashable {
        var origin: Origin
        var state: State
        /// The camera has been on the navigation path during this connection.
        var shown: Bool
    }

    private(set) var arms: [CameraDescriptor.ID: Arm] = [:]

    func state(of id: CameraDescriptor.ID) -> State? { arms[id]?.state }

    /// A camera discovery didn't list before: a USB one starts its connection, undecided. False for any other carrier
    /// (a Wi-Fi camera is listed whether or not it is in reach; its connection is a Browse visit).
    mutating func connected(_ camera: CameraDescriptor) -> Bool {
        guard camera.carrier == .usb else { return false }
        arms[camera.id] = Arm(origin: .usbConnection, state: .undecided, shown: false)
        return true
    }

    /// The camera went: its connection ends, whatever its state.
    mutating func disconnected(_ id: CameraDescriptor.ID) {
        arms[id] = nil
    }

    /// Wi-Fi: a live ID new on the path gets a waiting, shown arm; a Wi-Fi arm whose ID left the path is removed.
    /// USB: an armed ID on the path is marked shown; a shown arm not yet ended whose ID left the path ends `.leftBrowse`.
    /// Returns the IDs ended `.leftBrowse`.
    mutating func pathChanged(to path: [CameraDescriptor], isOffline: (CameraDescriptor.ID) -> Bool)
        -> [CameraDescriptor.ID] {
        let onPath = Set(path.map(\.id))
        var left: [CameraDescriptor.ID] = []
        for (id, arm) in arms {
            switch arm.origin {
            case .wiFiVisit:
                if !onPath.contains(id) { arms[id] = nil }
            case .usbConnection:
                if onPath.contains(id) {
                    arms[id]?.shown = true
                } else if arm.shown, !arm.state.isEnded {
                    arms[id]?.state = .ended(.leftBrowse)
                    left.append(id)
                }
            }
        }
        for camera in path where camera.carrier == .wifi && arms[camera.id] == nil && !isOffline(camera.id) {
            arms[camera.id] = Arm(origin: .wiFiVisit, state: .waiting, shown: true)
        }
        return left.sorted { $0.rawValue < $1.rawValue }
    }

    /// The setting was read for an undecided connection: `.on` waits for the first live listing; anything else ends it.
    mutating func decided(_ id: CameraDescriptor.ID, _ decision: AutoImportDecision) {
        guard arms[id]?.state == .undecided else { return }
        arms[id]?.state = decision == .on ? .waiting : .ended(.off(decision))
    }

    /// A listing starts being decided: true, and `deciding`, only from `undecided` or `waiting`.
    mutating func beginDeciding(_ id: CameraDescriptor.ID) -> Bool {
        switch arms[id]?.state {
        case .undecided?, .waiting?:
            arms[id]?.state = .deciding
            return true
        case .deciding?, .ended?, nil:
            return false
        }
    }

    /// The listing's decision is made: only from `deciding` (a Browse left meanwhile has already ended or removed it).
    mutating func finishDeciding(_ id: CameraDescriptor.ID, _ next: State) {
        guard arms[id]?.state == .deciding else { return }
        arms[id]?.state = next
    }

    /// Ends the arm for `why`, unless it has ended already.
    mutating func end(_ id: CameraDescriptor.ID, _ why: Ended) {
        guard let arm = arms[id], !arm.state.isEnded else { return }
        arms[id]?.state = .ended(why)
    }

    /// The connections whose setting hasn't been read with the app in front.
    var undecided: [CameraDescriptor.ID] {
        arms.filter { $0.value.state == .undecided }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    /// The connections waiting for their first live listing in front.
    var waiting: [CameraDescriptor.ID] {
        arms.filter { $0.value.state == .waiting }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }
}
