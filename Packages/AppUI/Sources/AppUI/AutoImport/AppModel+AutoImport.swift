import CameraTransport
import Catalogue
import Foundation

// Auto-import on connect (Iteration 4, backlog section 14; Shamil, 19 Nov). Plain Swift, tested on Linux.
//
// - The setting is per camera body, off by default: `CameraRecord.autoImport` on its one-body keys, read by its D11 name
//   (`AutoImportRule`), switched in Settings › *Import When Connected* (`AutoImportSettings`).
// - **USB:** a camera discovery didn't list before starts a connection (`CamerasModel.onCameraAppeared`). With the app
//   in front the setting is read at once; otherwise when the app is next in front. When it is on, Browse opens on the
//   camera, unless something else holds the screen or the import (another camera's Browse, a job, Import keepers, an
//   "Import new photos" waiting), and then the camera imports at its first listing if the person opens it.
// - **Wi-Fi:** nothing opens by itself. A connection is one Browse visit the person started (a row tap, Connect, the
//   reminder's Import Now), and the setting is read at its first live listing.
// - **Both:** at the first live listing in front, with no job running, nobody choosing files and no "Import new photos"
//   taking it, the app does what *Select All New* then *Import* do, with the remembered choice
//   (`BrowseModel.importAllNew(automatic:)`). At most once per connection (`AutoImportArms`); never with the app away and
//   never from a proximity wake, which only shows the reminder.

extension AppModel {
    // MARK: - Connections

    /// Discovery listed `camera` for the first time (`CamerasModel.onCameraAppeared`): a USB camera's connection starts,
    /// decided now with the app in front, or when it is next in front.
    func autoImportCameraAppeared(_ camera: CameraDescriptor) {
        guard autoImportArms.connected(camera) else { return }
        guard inFront else {
            log.note("auto-import: a camera connected over USB (\(Self.autoImportModeWord(camera))) with the app away; "
                + "deciding when it is in front")
            return
        }
        let id = camera.id
        Task { [weak self] in await self?.decideConnection(id) }
    }

    /// The camera went (`CamerasModel.onCameraDisappeared`): its connection ends.
    func autoImportCameraDisappeared(_ id: CameraDescriptor.ID) {
        autoImportArms.disconnected(id)
    }

    /// The navigation path changed (`browsePathChanged(_:)`): a live Wi-Fi camera opened starts a visit; Browse left on a
    /// USB camera before its card was read ends that connection's auto-import.
    func autoImportPathChanged(_ path: [CameraDescriptor]) {
        let offline = Set(path.map(\.id).filter { cameras.isOffline($0) })
        let left = autoImportArms.pathChanged(to: path, isOffline: { offline.contains($0) })
        // A Browse that went because the camera did (`cameraGone()` sets `.gone` before its `onGone` clears the path) isn't
        // the person leaving it.
        for id in left where cameras.browses(of: id).last?.phase != .gone {
            log.note("auto-import: dropped: Browse was left before the card was read")
        }
    }

    /// Reads the setting for an undecided USB connection with the app in front (section 3.2): off ends it; on opens
    /// Browse on the camera when nothing else holds the screen or the import.
    func decideConnection(_ id: CameraDescriptor.ID) async {
        guard autoImportArms.state(of: id) == .undecided,
              let listed = cameras.cameras.first(where: { $0.id == id }) else { return }
        let decision = await connectionDecision(for: listed)
        // The camera may have gone, a listing may have decided it, or the app may have left (it stays undecided then),
        // while the catalogue and the link were read.
        guard inFront, autoImportArms.state(of: id) == .undecided,
              let camera = cameras.cameras.first(where: { $0.id == id }) else { return }
        autoImportArms.decided(id, decision)
        let connected = "auto-import: a camera connected over USB (\(Self.autoImportModeWord(camera)))"
        guard decision == .on else {
            log.note("\(connected): off (\(decision.logWords))")
            return
        }
        openForAutoImport(camera, connected: connected)
    }

