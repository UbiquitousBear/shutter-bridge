import Foundation
import ImageCaptureCore

// The guided runs on the Guided tab, following docs/spike-remaining.md's session plan. Each run calls the same
// functions as the Wired, Wi-Fi and Bluetooth tabs' buttons, so it logs and measures exactly what they do; the
// alerts only replace "now do this on the camera" in the runbook.

extension GuidedScript {
    static let all: [GuidedScript] = [
        GuidedScript(id: "usb.evening", group: "USB (session S1)", title: "USB evening: checks, MSC, PC Remote, MTP",
                     summary: "All five USB sections in order (about 35 min). Each can be skipped.") { r in
            try await r.cameraChecks()
            try await r.mscResume()
            try await r.mscLifecycle()
            try await r.pcRemote()
            try await r.mtpPair()
        },
        GuidedScript(id: "usb.checks", group: "USB (session S1)", title: "Camera and Photos checks",
                     summary: "Can the USB mode be fixed; does Photos › Import show JPGs (3 min).") { r in try await r.cameraChecks() },
        GuidedScript(id: "usb.msc.resume", group: "USB (session S1)", title: "MSC: resume after a cable pull",
                     summary: "requestReadData read, pull at the alert, replug, resume and verify (3 min).") { r in try await r.mscResume() },
        GuidedScript(id: "usb.msc.lifecycle", group: "USB (session S1)", title: "MSC: app switch, continued task, lock",
                     summary: "Three downloads; you switch apps or lock the phone when told (12 min).") { r in try await r.mscLifecycle() },
        GuidedScript(id: "usb.pcremote", group: "USB (session S1)", title: "PC Remote: DeviceInfo and ObjectAdded",
                     summary: "Does the shutter work and send ObjectAdded over USB (5 min).") { r in try await r.pcRemote() },
        GuidedScript(id: "usb.mtp.pair", group: "USB (session S1)", title: "MTP: RAW+JPEG pair",
                     summary: "GetObjectInfo of the newest ARW and its JPG or HEIF (3 min).") { r in try await r.mtpPair() },

        GuidedScript(id: "wifi.mode", group: "Wi-Fi (session S2)", title: "Wi-Fi: one camera mode",
                     summary: "Join, probes, connect, list, thumbnails, 20 ARW, shutter (15 min). Run once per mode.") { r in try await r.wifiModePass() },
        GuidedScript(id: "wifi.guid", group: "Wi-Fi (session S2)", title: "Wi-Fi: GUID after a power cycle",
                     summary: "Reconnect with the same GUID, then a new one; note the camera's prompts (5 min).") { r in try await r.wifiGUID() },
        GuidedScript(id: "wifi.resume", group: "Wi-Fi (session S2)", title: "Wi-Fi: resume after Wi-Fi off",
                     summary: "Reference hash, read paused at 50 %, Wi-Fi off and on, resume and verify (5 min).") { r in try await r.wifiResume() },

        GuidedScript(id: "ble.adverts", group: "Bluetooth (session S3)", title: "Bluetooth: what the camera advertises",
                     summary: "30 s scans with the camera on, asleep and off; snapshots; pick the filter UUID (15 min).") { r in try await r.bleAdverts() },
        GuidedScript(id: "ble.proximity", group: "Bluetooth (session S3)", title: "Bluetooth: proximity reminder",
                     summary: "Background watch, camera switched on with the phone locked; same room and next room (15 min).") { r in try await r.bleProximity() },
    ]
}

extension GuidedRunner {
    // MARK: - USB helpers

    func ensureBrowsing() async {
        if !browser.isBrowsing {
            step("Start browsing for cameras")
            await browser.start()
        }
    }

    /// Waits for a camera other than `old` to appear and selects it.
    func waitForCamera(mode: String, excluding old: ICCameraDevice?) async throws {
        await ensureBrowsing()
        let found = try await waitUntil("Plug in the camera",
                                        "Plug the camera into the phone and choose \(mode) on the camera's screen.",
                                        timeout: 300) { self.browser.cameras.contains { $0 !== old } }
        guard found, let camera = browser.cameras.last(where: { $0 !== old }) else {
            throw GuidedStop("no camera appeared within 5 minutes")
        }
        usb.selectedCameraID = ObjectIdentifier(camera)
        log.note("  guided: camera \(camera.name ?? "?") over \(camera.transportType ?? "?")")
    }

