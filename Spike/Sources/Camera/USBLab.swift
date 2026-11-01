import Foundation
import Observation
import ImageCaptureCore

/// The Wired tab's session state, shared with the guided runner: which camera is selected, the CameraSession for
/// it, and how to open one. It was @State in WiredView; the Guided tab drives the same session.
@Observable
@MainActor
final class USBLab {
    private(set) var session: CameraSession?
    var selectedCameraID: ObjectIdentifier?
    /// Off: Open session returns when the session is open and the catalogue is logged in the background.
    var waitForCatalogue = true

    @ObservationIgnored let browser: DeviceBrowser
    @ObservationIgnored let log: SpikeLog
    @ObservationIgnored let lifecycle: LifecycleMonitor

    init(browser: DeviceBrowser, log: SpikeLog, lifecycle: LifecycleMonitor) {
        self.browser = browser
        self.log = log
        self.lifecycle = lifecycle
    }

    var selectedCamera: ICCameraDevice? {
        if let id = selectedCameraID, let camera = browser.cameras.first(where: { ObjectIdentifier($0) == id }) {
            return camera
        }
        // The selected camera has gone (cable pulled): the most recently added one is likely the replugged camera.
        return browser.cameras.last
    }

    var isBusy: Bool { session?.isBusy ?? false }
    var isOpen: Bool { session?.isOpen ?? false }
    /// The camera stopped answering on this session's connection: only Open session (a new session) is offered.
    var isStalled: Bool { session?.linkStalled ?? false }
    var canRun: Bool { isOpen && !isBusy && !isStalled }

    /// Reuses the session if it belongs to the selected camera, the camera is still attached and its connection hasn't
    /// stalled; otherwise starts a new one (after a cable pull the re-plugged camera is a new ICCameraDevice). Returns
    /// when the open has finished (and the catalogue, if `waitForCatalogue`).
    func openSession(waitForCatalogue override: Bool? = nil) async {
        guard let selected = selectedCamera else {
            log.warn("No camera: start browsing and plug the camera in (Day 1)")
            return
        }
        let wait = override ?? waitForCatalogue
        if let session, session.device === selected, !session.removed, !session.linkStalled {
            await session.openSession(waitForCatalogue: wait)
            return
        }
        // After a cable pull, if the browser still lists the dead device, prefer the camera added since (the
        // replugged camera is a new ICCameraDevice, added at the end). A stalled but still attached camera stays
        // selected, so it can be retried and the warning below shows.
        var camera = selected
        if let session, session.device === selected, session.removed,
           let other = browser.cameras.last(where: { $0 !== session.device }) {
            log.note("Open session: switching to the most recently added camera (\(other.name ?? "?")); the selected one was disconnected")
            selectedCameraID = ObjectIdentifier(other)
            camera = other
        }
        if let session {
            // Which case this was is the first thing to know when a replug doesn't recover the camera.
            let why = session.removed ? "the camera was disconnected"
                : session.device !== camera ? "a different camera (or the replugged one) is selected"
                : "the connection stalled and ImageCaptureCore hasn't reported a disconnect, so this is the same connection"
            log.note("Open session: starting a new session (\(why))")
            if session.linkStalled && session.device === camera && !session.removed {
                log.warn("The camera hasn't been unplugged since it stopped answering. If this open gets no answer, unplug it and plug it back in; if that doesn't help, turn the camera off and on.")
            }
        }
        session?.detach()
        let fresh = CameraSession(device: camera, log: log, lifecycle: lifecycle)
        session = fresh
        await fresh.openSession(waitForCatalogue: wait)
    }

    /// Runs `work` on the current session and returns when it has finished.
    func run(_ work: @MainActor (CameraSession) async -> Void) async {
        guard let session else {
            log.warn("Open a session first (Day 2)")
            return
        }
        await work(session)
    }
}