    /// Opens Browse on `camera`, whose setting is on, unless something else holds the screen or the import; its first
    /// listing then starts the import (`autoImportListed(_:)`). Opening it closes what LiveApp closes for an intent:
    /// the Staging loupe and Settings, and a finished Import sheet that isn't this camera's.
    private func openForAutoImport(_ camera: CameraDescriptor, connected: String) {
        if cameras.path.last?.id == camera.id {
            log.note("\(connected): on; Browse is already open on it")
            // A card already read while the setting was being read: nothing more will be listed.
            if let browse = cameras.liveBrowses().last(where: { $0.camera.id == camera.id }) { autoImportListed(browse) }
            return
        }
        let reason: String? = if !cameras.path.isEmpty {
            "another camera's Browse is open"
        } else if importer.isActive {
            "a job is running"
        } else if importer.runsKeepers {
            "Import keepers runs"
        } else if intents.pending != nil {
            "an Import new photos request is waiting"
        } else {
            nil
        }
        if let reason {
            log.note("\(connected): on; not opening Browse (\(reason)); it starts if the camera is opened")
            return
        }
        log.note("\(connected): on; opening Browse")
        cameras.path = [camera]
        intents.navigate(showsImport: false)
    }

    /// The setting for a USB camera at its connection. With no row switched on, nothing more is read: no link is asked
    /// for. Otherwise the key is read as `isCamera(_:withKey:)` reads it, opening nothing.
    private func connectionDecision(for camera: CameraDescriptor) async -> AutoImportDecision {
        guard let records = await autoImportRecords() else { return .unreadable }
        guard records.contains(where: \.autoImport) else { return .off }
        var key: CameraKey?
        if let known = await discovery.knownKey(for: camera.id) {
            key = known
        } else if let link = try? await discovery.cameraLink(for: camera.id) {
            key = await cameraKeying(camera, link)
        }
        return AutoImportRule.decision(for: camera, key: key, records: records)
    }

    // MARK: - The first live listing

    /// A Browse model listed its camera's live card and no "Import new photos" took it (`browseListed(_:)`): the import
    /// starts if the connection is still waiting, the app is in front, Browse is on top of the Cameras stack and ready, and
    /// a fresh read of the setting says on (section 3.4).
    func autoImportListed(_ browse: BrowseModel) {
        let id = browse.camera.id
        guard let state = autoImportArms.state(of: id) else { return }
        switch state {
        case .ended(.started):
            log.note("auto-import: not again for this connection (the card was listed again)")
            return
        case .ended, .deciding:
            return
        case .undecided, .waiting:
            break
        }
        guard inFront else {
            autoImportArms.readWhileAway(id)
            log.note("auto-import: the card was read with the app away; waiting for it to be in front")
            return
        }
        guard cameras.path.last?.id == id else { return }
        if browse.showsLiveCard, browse.liveCardKey == nil {
            // A Wi-Fi camera with no key of its own: Browse imports nothing under a key every such camera would share.
            autoImportArms.end(id, .off(.unidentified))
            log.note("auto-import: the card is read (\(Self.autoImportCarrierWord(browse.camera))): off "
                + "(\(AutoImportDecision.unidentified.logWords))")
            return
        }
        if browse.showsLiveCard, browse.isStartingImport {
            // The person's own Import is being handed over (Photos may be asking): they chose files before the card was read.
            autoImportArms.end(id, .choosingFiles)
            log.note("auto-import: not started: the person is choosing files")
            return
        }
        guard browse.isReadyToImportAllNew, let key = browse.liveCardKey, autoImportArms.beginDeciding(id) else { return }
        Task { [weak self] in await self?.decideListing(browse, key: key) }
    }