    /// Gets the camera attached in `mode`: keeps one that is already attached in that mode, otherwise asks for an
    /// unplug and a replug.
    func prepareMode(_ mode: String) async throws {
        await ensureBrowsing()
        if let attached = usb.selectedCamera {
            let keep = try await ask("USB mode", "Is the camera plugged in, in \(mode)? It is attached over \(attached.transportType ?? "?").",
                                     buttons: ["Yes, keep it", "No, replug it"])
            if keep.hasPrefix("Yes") { return }
            try await waitUntil("Unplug the camera", "Pull the cable out of the phone.", timeout: 300) {
                !self.browser.cameras.contains { $0 === attached } || (self.usb.session?.removed ?? false)
            }
            try await waitForCamera(mode: mode, excluding: attached)
        } else {
            try await waitForCamera(mode: mode, excluding: nil)
        }
    }

    /// Opens a session on the selected camera; offers a retry if it doesn't open.
    func openSession(wait: Bool) async throws {
        while true {
            step("Open session" + (wait ? "" : " (not waiting for the catalogue)"))
            let done = GuidedFlag()
            Task {
                await self.usb.openSession(waitForCatalogue: wait)
                done.value = true
            }
            try await waitUntil("Opening the session",
                                wait ? "Waiting for ImageCaptureCore's catalogue: about 7 s in MSC, 65 s in MTP." : "Opening.",
                                timeout: 240) { done.value }
            if usb.isOpen { return }
            let retry = try await ask("The session didn't open", usb.session?.lastResult ?? "No session.",
                                      buttons: ["Try again", "Skip this section"])
            if retry != "Try again" { throw GuidedStop("the session didn't open") }
        }
    }

    /// Runs a session operation and waits for it; "Cancel run" stops it.
    func operation(_ title: String, _ message: String, timeout: Double,
                   _ work: @escaping @MainActor (CameraSession) async -> Void) async throws {
        let done = GuidedFlag()
        Task {
            await self.usb.run(work)
            done.value = true
        }
        do {
            let finished = try await waitUntil(title, message, timeout: timeout) { done.value }
            if !finished {
                usb.session?.requestStop()
                try await waitUntil("Stopping", "Stopping \(title).", timeout: 90) { done.value }
            }
        } catch is GuidedCancelled {
            usb.session?.requestStop()
            throw GuidedCancelled()
        }
    }

    /// Checks the transport: mass storage for MSC, USB (PTP) for MTP and PC Remote.
    func expectTransport(massStorage: Bool, mode: String) async throws {
        let transport = usb.session?.device.transportType ?? usb.selectedCamera?.transportType ?? "?"
        let isMassStorage = transport.localizedCaseInsensitiveContains("MassStorage")
        guard isMassStorage != massStorage else { return }
        let go = try await ask("Not \(mode)?", "The camera is attached over \(transport), which isn't what \(mode) gives.",
                               buttons: ["Continue anyway", "Skip this section"])
        if go != "Continue anyway" { throw GuidedStop("wrong USB mode (\(transport))") }
    }

    /// Starts `work`, asks the tester to `action` (switch apps, lock the phone) and waits until the app is back in
    /// front, then offers to stop the transfer or let it finish.
    func awayDuring(_ title: String, action: String, minutes: Int,
                    _ work: @escaping @MainActor (CameraSession) async -> Void) async throws {
        try await ask(title, "Tap Start, then \(action) within 10 s and stay away about \(minutes) min. The run carries on when you come back.",
                      buttons: ["Start"])
        let returns = lifecycle.foregroundReturns
        let done = GuidedFlag()
        Task {
            await self.usb.run(work)
            done.value = true
        }
        do {
            try await waitUntil(title, "Now \(action). Come back after about \(minutes) min.", timeout: Double(minutes * 60 + 900)) {
                self.lifecycle.foregroundReturns > returns || done.value
            }
            if lifecycle.foregroundReturns == returns {
                log.warn("  guided: \(title): the transfer ended before the app left the foreground")
            } else {
                log.note(String(format: "  guided: %@: away %.0f s", title, lifecycle.lastAwaySeconds))
            }
            if !done.value {
                let next = try await ask("Back in the app", "The transfer is still running.", buttons: ["Let it finish", "Stop it now"])
                if next == "Stop it now" { usb.session?.requestStop() }
                try await waitUntil("Finishing", "Waiting for the transfer to end.", timeout: 900) { done.value }
            }
        } catch is GuidedCancelled {
            usb.session?.requestStop()
            throw GuidedCancelled()
        }
    }

