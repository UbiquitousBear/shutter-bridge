import Foundation
import ImageCaptureCore

// The guided runs on the Guided tab, following docs/spike-remaining.md's session plan. Each run calls the same
// functions as the Wired, Wi-Fi and Bluetooth tabs' buttons, so it logs and measures exactly what they do; the
// alerts only replace "now do this on the camera" in the runbook.

/// The camera-port wait after a restart (GuidedRunner.waitForCameraPort): written by its polling task, read by the
/// waiting alert's condition, both on the main actor.
@MainActor
private final class PortWait {
    var attempts = 0
    var lastError = "none"
    /// Seconds from the start of the wait to the first TCP connect that succeeded; nil until then.
    var answeredAfter: Double?
}

/// One decimal by default, as in the log lines elsewhere.
private func fmt(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

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

        GuidedScript(id: "usb.browse", group: "USB (session S1)", title: "USB: thumbnail speed-ups",
                     summary: "Thumbnails 1, 2 and 4 at a time; previews read from the file headers (5 min, MSC or MTP).") { r in try await r.usbBrowseSpeed() },
        GuidedScript(id: "usb.long.lock", group: "USB (session S1)", title: "USB: 10-minute continued task under lock",
                     summary: "A continued task over the whole card for 10 min with the phone locked (12 min, mostly unattended).") { r in try await r.usbLongLock() },
        GuidedScript(id: "usb.scaling", group: "Scaling", title: "Scaling: listing time vs card size",
                     summary: "Cold listing now, a burst of about 300 frames, cold listing again; projects 2,000 and 5,000 files (20–30 min).") { r in try await r.scaling() },

        GuidedScript(id: "wifi.mode", group: "Wi-Fi (session S2)", title: "Wi-Fi: one camera mode",
                     summary: "Join, probes, connect, list (Sony contents transfer if nothing lists), thumbnails, 20 ARW, shutter (15 min). Run once per mode.") { r in try await r.wifiModePass() },
        GuidedScript(id: "wifi.guid", group: "Wi-Fi (session S2)", title: "Wi-Fi: GUID after a power cycle",
                     summary: "Reconnect with the same GUID, then a new one; note the camera's prompts (5 min).") { r in try await r.wifiGUID() },
        GuidedScript(id: "wifi.resume", group: "Wi-Fi (session S2)", title: "Wi-Fi: resume after Wi-Fi off",
                     summary: "Partial read probe if not yet run on this network, reference hash, read paused at 50 %, Wi-Fi off and on, resume and verify (5–8 min).") { r in try await r.wifiResume() },
        GuidedScript(id: "wifi.lock", group: "Wi-Fi (session S2)", title: "Wi-Fi: lock during a transfer",
                     summary: "20 ARW with the phone locked, then the same inside a continued task (8 min).") { r in try await r.wifiLock() },
        GuidedScript(id: "wifi.send", group: "Wi-Fi (session S2)", title: "Wi-Fi: Send to Smartphone",
                     summary: "The fallback: choose 2 photos on the camera and send; does the app see just those? (5 min).") { r in try await r.wifiSendToSmartphone() },

        GuidedScript(id: "ble.adverts", group: "Bluetooth (session S3)", title: "Bluetooth: what the camera advertises",
                     summary: "30 s scans with the camera on, asleep and off; snapshots; pick the filter UUID (15 min).") { r in try await r.bleAdverts() },
        GuidedScript(id: "ble.proximity", group: "Bluetooth (session S3)", title: "Bluetooth: proximity reminder",
                     summary: "Background watch; the scan starts once the phone is locked, camera nearby on or off; same room and next room (10 min).") { r in try await r.bleProximity() },
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

    /// `camera` has gone: the browser no longer lists it, or its own session saw it removed.
    func isUnplugged(_ camera: ICCameraDevice?) -> Bool {
        guard let camera else { return true }
        if !browser.cameras.contains(where: { $0 === camera }) { return true }
        if let session = usb.session, session.device === camera, session.removed { return true }
        return false
    }

    /// Starts a continued task with `submit` and waits for iOS to run it; stops the section if it was refused.
    func startContinued(_ what: String, _ submit: () -> Void) async throws {
        submit()
        let started = try await waitUntil("Starting the continued task", "Waiting for iOS to start it.", timeout: 30) {
            self.continued.state == "running" || !self.continued.isRunning
        }
        guard started, continued.isRunning, continued.state == "running" else {
            throw GuidedStop("\(what) didn't start (continued task: \(continued.state); the log says why)")
        }
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
                self.isUnplugged(attached)
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
                                wait ? "Waiting for ImageCaptureCore's catalogue: about 7 s in MSC, 65 s in MTP (longer for a bigger card)." : "Opening.",
                                timeout: wait ? 900 : 120) { done.value }
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
        let entries = lifecycle.backgroundEntries
        let done = GuidedFlag()
        Task {
            await self.usb.run(work)
            done.value = true
        }
        do {
            try await waitUntil(title, "Now \(action). Come back after about \(minutes) min.", timeout: Double(minutes * 60 + 900)) {
                self.lifecycle.foregroundReturns > returns || (done.value && self.lifecycle.backgroundEntries == entries)
            }
            if lifecycle.backgroundEntries == entries {
                log.warn("  guided: \(title): \(done.value ? "the transfer ended before the app left the foreground" : "the app never left the foreground")")
            } else if lifecycle.foregroundReturns > returns {
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
                guard let session = usb.session, session.isOpen, !session.removed else {
                    throw GuidedStop("no open session (the camera may have been unplugged)")
                }
                let resultBefore = session.lastResult
                session.onPullNow = { @MainActor [weak self] in
                    self?.notice("Pull the cable now", "Pull the USB-C cable out of the phone now.")
                }
                defer { session.onPullNow = nil }
                try await operation("Reading the newest ARW", "About 18 s. An alert will say when to pull the cable.", timeout: 180) {
                    await $0.startReadDataResume()
                }
                let result = session.lastResult
                if result == resultBefore {
                    throw GuidedStop("the read didn't start (\(session.removed ? "the camera was unplugged" : "the session was busy or closed"))")
                }
                if result.hasPrefix("Interrupted") {
                    // The read's own error comes first; ImageCaptureCore reports the removal a moment later.
                    pulled = try await waitUntil("Detecting the cable pull", "Waiting for the phone to notice the camera has gone.", timeout: 20) {
                        session.removed
                    }
                    if !pulled { throw GuidedStop("the read stopped without a cable pull: \(result)") }
                } else if result == "Finished without interruption" {
                    if attempt >= 2 { throw GuidedStop("the read finished before the cable was pulled, twice") }
                    try await ask("No cable pull", "The read finished before the cable came out. It starts again; pull when the alert appears.",
                                  buttons: ["Try again"])
                } else {
                    throw GuidedStop("the read didn't run: \(result)")
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
            try await startContinued("The 20-ARW continued task") { usb.session?.continuedDownload(using: continued) }
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
            // Pass-through waits for ImageCaptureCore's catalogue, and a command's own timeout is 60 s: open with the wait.
            try await openSession(wait: true)
            try await operation("GetDeviceInfo", "Reading what the camera supports in PC Remote mode.", timeout: 150) {
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

    func usbBrowseSpeed() async throws {
        try await section("USB: thumbnail speed-ups",
                          "Works in MSC or MTP, about 5 minutes. Thumbnails one, two and four at a time on different files (so none comes from a cache), then the previews built into the files, read with requestReadData.") {
            try await prepareMode("Image Transfer (MSC) or (MTP)")
            try await openSession(wait: true)
            try await operation("Thumbnails, 1 at a time (files 1–50)", "", timeout: 300) { await $0.timeThumbnailsConcurrent(count: 50, offset: 0, inFlight: 1) }
            try await operation("Thumbnails, 2 at a time (files 51–100)", "", timeout: 300) { await $0.timeThumbnailsConcurrent(count: 50, offset: 50, inFlight: 2) }
            try await operation("Thumbnails, 4 at a time (files 101–150)", "", timeout: 300) { await $0.timeThumbnailsConcurrent(count: 50, offset: 100, inFlight: 4) }
            try await operation("ARW previews, first 256 KB", "", timeout: 300) { await $0.timeHeaderPreviews(ext: "ARW", count: 20, offset: 0, kilobytes: 256) }
            try await operation("ARW previews, first 1 MB", "", timeout: 300) { await $0.timeHeaderPreviews(ext: "ARW", count: 20, offset: 20, kilobytes: 1024) }
            try await operation("JPG previews, first 64 KB", "", timeout: 300) { await $0.timeHeaderPreviews(ext: "JPG", count: 20, offset: 0, kilobytes: 64) }
        }
    }

    func usbLongLock() async throws {
        try await section("USB: 10-minute continued task under lock",
                          "Image Transfer (MSC), about 12 minutes, mostly unattended: a continued task over the whole card, repeated for 10 min, with the phone locked throughout.") {
            try await prepareMode("Image Transfer (MSC)")
            try await openSession(wait: true)
            try await expectTransport(massStorage: true, mode: "Image Transfer (MSC)")
            try await ask("Ready to lock", "Tap Start, then lock the phone as soon as the import shows on the Lock Screen or in the Dynamic Island. Leave it locked for the 10 minutes, then unlock.",
                          buttons: ["Start"])
            let returns = lifecycle.foregroundReturns
            try await startContinued("The 10-minute continued task") { usb.session?.continuedLongDownload(using: continued, minutes: 10) }
            try await waitUntil("Lock the phone now", "Lock the phone and leave it for 10 minutes. Unlock afterwards.", timeout: 1500) {
                self.lifecycle.foregroundReturns > returns || !self.continued.isRunning
            }
            try await waitUntil("Finishing the continued task", "Waiting for it to end.", timeout: 900) { !self.continued.isRunning }
        }
    }

    /// A cold catalogue on a fresh plug: (files, seconds), or nil if ImageCaptureCore had kept it (asks for a replug).
    private func coldCatalogue(mode: String, massStorage: Bool) async throws -> (files: Int, seconds: Double) {
        for _ in 0..<2 {
            let old = usb.selectedCamera
            if old != nil {
                try await waitUntil("Unplug the camera", "Pull the cable out of the phone, for a cold listing.", timeout: 300) {
                    self.isUnplugged(old)
                }
            }
            try await waitForCamera(mode: mode, excluding: old)
            let openedAt = Date()
            try await openSession(wait: true)
            try await expectTransport(massStorage: massStorage, mode: mode)
            try await waitUntil("Listing the card", "ImageCaptureCore is still listing a big card.", timeout: 1800) {
                self.usb.session?.catalogComplete ?? true
            }
            if let m = log.measurements.last(where: { $0.at >= openedAt && $0.name.hasPrefix("usb.catalog.complete") }) {
                let files = usb.session?.files.count ?? 0
                if m.name == "usb.catalog.complete" {
                    log.note("  guided: \(mode): \(files) files listed cold in \(fmt(m.value, 2)) s")
                    return (files, m.value)
                }
                log.warn("  guided: \(mode): \(m.name) is not a cold figure; replugging")
            } else {
                log.warn("  guided: \(mode): no catalogue figure after the open; replugging")
            }
        }
        throw GuidedStop("no cold catalogue figure for \(mode)")
    }

    func scaling() async throws {
        try await section("Scaling: listing time vs card size",
                          "About 20–30 minutes. A cold listing in each mode now, then you shoot a burst of about 300 small JPGs, then a cold listing again. From the two sizes the app works out the cost per file and projects 2,000 and 5,000 files.") {
            let modes = try await ask("Which modes?", "MTP adds about 65 s per listing.", buttons: ["MSC only", "MSC and MTP"])
            var plan: [(mode: String, massStorage: Bool, key: String)] = [("Image Transfer (MSC)", true, "msc")]
            if modes == "MSC and MTP" { plan.append(("Image Transfer (MTP)", false, "mtp")) }
            var before: [String: (files: Int, seconds: Double)] = [:]
            for entry in plan {
                step("Cold listing before the burst: \(entry.mode)")
                before[entry.key] = try await coldCatalogue(mode: entry.mode, massStorage: entry.massStorage)
            }
            try await ask("Shoot a burst", "Pull the cable. On the camera: Image Quality JPEG, Image Size S, Drive Mode Continuous Shooting Hi. Shoot about 300 frames (a few long presses of the shutter), then tap Done.",
                          buttons: ["Done"])
            for entry in plan {
                step("Cold listing after the burst: \(entry.mode)")
                let after = try await coldCatalogue(mode: entry.mode, massStorage: entry.massStorage)
                guard let first = before[entry.key], after.files - first.files >= 100 else {
                    log.warn("  guided: \(entry.mode): the card grew by fewer than 100 files, too few for a scaling figure")
                    continue
                }
                let perFile = (after.seconds - first.seconds) / Double(after.files - first.files)
                guard perFile > 0 else {
                    log.warn("  guided: \(entry.mode): the bigger card listed no slower (\(fmt(first.seconds, 2)) s → \(fmt(after.seconds, 2)) s), so no projection")
                    continue
                }
                let fixed = first.seconds - perFile * Double(first.files)
                let context = "cold catalogue \(first.files) files \(fmt(first.seconds, 2)) s → \(after.files) files \(fmt(after.seconds, 2)) s; fixed part \(fmt(fixed, 2)) s"
                log.measure("usb.\(entry.key).catalog.perFile", perFile * 1000, "ms", context: context)
                for target in [2_000, 5_000] {
                    log.measure("usb.\(entry.key).catalog.projected\(target)", fixed + perFile * Double(target), "s",
                                context: "straight-line projection from two card sizes; " + context)
                }
            }
            try await ask("Tidy the card", "If you don't want the burst frames, delete them on the camera (Playback → Delete → Multiple Images, or protect the rest and delete all).",
                          buttons: ["OK"])
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
    /// `homeLAN` answers "Which network?" for the caller when the camera mode already says which (nil asks).
    func wifiJoin(homeLAN: Bool? = nil) async throws {
        let net: String
        if let homeLAN {
            net = homeLAN ? "Home LAN" : "Camera access point"
            log.note("  guided: network \(net) (from the camera mode)")
        } else {
            net = try await ask("Which network?", "The camera's own Wi-Fi (access point), or your home network (LAN)?",
                                buttons: ["Camera access point", "Home LAN"])
        }
        UserDefaults.standard.set(net == "Home LAN" ? "lan" : "ap", forKey: "ptpip.net")
        wireless.path.start()
        if net == "Home LAN" {
            let typed = try await waitInTabs("Camera IP on the home LAN",
                                             "Open the Wi-Fi tab and type the camera's IP in Camera IP (or use a Bonjour or SSDP result there), then come back and tap Done.",
                                             timeout: 900) { false }
            if typed != "Done" { throw GuidedStop("no camera IP") }
            return
        }
        let scans = wireless.qrScans
        // The SSID from an earlier scan stays in memory for the whole launch: only a new scan (or a newly typed
        // SSID) means the app should join; Done with nothing new means the tester joined in Settings.
        let ssidBefore = wireless.joinSSID
        let scanned = try await waitInTabs("Join the camera's network",
                                           "On the camera, open the screen with its QR code (Smartphone Connect) or its network name and password (PC Remote over Wi-Fi Direct). Scan the code on the Wi-Fi tab, or join the camera's network in Settings › Wi-Fi, then tap Done here.",
                                           timeout: 900) {
            self.wireless.qrScans > scans
        }
        if scanned == "Skip" { return }
        if scanned == "Done" && (wireless.joinSSID.isEmpty || wireless.joinSSID == ssidBefore) {
            // Joined in Settings (PC Remote shows no QR code): look for the camera on the network the phone is on.
            try await findCameraJoinedOutsideApp()
            return
        }
        if wireless.joinSSID.isEmpty { throw GuidedStop("no SSID to join") }
        try await wifi("Join camera Wi-Fi", "Accept the system prompt to join the camera's network.", timeout: 90) { wireless.join() }
        // Only this join's own gateway: a failed join leaves the home network's, which isn't the camera.
        if let gateway = wireless.lastJoinGateway {
            UserDefaults.standard.set(gateway, forKey: "ptpip.host")
            log.note("  guided: camera IP \(gateway) (the camera network's gateway)")
        } else {
            let fixed = try await waitInTabs("Camera IP", "The join didn't report the camera's network. In Settings › Wi-Fi, join the camera's network; then in the Wi-Fi tab set Camera IP (usually 192.168.122.1) and tap Done here.",
                                             timeout: 900) { false }
            if fixed != "Done" { throw GuidedStop("not on the camera's network") }
        }
    }

    /// The tester joined the camera's network in Settings: a TCP connect to the PTP/IP port at the stored camera IP
    /// (then 192.168.122.1, the camera's usual address) says whether the phone is on it. One retry after asking.
    private func findCameraJoinedOutsideApp() async throws {
        let stored = (UserDefaults.standard.string(forKey: "ptpip.host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let usual = "192.168.122.1"
        let hosts = stored.isEmpty || stored == usual ? [usual] : [stored, usual]
        for attempt in 1...2 {
            for host in hosts {
                step("TCP \(host):15740 (network joined outside the app)")
                do {
                    let seconds = try await PTPIPClient.probePort(host: host, timeout: 5, log: PTPIPClient.logger(log))
                    UserDefaults.standard.set(host, forKey: "ptpip.host")
                    log.note("  guided: joined outside the app: \(host):15740 answered in \(fmt(seconds, 2)) s; camera IP set to \(host)")
                    return
                } catch {
                    log.warn("  guided: TCP \(host):15740 failed: \(error)")
                }
            }
            if attempt == 2 { break }
            let retry = try await ask("Not on the camera's network?",
                                      "Nothing answered at \(hosts.joined(separator: " or ")) on port 15740. In Settings › Wi-Fi, join the camera's network (the name and password on the camera's screen), wait for the tick, then come back and tap Try again.",
                                      buttons: ["Try again", "Skip this section"])
            if retry != "Try again" { break }
        }
        throw GuidedStop("not on the camera's network")
    }

    // MARK: - Wi-Fi sections

    func wifiModePass() async throws {
        let mode = try await ask("Camera mode", "Which Wi-Fi mode is the camera in? Set it on the camera now (Network menu).",
                                 buttons: ["Smartphone Connect", "PC Remote (camera's network)", "PC Remote (home Wi-Fi)"])
        step("Wi-Fi mode: \(mode)")
        log.note("◆ Wi-Fi mode under test: \(mode)")
        // PC Remote drops the session unless Sony's init sequence follows OpenSession within 30 s, so connect runs it
        // itself rather than leaving it to a later step.
        let pcRemote = mode.hasPrefix("PC Remote")
        let previousSDIO = wireless.sdioAfterConnect
        wireless.sdioAfterConnect = pcRemote
        defer { wireless.sdioAfterConnect = previousSDIO }
        log.note("  guided: Sony init sequence after connect \(pcRemote ? "on" : "off") for this run")
        try await section("Join and find the camera", "The network, then the camera's IP.") {
            switch mode {
            case "PC Remote (home Wi-Fi)": try await wifiJoin(homeLAN: true)
            case "PC Remote (camera's network)": try await wifiJoin(homeLAN: false)
            default: try await wifiJoin()
            }
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
        try await section("Session and transfers", "Connect, list the card, the shutter on that session, Sony contents transfer if nothing listed, then 50 thumbnails and 20 newest ARW (about 10 min).") {
            let t = wifiTarget()
            try await wifi("Connect + OpenSession + GetDeviceInfo",
                           "The camera may ask you to confirm the connection: accept it on the camera." + (pcRemote ? " Sony's init sequence follows straight away." : ""),
                           timeout: 120) {
                wireless.connect(t)
            }
            if wireless.isConnected, wireless.connectionState.hasPrefix("connected") {
                try await wifi("List card", "GetObjectHandles, then GetObjectInfo for every object.", timeout: 900) { wireless.listCard() }
                // The shutter test belongs on this plain (RemoteControl) session: ObjectAdded is a question about the
                // camera mode, not about a contents-transfer session.
                if wireless.isConnected, wireless.connectionState.hasPrefix("connected") {
                    try await ask("Press the shutter", "Tap Start, then press the shutter twice in the next 20 s.", buttons: ["Start"])
                    try await wifi("Shutter test (20 s)", "Press the shutter twice now.", timeout: 60) { wireless.shutterTest() }
                } else {
                    log.warn("  guided: not connected after List card, so no shutter test: \(wireless.connectionState)")
                }
            } else {
                // Sony's contents transfer opens a connection of its own (SDIO_OpenSession), so PC Remote goes on.
                guard pcRemote else { throw GuidedStop("not connected: \(wireless.connectionState)") }
                log.warn("  guided: plain connect failed (\(wireless.connectionState)), so no plain List card or shutter test; trying Sony's contents transfer anyway")
            }
            if wireless.objects.isEmpty {
                log.note("  guided: the plain session listed nothing; trying Sony's contents transfer")
                try await section("Sony contents transfer: whole card",
                                  "Nothing listed. The app reconnects in Sony's contents-transfer mode for the whole card (SDIO_OpenSession) and lists again. The camera may take up to 2 minutes to index the card.") {
                    try await wifi("Contents transfer: whole card",
                                   "SDIO_OpenSession, Sony's init sequence and the transfer mode, then waiting while the camera indexes the card (up to about 2 minutes).",
                                   timeout: 180) {
                        wireless.connectContentsTransfer(t, mode: .wholeCard)
                    }
                    try await listAfterContentsTransfer("whole card")
                }
            }
            if wireless.objects.isEmpty {
                try await section("Sony contents transfer: photos sent from the camera",
                                  "Still nothing listed. The app reconnects in Sony's contents-transfer mode for photos the camera sends; you send them once it is connected.") {
                    try await ask("Photos sent from the camera", "Tap Start. Once the app says it is connected, choose a couple of photos on the camera and send them to the phone, if the camera offers it in this mode. The app waits up to 90 s for them to list.",
                                  buttons: ["Start"])
                    try await wifi("Contents transfer: photos sent from the camera",
                                   "Reconnecting in Sony's contents-transfer mode. Once it says connected, choose a couple of photos on the camera and send them; the app waits up to 90 s for them to list.",
                                   timeout: 180) {
                        wireless.connectContentsTransfer(t, mode: .selectedOnCamera)
                    }
                    let sent = try await ask("Did the camera send?", "Did the camera offer to send photos in this mode, and did you send some?",
                                             buttons: ["Sent", "Not offered"])
                    log.note("◆ Photos sent from the camera: \(sent == "Sent" ? "chosen and sent" : "not offered in this mode")")
                    try await listAfterContentsTransfer("photos sent from the camera")
                }
            }
            if wireless.objects.isEmpty {
                log.warn("  guided: nothing listed in \(mode), so no thumbnails or downloads")
            } else {
                try await wifi("Thumbnails for 50 newest", "GetThumb for the 50 newest.", timeout: 300) { wireless.thumbnails() }
                try await wifi("GetObject 20 newest ARW", "Downloading 20 ARW, with the battery read before and after.", timeout: 1200) { wireless.downloadARW() }
            }
        }
    }

    /// After a contents-transfer connect: lists the card if the session is up; stops the section if it isn't.
    private func listAfterContentsTransfer(_ what: String) async throws {
        guard wireless.isConnected, wireless.connectionState.hasPrefix("connected") else {
            throw GuidedStop("not connected after the contents transfer (\(what)): \(wireless.connectionState)")
        }
        try await wifi("List card", "GetStorageIDs, GetObjectHandles, then GetObjectInfo for every object.", timeout: 900) { wireless.listCard() }
        log.note("  guided: contents transfer (\(what)): \(wireless.objects.count) objects listed")
    }

    func wifiGUID() async throws {
        try await section("GUID after a power cycle", "Is this phone remembered after the camera restarts, and is a new phone asked to confirm? About 5 minutes.") {
            try await ask("Restart the camera", "Switch the camera off and on, put it back in the same Wi-Fi mode, and wait for its Wi-Fi screen. If the phone doesn't rejoin the camera's network by itself, rejoin it in Settings.",
                          buttons: ["Done"])
            try await waitForCameraPort()
            try await wifi("Reconnect (same GUID)", "Reconnecting as the same phone.", timeout: 120) { wireless.reconnect(wifiTarget()) }
            let reconnected = wireless.isConnected && wireless.connectionState.hasPrefix("connected")
            if !reconnected { log.warn("  guided: the reconnect after the power cycle didn't connect: \(wireless.connectionState)") }
            let same = try await ask("Did the camera ask?", "Did the camera ask you to allow the connection (and did you have to press anything)?",
                                     buttons: ["Yes, I had to allow it", "It showed something, nothing to press", "No, it connected"])
            log.note("◆ Same GUID after a power cycle: \(same)" + (reconnected ? "" : " (the reconnect failed: \(wireless.connectionState))"))
            UserDefaults.standard.set(UUID().uuidString, forKey: "ptpip.guid")
            log.note("PTP/IP: new GUID for the re-pair test (guided run)")
            try await wifi("Connect (new GUID)", "Connecting as a new phone: accept on the camera if it asks.", timeout: 120) { wireless.connect(wifiTarget()) }
            let new = try await ask("Did the camera ask?", "Did the camera ask you to confirm this new phone?",
                                    buttons: ["Yes, it asked", "No, it connected", "It failed"])
            log.note("◆ New GUID: \(new)")
        }
    }

    /// After a camera restart: waits (up to 300 s) until the camera's PTP/IP port answers at the stored camera IP,
    /// trying a 2 s TCP connect every 2 s, while an alert asks the tester to switch the camera's Wi-Fi back on and,
    /// if needed, rejoin its network. Logs how long the camera took to answer and after how many tries.
    private func waitForCameraPort() async throws {
        let host = wifiTarget().host
        let state = PortWait()
        let clock = ContinuousClock()
        let started = clock.now
        step("Waiting for the camera at \(host):15740")
        // Quiet: a refused or timed-out connect every 2 s for up to 5 minutes would bury the log.
        let quiet: PTPIPClient.Logger = { _, _ in }
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                let attemptStarted = clock.now
                state.attempts += 1
                do {
                    _ = try await PTPIPClient.probePort(host: host, timeout: 2, log: quiet)
                    state.answeredAfter = (clock.now - started).inSeconds
                    return
                } catch {
                    state.lastError = "\(error)"
                }
                let wait = 2 - (clock.now - attemptStarted).inSeconds
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
        }
        defer { poller.cancel() }
        let back = try await waitUntil("Switch the camera's Wi-Fi on",
                                       "After a restart the camera's Wi-Fi is off: switch it back on in PC Remote. If the phone moved to your home Wi-Fi, join the camera's network again in Settings › Wi-Fi.",
                                       timeout: 300) { state.answeredAfter != nil }
        if back, let after = state.answeredAfter {
            log.note("  guided: the camera answered at \(host):15740 \(fmt(after)) s after the restart was confirmed (\(state.attempts) TCP connect(s), 2 s timeout each)")
            return
        }
        log.warn("  guided: nothing answered at \(host):15740 within 300 s (\(state.attempts) TCP connect(s); last: \(state.lastError))")
        let choice = try await ask("The camera didn't answer", "Nothing answered at \(host) on port 15740 for 5 minutes. Check that the camera's Wi-Fi is on in PC Remote and that the phone is on the camera's network, then try the reconnect anyway, or stop this section.",
                                   buttons: ["Reconnect anyway", "Stop"])
        if choice != "Reconnect anyway" { throw GuidedStop("the camera didn't answer at \(host):15740 after the restart") }
    }

    func wifiResume() async throws {
        try await section("Resume after Wi-Fi off", "The partial read probe if it hasn't run on this network in this kind of session, a reference download, then a read that pauses at 50 % for you to turn Wi-Fi off and on, then the resume. About 5–8 minutes.") {
            guard wireless.isConnected else { throw GuidedStop("connect first (Wi-Fi: one camera mode)") }
            if wireless.objects.isEmpty {
                try await wifi("List card", "The resume needs the card listed.", timeout: 900) { wireless.listCard() }
            }
            // Which byte-range layout works on this network, unless a probe has already said: on 2 Nov the camera
            // answered the standard GetPartialObject InvalidObjectHandle in the whole-card contents transfer.
            let net = wireless.sessionNet ?? wifiTarget().net
            // Remembered per kind of session too: the refusal was seen in the whole-card contents transfer only.
            let session = wireless.partialProbeSession
            if PartialReadProbe.remembered(net: net, session: session) == .notProbed {
                // 600 s: up to three layouts may each wait 15 s and reconnect, and a reconnect means listing the card again.
                try await wifi("Partial read probe",
                               "GetObject of the newest ARW as a reference, then a 1 MiB byte-range read with each layout the camera lists. A layout the camera doesn't understand may get no answer: the app then waits 15 s, reconnects and tries the next, and lists the card again at the end.",
                               timeout: 600) { wireless.probePartialReads() }
            }
            let probe = PartialReadProbe.remembered(net: net, session: session)
            log.note("  guided: byte-range reads on \(net) in a \(session) session: \(probe.label)")
            switch probe {
            case .notProbed:
                throw GuidedStop("the partial read probe didn't finish (see the log); run Partial read probe on the Wi-Fi tab")
            case .noneWorks:
                try await ask("Skip the Wi-Fi-off part",
                              "The camera refuses byte-range reads in this mode, so a file interrupted by a drop has to restart from the beginning: there is nothing to resume. Don't turn Wi-Fi off; this section ends here.",
                              buttons: ["OK"])
                log.note("◆ Resume after Wi-Fi off: not run, no byte-range read works on \(net) in a \(session) session")
                return
            case .works:
                break
            }
            // A reconnect during the probe starts a session with an empty listing; the probe lists again, but not if
            // that failed.
            guard wireless.isConnected else { throw GuidedStop("the connection was lost during the partial read probe (see the log); connect again and rerun this section") }
            if wireless.objects.isEmpty {
                try await wifi("List card", "The probe reconnected, and the resume needs the card listed again.", timeout: 900) { wireless.listCard() }
            }
            if wireless.objects.isEmpty { throw GuidedStop("the card isn't listed after the partial read probe (see the log)") }
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

    func wifiLock() async throws {
        try await section("Lock during a Wi-Fi transfer", "Needs a connected session with the card listed (Wi-Fi: one camera mode). About 8 minutes.") {
            guard wireless.isConnected else { throw GuidedStop("connect first (Wi-Fi: one camera mode)") }
            if wireless.objects.isEmpty {
                try await wifi("List card", "The transfer needs the card listed.", timeout: 900) { wireless.listCard() }
            }
            guard wireless.objects.contains(where: { $0.info.filename.uppercased().hasSuffix(".ARW") }) else {
                throw GuidedStop("no ARW listed on the card")
            }
            try await ask("Plain transfer, phone locked", "Tap Start, then lock the phone within 10 s and leave it locked about 2 minutes.", buttons: ["Start"])
            var returns = lifecycle.foregroundReturns
            step("GetObject 20 newest ARW, phone locked")
            wireless.downloadARW()
            try await waitUntil("Lock the phone now", "Lock the phone. Unlock after about 2 minutes.", timeout: 1200) {
                self.lifecycle.foregroundReturns > returns || !self.wireless.busy
            }
            try await waitUntil("Finishing the transfer", "Waiting for it to end or fail.", timeout: 1200) { !self.wireless.busy }

            // Two minutes locked has likely ended the PTP/IP session: start the second half on a fresh one.
            try await ask("Reconnect", "Make sure the phone is back on the camera's network (Settings › Wi-Fi), then tap OK to reconnect.", buttons: ["OK"])
            try await wifi("Reconnect (same GUID)", "Reconnecting before the continued task.", timeout: 120) { wireless.reconnect(wifiTarget()) }
            guard wireless.isConnected, wireless.connectionState.hasPrefix("connected") else {
                throw GuidedStop("couldn't reconnect: \(wireless.connectionState)")
            }
            try await wifi("List card", "The continued task needs the card listed again.", timeout: 900) { wireless.listCard() }

            try await ask("Continued task, phone locked", "Tap Start, then lock the phone once the import shows on the Lock Screen or in the Dynamic Island; unlock after about 2 minutes.",
                          buttons: ["Start"])
            returns = lifecycle.foregroundReturns
            step("Continued task: 20 ARW over Wi-Fi, phone locked")
            try await startContinued("The Wi-Fi continued task") { wireless.downloadARWContinued() }
            try await waitUntil("Lock the phone now", "Lock the phone. Unlock after about 2 minutes.", timeout: 1200) {
                self.lifecycle.foregroundReturns > returns || !self.continued.isRunning
            }
            try await waitUntil("Finishing the continued task", "Waiting for it to end.", timeout: 1200) { !self.continued.isRunning }
        }
    }

    func wifiSendToSmartphone() async throws {
        try await section("Send to Smartphone", "If PTP/IP browsing fails, 1.0's wireless path is the camera's own Send to Smartphone. Does our app see the photos the camera sends? About 5 minutes.") {
            let chosen = try await ask("Choose photos on the camera", "On the camera: Playback, then the Send to Smartphone function (Select on This Device or Select on Camera & Send). Choose 2 photos and start sending, so the camera waits for a phone. How many did you choose?",
                                       buttons: ["1", "2", "3", "More"])
            try await wifiJoin()
            let t = wifiTarget()
            try await wifi("Connect + OpenSession + GetDeviceInfo", "Connecting as the camera waits to send.", timeout: 120) { wireless.connect(t) }
            guard wireless.isConnected, wireless.connectionState.hasPrefix("connected") else {
                log.flag("\(t.prefix).sendToSmartphone.connects", false, context: "Send to Smartphone: \(wireless.connectionState)")
                throw GuidedStop("the app couldn't open a PTP/IP session while the camera was sending")
            }
            log.flag("\(t.prefix).sendToSmartphone.connects", true, context: "Send to Smartphone: a PTP/IP session opened")
            var listStarted = Date()
            try await wifi("List card", "Listing what the camera offers.", timeout: 600) { wireless.listCard() }
            var listed = log.measurements.contains(where: { $0.at >= listStarted && $0.name == "\(t.prefix).objects" })
            if wireless.objects.isEmpty {
                log.note("  guided: Send to Smartphone: the plain session listed nothing; trying Sony's selected-set mode on the same session")
                // The camera is sending into this session, so it stays open: no reconnect.
                try await wifi("Selected set in this session", "Sony's init sequence if needed, 0x9212 [1,0,0], then waiting up to 90 s for the photos the camera sends.",
                               timeout: 180) {
                    wireless.selectedSetInSession()
                }
                if wireless.isConnected, wireless.connectionState.hasPrefix("connected") {
                    listStarted = Date()
                    try await wifi("List card", "Listing what the camera offers in contents-transfer mode.", timeout: 600) { wireless.listCard() }
                    listed = listed || log.measurements.contains(where: { $0.at >= listStarted && $0.name == "\(t.prefix).objects" })
                } else {
                    log.warn("  guided: Send to Smartphone: not connected after the selected-set mode: \(wireless.connectionState)")
                }
            }
            guard listed else {
                throw GuidedStop("the listing failed (see the log), so it says nothing about what Send to Smartphone offers")
            }
            let names = wireless.objects.map { $0.info.filename }
            log.note("◆ Send to Smartphone: listed \(names.count) objects (\(chosen) chosen on the camera): \(names.prefix(10).joined(separator: ", "))")
            if !names.isEmpty {
                try await wifi("Thumbnails", "GetThumb for what was listed.", timeout: 300) { wireless.thumbnails() }
                if names.contains(where: { $0.uppercased().hasSuffix(".ARW") }) {
                    try await wifi("GetObject newest ARW", "Downloading the ARW listed (up to 20), for the fallback path's throughput.", timeout: 1200) {
                        wireless.downloadARW()
                    }
                } else {
                    log.note("  guided: Send to Smartphone: no ARW listed, so no download throughput")
                }
            }
            let same = try await ask("The chosen photos?", "Listed \(names.count): \(names.prefix(8).joined(separator: ", "))\(names.count > 8 ? ", …" : ""). Are these the photos you chose on the camera (a RAW+JPEG pair counts as one)?",
                                     buttons: ["Yes, just those", "More than those", "Not those"])
            log.flag("\(t.prefix).sendToSmartphone.listsSelection", same == "Yes, just those",
                     context: "listed \(names.count) objects with \(chosen) chosen on the camera; tester: \(same)")
            let camera = try await ask("On the camera", "What does the camera show now?", buttons: ["Sent / complete", "Still waiting", "An error"])
            log.note("◆ Send to Smartphone: camera shows \(camera)")
        }
    }

    // MARK: - Bluetooth sections

    /// One 30 s scan and snapshot; returns the service UUIDs camera-like devices advertised in it.
    @discardableResult
    private func scan(power: AdvertisementScanner.PowerState, pairing: AdvertisementScanner.PairingContext,
                      instructions: String) async throws -> [String] {
        let go = try await ask("Camera \(power.rawValue), \(pairing.rawValue)", instructions, buttons: ["Ready", "Skip this state"])
        guard go == "Ready" else { return [] }
        scanner.log = log
        scanner.start(sonyOnly: true)
        let started = try await waitUntil("Starting the scan", "Allow Bluetooth if iOS asks.", timeout: 30) { self.scanner.isScanning }
        if !started { throw GuidedStop("Bluetooth scanning didn't start (\(scanner.state))") }
        try await waitUntil("Scanning for 30 s", "Camera \(power.rawValue); leave it as it is.", timeout: 32) {
            guard let since = self.scanner.scanStartedAt else { return false }
            return Date().timeIntervalSince(since) >= 30
        }
        scanner.stop()
        let candidates = scanner.candidateServiceUUIDs
        let uuid = UserDefaults.standard.string(forKey: ProximityWatcher.Keys.serviceUUID) ?? ""
        scanner.saveSnapshot(power: power, pairing: pairing, proximityUUID: uuid.isEmpty ? nil : uuid)
        return candidates
    }

    func bleAdverts() async throws {
        // The reminder has to work while Creators' App is quit, so that scan's UUIDs come first.
        var seenWhileOn: [String] = []
        var seenConnected: [String] = []
        try await section("Advertisements by power state",
                          "Creators' App paired but quit (the usual state for our users), then one run with it connected. 30 s scans, about 15 minutes.") {
            seenWhileOn = try await scan(power: .on, pairing: .unlinked, instructions: "Quit Creators' App (swipe it away). Camera switched on.")
            try await scan(power: .asleep, pairing: .unlinked, instructions: "Let the camera go to sleep (power save), Creators' App still quit.")
            try await scan(power: .off, pairing: .unlinked, instructions: "Switch the camera off, Creators' App still quit.")
            seenConnected = try await scan(power: .on, pairing: .connected, instructions: "Switch the camera on and open Creators' App until it shows the camera connected.")
            try await scan(power: .on, pairing: .unpaired, instructions: "Only if you're happy to pair again later: remove the camera in Creators' App and in the camera's Bluetooth settings. Otherwise skip.")
        }
        try await section("Proximity filter UUID", "Pick the service UUID the background watch filters on.") {
            let candidates = seenWhileOn + seenConnected.filter { !seenWhileOn.contains($0) }
            guard !candidates.isEmpty else {
                throw GuidedStop("no service UUID advertised by a camera-like device; background scanning needs an advertised one")
            }
            let choice = try await ask("Filter UUID", "Advertised by the camera with Creators' App quit: \(seenWhileOn.isEmpty ? "none" : seenWhileOn.joined(separator: ", ")); while connected: \(seenConnected.isEmpty ? "none" : seenConnected.joined(separator: ", ")). Use which one?",
                                       buttons: Array(candidates.prefix(3)) + ["None of them"])
            if candidates.contains(choice) {
                UserDefaults.standard.set(choice, forKey: ProximityWatcher.Keys.serviceUUID)
                proximity.serviceUUIDChanged()
                log.note("◆ Proximity filter UUID set to \(choice)")
            }
        }
    }

    func bleProximity() async throws {
        try await section("Proximity reminder", "Background watch on; the scan starts once the phone is locked, with the camera already nearby, on or off. Same room, then next room. About 10 minutes.") {
            guard proximity.storedServiceUUID != nil else { throw GuidedStop("no filter UUID yet: run Bluetooth: what the camera advertises") }
            if !proximity.enabled {
                proximity.setEnabled(true)
                try await waitUntil("Starting the background watch", "Allow notifications and Bluetooth if iOS asks.", timeout: 60) {
                    self.proximity.isScanning
                }
            }
            for room in ["same room", "next room"] {
                try await ask("Camera in the \(room)",
                              "Put the camera in the \(room), on or off (it advertises either way). Then tap Start and lock the phone. The scan starts when the app leaves the screen. Wait up to 2 minutes for a reminder, then unlock.",
                              buttons: ["Start"])
                let returns = lifecycle.foregroundReturns
                proximity.armOnNextBackground()
                let left: Bool
                do {
                    left = try await waitUntil("Lock the phone now", "Lock the phone. The scan starts when the app leaves the screen. Unlock after the reminder, or after 2 minutes.",
                                               timeout: 600) { self.lifecycle.foregroundReturns > returns }
                } catch {
                    proximity.disarmBackgroundScan()
                    throw error
                }
                // Never left the screen: don't leave the scan armed for some later, unrelated background entry.
                if !left { proximity.disarmBackgroundScan() }
                let seen = try await ask("Reminder?", "Did a reminder arrive while the phone was locked (\(room))?",
                                         buttons: ["Yes", "No"])
                log.flag("ble.proximity.reminder.\(room == "same room" ? "sameRoom" : "nextRoom")", seen == "Yes",
                         context: "scan started after the lock, \(room)")
            }
        }
    }
}