    /// Reads the setting for a listing, then hands the card's new files over when it still applies.
    private func decideListing(_ browse: BrowseModel, key: CameraKey) async {
        let id = browse.camera.id
        let carrier = Self.autoImportCarrierWord(browse.camera)
        let decision = await autoImportDecision(for: browse.camera, key: key)
        // Browse was left meanwhile (ended `.leftBrowse`, or the visit removed), or a request took the listing.
        guard autoImportArms.state(of: id) == .deciding else { return }
        guard decision == .on else {
            autoImportArms.finishDeciding(id, .ended(.off(decision)))
            log.note("auto-import: the card is read (\(carrier)): off (\(decision.logWords))")
            return
        }
        if browse.isStartingImport {
            // The person's own Import started while the setting was read.
            autoImportArms.finishDeciding(id, .ended(.choosingFiles))
            log.note("auto-import: not started: the person is choosing files")
            return
        }
        guard inFront, cameras.path.last?.id == id, browse.isReadyToImportAllNew else {
            autoImportArms.finishDeciding(id, .waiting)
            return
        }
        let busy: (AutoImportArms.Ended, String)? = if importer.isActive {
            (.jobRunning, "a job is running")
        } else if importer.runsKeepers {
            (.keepersRunning, "Import keepers runs")
        } else if !browse.selection.isEmpty || browse.isSelecting {
            (.choosingFiles, "the person is choosing files")
        } else {
            nil
        }
        if let (ended, words) = busy {
            autoImportArms.finishDeciding(id, .ended(ended))
            log.note("auto-import: not started: \(words)")
            return
        }
        // No wait between this and the hand-over: a second listing finds it started.
        autoImportArms.finishDeciding(id, .ended(.started))
        let remembered = importer.importChoice
        log.note("auto-import: the card is read (\(carrier)); importing all new "
            + (remembered == .staging ? "to stage" : "to Photos"))
        let outcome = await browse.importAllNew(automatic: true)
        let result: NewPhotosImportStart = outcome.map {
            .requested($0, choice: destinationUsed(by: $0, remembered: remembered))
        } ?? .couldNotStart
        log.note("auto-import: " + Self.logWords(for: result))
        switch outcome {
        case .started?, .appended?: intents.navigate(showsImport: true, importOverCamera: id)
        default: break
        }
    }

    // MARK: - The app in front again

    /// The app is in front again (`scenePhaseChanged(_:)`): USB cameras connected while it was away are decided now, and
    /// a connection whose card was read meanwhile starts, if Browse still shows the live card.
    func autoImportBecameActive() async {
        let undecided = autoImportArms.undecided.filter { id in cameras.cameras.contains { $0.id == id } }
        if !undecided.isEmpty {
            log.note("auto-import: the app is in front; deciding \(undecided.count) camera(s) connected while it was away")
            for id in undecided { await decideConnection(id) }
        }
        // Only a card read with the app away is decided on a return, and only on the first: any other waiting arm waits
        // for a listing, so a later lock and unlock never starts an import after the person imported files themselves.
        for id in autoImportArms.takeReadWhileAway() {
            guard let browse = cameras.liveBrowses().last(where: { $0.camera.id == id }) else { continue }
            autoImportListed(browse)
        }
    }

    /// An "Import new photos" request took the camera's listing (`browseListed(_:)`): the intent imports, once, and the
    /// connection's auto-import ends.
    func autoImportRequestTookListing(_ id: CameraDescriptor.ID) {
        guard let state = autoImportArms.state(of: id), !state.isEnded else { return }
        autoImportArms.end(id, .requestTookIt)
        log.note("auto-import: an Import new photos request took this connection")
    }

    // MARK: - Reading the setting

    /// The setting for `camera` under `key`, from a fresh read of the catalogue; unreadable is treated as off.
    private func autoImportDecision(for camera: CameraDescriptor, key: CameraKey?) async -> AutoImportDecision {
        guard let records = await autoImportRecords() else { return .unreadable }
        return AutoImportRule.decision(for: camera, key: key, records: records)
    }

    /// Every Camera row, or nil (logged) when the catalogue can't be read.
    private func autoImportRecords() async -> [CameraRecord]? {
        do {
            return try await catalogue.cameras()
        } catch {
            log.note("auto-import: the catalogue couldn't be read (\(type(of: error))); treated as off")
            return nil
        }
    }

    /// The camera's USB mode for the log.
    nonisolated static func autoImportModeWord(_ camera: CameraDescriptor) -> String {
        switch camera.mode {
        case .usb(.massStorage): "msc"
        case .usb(.mtp): "mtp"
        case .usb(.remoteShoot): "remote shoot"
        case .wifi: "wifi"
        case .staging: "staging"
        }
    }

    /// The camera's carrier for the log.
    nonisolated static func autoImportCarrierWord(_ camera: CameraDescriptor) -> String {
        camera.carrier == .wifi ? "wifi" : "usb"
    }
}