    // MARK: - USB sections

    func cameraChecks() async throws {
        try await section("Camera and Photos checks", "Two questions, about 3 minutes. No app session.") {
            let mode = try await ask("USB Connection Mode",
                                     "On the camera: Setup → USB → USB Connection Mode. Can it be set to one mode, so the camera stops asking on every plug?",
                                     buttons: ["Yes, one mode can be set", "No, it always asks", "Skip"])
            if mode != "Skip" { log.flag("usb.mode.fixable", mode.hasPrefix("Yes"), context: mode) }
            let photos = try await ask("Photos › Import",
                                       "With JPGs on the card: plug the camera in, open the Photos app, tap the camera under Import and look for the JPGs. Then come back here.",
                                       buttons: ["JPGs show", "Nothing shows", "Skip"])
            if photos != "Skip" { log.flag("usb.photosImport.jpgShown", photos == "JPGs show", context: "Photos › Import with JPGs on the card") }
        }
    }

    func mscResume() async throws {
        try await section("MSC: resume after a cable pull",
                          "Image Transfer (MSC), about 3 minutes: the app reads the newest ARW slowly, you pull the cable when an alert says so, plug it back in, and the app resumes and checks the file.") {
            try await prepareMode("Image Transfer (MSC)")
            try await openSession(wait: true)
            try await expectTransport(massStorage: true, mode: "Image Transfer (MSC)")
            var attempt = 0
            var pulled = false
            while !pulled {
                attempt += 1
                guard let session = usb.session else { throw GuidedStop("no session") }
                session.onPullNow = { @MainActor [weak self] in
                    self?.notice("Pull the cable now", "Pull the USB-C cable out of the phone now.")
                }
                try await operation("Reading the newest ARW", "About 18 s. An alert will say when to pull the cable.", timeout: 180) {
                    await $0.startReadDataResume()
                }
                session.onPullNow = nil
                pulled = try await waitUntil("Waiting for the cable pull", "Pull the USB-C cable out of the phone now.", timeout: 20) {
                    session.removed
                }
                if !pulled {
                    if attempt >= 2 { throw GuidedStop("the read finished before the cable was pulled, twice") }
                    try await ask("No cable pull", "The read finished before the cable came out. It starts again; pull when the alert appears.",
                                  buttons: ["Try again"])
                }
            }
            try await waitForCamera(mode: "Image Transfer (MSC)", excluding: usb.session?.device)
            try await openSession(wait: true)
            try await operation("Resuming the read", "Reading the rest, then checking it against a download.", timeout: 300) {
                await $0.resumeReadDataRead()
            }
        }
    }

    func mscLifecycle() async throws {
        try await section("MSC: app switch, continued task, lock",
                          "Image Transfer (MSC), about 12 minutes. Three downloads: you switch apps during the first, lock the phone during a continued task, then lock it during the last.") {
            try await prepareMode("Image Transfer (MSC)")
            try await openSession(wait: true)
            try await expectTransport(massStorage: true, mode: "Image Transfer (MSC)")

            try await awayDuring("App switch during a download", action: "switch to another app (Settings, say)", minutes: 2) {
                await $0.longSerialDownload()
            }

            try await ask("Continued task", "Tap Start: 20 ARW download inside a continued task. Lock the phone as soon as its progress appears on the Lock Screen or in the Dynamic Island, and unlock after about 1 min.",
                          buttons: ["Start"])
            let returns = lifecycle.foregroundReturns
            usb.session?.continuedDownload(using: continued)
            try await waitUntil("Starting the continued task", "Waiting for iOS to start it.", timeout: 30) { self.continued.isRunning }
            try await waitUntil("Lock the phone now", "Lock the phone. Unlock it after about 1 min.", timeout: 600) {
                self.lifecycle.foregroundReturns > returns || !self.continued.isRunning
            }
            try await waitUntil("Finishing the continued task", "Waiting for it to end.", timeout: 600) { !self.continued.isRunning }

            try await awayDuring("Lock during a download", action: "lock the phone", minutes: 3) {
                await $0.longSerialDownload()
            }
        }
    }

    func pcRemote() async throws {
        try await section("PC Remote: DeviceInfo and ObjectAdded",
                          "Remote Shoot (PC Remote), about 5 minutes: the only USB mode with the shutter enabled. Does it send a new-photo event?") {
            try await prepareMode("Remote Shoot (PC Remote)")
            try await openSession(wait: false)
            try await operation("GetDeviceInfo", "Reading what the camera supports in PC Remote mode. Up to 65 s while ImageCaptureCore lists the card.", timeout: 150) {
                await $0.ptpGetDeviceInfo()
            }
            try await ask("Press the shutter", "Tap Start, then press the shutter 2 or 3 times in the next 60 s.", buttons: ["Start"])
            try await operation("Watching for ObjectAdded (60 s)", "Press the shutter 2 or 3 times now.", timeout: 150) {
                await $0.watchForObjectAdded(seconds: 60)
            }
            let shot = try await ask("Did the camera take the pictures?", "Did the shutter fire?", buttons: ["Yes", "No, it was disabled"])
            log.flag("usb.pcRemote.shutterEnabled", shot == "Yes", context: "Remote Shoot (PC Remote) with a session open")
        }
    }

    func mtpPair() async throws {
        try await section("MTP: RAW+JPEG pair",
                          "Image Transfer (MTP), about 3 minutes. Needs RAW+JPEG or RAW+HEIF frames on the card; the catalogue takes about 65 s.") {
            try await ask("Shoot the pairs", "If you haven't yet: with the cable out, shoot 3 frames in RAW+JPEG and 2 in RAW+HEIF.",
                          buttons: ["Done", "Already on the card"])
            try await prepareMode("Image Transfer (MTP)")
            try await openSession(wait: true)
            try await expectTransport(massStorage: false, mode: "Image Transfer (MTP)")
            try await operation("GetObjectInfo: newest ARW + pair", "Reading the newest ARW and its pair.", timeout: 180) {
                await $0.ptpObjectInfo()
            }
        }
    }

    // MARK: - Wi-Fi helpers

    /// The same target the Wi-Fi tab builds from its stored settings.
    func wifiTarget() -> WiFiTarget {
        let defaults = UserDefaults.standard
        let net = defaults.string(forKey: "ptpip.net") == "lan" ? "lan" : "ap"
        let host = (defaults.string(forKey: "ptpip.host") ?? "192.168.122.1").trimmingCharacters(in: .whitespacesAndNewlines)
        var guidString = defaults.string(forKey: "ptpip.guid") ?? ""
        if UUID(uuidString: guidString) == nil {
            guidString = UUID().uuidString
            defaults.set(guidString, forKey: "ptpip.guid")
        }
        return WiFiTarget(net: net, host: host, guid: UUID(uuidString: guidString) ?? UUID())
    }

    /// Starts a Wi-Fi tab action (they run in their own Task) and waits until the lab is idle again.
    func wifi(_ title: String, _ message: String, timeout: Double, _ start: () -> Void) async throws {
        if wireless.busy || wireless.probing || wireless.joining {
            try await waitUntil("Waiting for the Wi-Fi tab", "Another Wi-Fi action is running.", timeout: 120) {
                !self.wireless.busy && !self.wireless.probing && !self.wireless.joining
            }
        }
        step(title)
        start()
        let idle = try await waitUntil(title, message, timeout: timeout) {
            !self.wireless.busy && !self.wireless.probing && !self.wireless.joining
        }
        if !idle { throw GuidedStop("\(title) didn't finish within \(Int(timeout)) s") }
    }

    /// Network, join and camera IP: on the camera's access point the QR code and join, on the home LAN the IP.
    func wifiJoin() async throws {
        let net = try await ask("Which network?", "The camera's own Wi-Fi (access point), or your home network (LAN)?",
                                buttons: ["Camera access point", "Home LAN"])
        UserDefaults.standard.set(net == "Home LAN" ? "lan" : "ap", forKey: "ptpip.net")
        wireless.path.start()
        if net == "Home LAN" {
            let typed = try await waitInTabs("Camera IP on the home LAN",
                                             "Open the Wi-Fi tab and type the camera's IP in Camera IP (or use a Bonjour or SSDP result there), then come back and tap Done.",
                                             timeout: 900) { false }
            if typed != "Done" { throw GuidedStop("no camera IP") }
            return
        }
        let before = wireless.qrSummary
        let scanned = try await waitInTabs("Scan the camera's QR code",
                                           "Put the camera on its Wi-Fi screen. Open the Wi-Fi tab and tap Scan camera QR code (or type the SSID and password there). This step ends by itself once the code is read.",
                                           timeout: 900) {
            !self.wireless.joinSSID.isEmpty && self.wireless.qrSummary != before
        }
        if scanned == "Skip" { return }
        if wireless.joinSSID.isEmpty { throw GuidedStop("no SSID to join") }
        try await wifi("Join camera Wi-Fi", "Accept the system prompt to join the camera's network.", timeout: 90) { wireless.join() }
        if let gateway = wireless.gatewayCandidate {
            UserDefaults.standard.set(gateway, forKey: "ptpip.host")
            log.note("  guided: camera IP \(gateway) (the network's gateway)")
        } else {
            let fixed = try await waitInTabs("Camera IP", "The join didn't give a gateway. In the Wi-Fi tab, check you're on the camera's network and set Camera IP, then tap Done here.",
                                             timeout: 900) { self.wireless.gatewayCandidate != nil }
            if fixed == "Skip" { throw GuidedStop("no camera IP") }
            if let gateway = wireless.gatewayCandidate { UserDefaults.standard.set(gateway, forKey: "ptpip.host") }
        }
    }

    // MARK: - Wi-Fi sections

    func wifiModePass() async throws {
        let mode = try await ask("Camera mode", "Which Wi-Fi mode is the camera in? Set it on the camera now (Network menu).",
                                 buttons: ["Smartphone Connect", "PC Remote (access point)", "Wi-Fi Direct"])
        step("Wi-Fi mode: \(mode)")
        log.note("◆ Wi-Fi mode under test: \(mode)")
        try await section("Join and find the camera", "The network, then the camera's IP.") {
            try await wifiJoin()
        }
        try await section("Day 6 probes", "TCP 15740, Bonjour, SSDP unicast and multicast (about 20 s).") {
            let t = wifiTarget()
            try await wifi("TCP 15740", "Connecting to \(t.host):15740.", timeout: 30) { wireless.probePort(t) }
            try await wifi("Bonjour", "Browsing _ptp._tcp for 5 s.", timeout: 30) { wireless.browseBonjour(t) }
            try await wifi("SSDP unicast", "M-SEARCH to \(t.host) for 5 s.", timeout: 30) { wireless.ssdpUnicast(t) }
            try await wifi("SSDP multicast", "M-SEARCH to the multicast group for 5 s (fails without the multicast entitlement).", timeout: 30) {
                wireless.ssdpMulticast(t)
            }
        }
        try await section("Session and transfers", "Connect, list the card, 50 thumbnails, 20 newest ARW, then the shutter (about 10 min).") {
            let t = wifiTarget()
            try await wifi("Connect + OpenSession + GetDeviceInfo", "The camera may ask you to confirm the connection: accept it on the camera.", timeout: 120) {
                wireless.connect(t)
            }
            guard wireless.isConnected, wireless.connectionState.hasPrefix("connected") else {
                throw GuidedStop("not connected: \(wireless.connectionState)")
            }
            if mode.hasPrefix("PC Remote") {
                try await wifi("Sony SDIO connect", "The Sony handshake that PC Remote modes may need before listing.", timeout: 60) { wireless.sonySDIO() }
            }
            try await wifi("List card", "GetObjectHandles, then GetObjectInfo for every object.", timeout: 900) { wireless.listCard() }
            if wireless.objects.isEmpty { throw GuidedStop("the card listed no objects in this mode") }
            try await wifi("Thumbnails for 50 newest", "GetThumb for the 50 newest.", timeout: 300) { wireless.thumbnails() }
            try await wifi("GetObject 20 newest ARW", "Downloading 20 ARW, with the battery read before and after.", timeout: 1200) { wireless.downloadARW() }
            try await ask("Press the shutter", "Tap Start, then press the shutter twice in the next 20 s.", buttons: ["Start"])
            try await wifi("Shutter test (20 s)", "Press the shutter twice now.", timeout: 60) { wireless.shutterTest() }
        }
    }

    func wifiGUID() async throws {
        try await section("GUID after a power cycle", "Is this phone remembered after the camera restarts, and is a new phone asked to confirm? About 5 minutes.") {
            try await ask("Restart the camera", "Switch the camera off and on, put it back in the same Wi-Fi mode, and wait for its Wi-Fi screen. If the phone doesn't rejoin the camera's network by itself, rejoin it in Settings.",
                          buttons: ["Done"])
            try await wifi("Reconnect (same GUID)", "Reconnecting as the same phone.", timeout: 120) { wireless.reconnect(wifiTarget()) }
            let same = try await ask("Did the camera ask?", "Did the camera ask you to confirm the connection this time?",
                                     buttons: ["No, it connected", "Yes, it asked", "It failed"])
            log.note("◆ Same GUID after a power cycle: \(same)")
            UserDefaults.standard.set(UUID().uuidString, forKey: "ptpip.guid")
            log.note("PTP/IP: new GUID for the re-pair test (guided run)")
            try await wifi("Connect (new GUID)", "Connecting as a new phone: accept on the camera if it asks.", timeout: 120) { wireless.connect(wifiTarget()) }
            let new = try await ask("Did the camera ask?", "Did the camera ask you to confirm this new phone?",
                                    buttons: ["Yes, it asked", "No, it connected", "It failed"])
            log.note("◆ New GUID: \(new)")
        }
    }

    func wifiResume() async throws {
        try await section("Resume after Wi-Fi off", "A reference download, then a read that pauses at 50 % for you to turn Wi-Fi off and on, then the resume. About 5 minutes.") {
            guard wireless.isConnected else { throw GuidedStop("connect first (Wi-Fi: one camera mode)") }
            if wireless.objects.isEmpty {
                try await wifi("List card", "The resume needs the card listed.", timeout: 900) { wireless.listCard() }
            }
            try await wifi("Reference hash", "GetObject of the newest ARW, for the SHA-256 to compare with.", timeout: 300) { wireless.referenceHash() }
            step("Resumable read, paused at 50 %")
            wireless.startResumableRead(pauseAtHalf: true)
            try await waitUntil("Reading to 50 %", "The read pauses at 50 %.", timeout: 300) {
                !self.wireless.busy || self.wireless.activity.hasPrefix("Paused at")
            }
            if wireless.busy {
                try await waitUntil("Turn Wi-Fi off now", "Open Control Centre and turn Wi-Fi off. Turn it back on after about 10 s, and let the phone rejoin the camera's network.",
                                    timeout: 300) { !self.wireless.busy }
            }
            if wireless.resumeSummary == nil { throw GuidedStop("the read finished without an interruption, so there's nothing to resume") }
            try await ask("Back on the camera's network?", "Tap OK once Wi-Fi is on and the phone has rejoined the camera's network.", buttons: ["OK"])
            try await wifi("Resume read", "Reconnecting, finding the file again and reading the rest.", timeout: 600) { wireless.resumeRead(wifiTarget()) }
        }
    }

    // MARK: - Bluetooth sections

    private func scan(power: AdvertisementScanner.PowerState, pairing: AdvertisementScanner.PairingContext,
                      instructions: String) async throws {
        let go = try await ask("Camera \(power.rawValue), \(pairing.rawValue)", instructions, buttons: ["Ready", "Skip this state"])
        guard go == "Ready" else { return }
        scanner.log = log
        scanner.start(sonyOnly: true)
        let started = try await waitUntil("Starting the scan", "Allow Bluetooth if iOS asks.", timeout: 30) { self.scanner.isScanning }
        if !started { throw GuidedStop("Bluetooth scanning didn't start (\(scanner.state))") }
        try await waitUntil("Scanning for 30 s", "Camera \(power.rawValue); leave it as it is.", timeout: 32) {
            guard let since = self.scanner.scanStartedAt else { return false }
            return Date().timeIntervalSince(since) >= 30
        }
        scanner.stop()
        let uuid = UserDefaults.standard.string(forKey: ProximityWatcher.Keys.serviceUUID) ?? ""
        scanner.saveSnapshot(power: power, pairing: pairing, proximityUUID: uuid.isEmpty ? nil : uuid)
    }

    func bleAdverts() async throws {
        try await section("Advertisements by power state",
                          "Creators' App paired but quit (the usual state for our users), then one run with it connected. 30 s scans, about 15 minutes.") {
            try await scan(power: .on, pairing: .unlinked, instructions: "Quit Creators' App (swipe it away). Camera switched on.")
            try await scan(power: .asleep, pairing: .unlinked, instructions: "Let the camera go to sleep (power save), Creators' App still quit.")
            try await scan(power: .off, pairing: .unlinked, instructions: "Switch the camera off, Creators' App still quit.")
            try await scan(power: .on, pairing: .connected, instructions: "Switch the camera on and open Creators' App until it shows the camera connected.")
            try await scan(power: .on, pairing: .unpaired, instructions: "Only if you're happy to pair again later: remove the camera in Creators' App and in the camera's Bluetooth settings. Otherwise skip.")
        }
        try await section("Proximity filter UUID", "Pick the service UUID the background watch filters on.") {
            let candidates = scanner.candidateServiceUUIDs
            guard !candidates.isEmpty else {
                throw GuidedStop("no service UUID advertised by a camera-like device; background scanning needs an advertised one")
            }
            let choice = try await ask("Filter UUID", "Advertised by the camera: \(candidates.joined(separator: ", ")). Use which one?",
                                       buttons: Array(candidates.prefix(3)) + ["None of them"])
            if candidates.contains(choice) {
                UserDefaults.standard.set(choice, forKey: ProximityWatcher.Keys.serviceUUID)
                proximity.serviceUUIDChanged()
                log.note("◆ Proximity filter UUID set to \(choice)")
            }
        }
    }

    func bleProximity() async throws {
        try await section("Proximity reminder", "Background watch on, phone locked, camera switched on; same room, then next room. About 15 minutes.") {
            guard proximity.storedServiceUUID != nil else { throw GuidedStop("no filter UUID yet: run Bluetooth: what the camera advertises") }
            if !proximity.enabled {
                proximity.setEnabled(true)
                try await waitUntil("Starting the background watch", "Allow notifications and Bluetooth if iOS asks.", timeout: 60) {
                    self.proximity.isScanning
                }
            }
            for room in ["same room", "next room"] {
                try await ask("Camera off for a minute", "Switch the camera off and wait about a minute. \(room == "next room" ? "Then take the phone into the next room." : "")",
                              buttons: ["Done"])
                try await ask("Switch on with the phone locked", "Tap Start, lock the phone straight away and switch the camera on. Wait up to 2 minutes for a reminder, then unlock.",
                              buttons: ["Start"])
                let returns = lifecycle.foregroundReturns
                proximity.markCameraSwitchedOn()
                try await waitUntil("Lock the phone now", "Lock the phone and switch the camera on. Unlock after the reminder, or after 2 minutes.",
                                    timeout: 600) { self.lifecycle.foregroundReturns > returns }
                let seen = try await ask("Reminder?", "Did a reminder arrive while the phone was locked (\(room))?",
                                         buttons: ["Yes", "No"])
                log.flag("ble.proximity.reminder.\(room == "same room" ? "sameRoom" : "nextRoom")", seen == "Yes",
                         context: "camera switched on with the phone locked, \(room)")
            }
        }
    }
}
