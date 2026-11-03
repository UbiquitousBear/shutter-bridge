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

/// The result of a Bluetooth handover call run under a waiting alert (GuidedRunner.bluetooth): set by its task,
/// read by the alert's condition, both on the main actor.
@MainActor
private final class HandoverCall<T> {
    var result: Result<T, Error>?
}

/// What GuidedRunner.joinCameraOverBluetooth did: whether the phone is on the camera's network, and if it isn't, why
/// in a few words (for the fallback step's message).
private struct BluetoothJoin {
    let joined: Bool
    let reason: String
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
        GuidedScript(id: "copy.all", group: "Copy to Files", title: "Copy all RAW to Files",
                     summary: "Every ARW on the card into a new folder in Files, over USB-C or Wi-Fi, phone locked if you like (400 RAW, 10–25 GB: about 5–12 min on the cable, 10–35 min on Wi-Fi).") { r in try await r.copyAllToFiles() },

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
        GuidedScript(id: "ble.handover", group: "Bluetooth (session S3)", title: "Bluetooth: Wi-Fi handover",
                     summary: "Subscribe as Sony's app does, switch the camera's Wi-Fi on over Bluetooth (a second try with every notification on, then optionally watch Creators' App do it), read its network details (never logged), join, import one file (about 15–20 min).") { r in try await r.bleHandover() },
        GuidedScript(id: "ble.watch", group: "Bluetooth (session S3)", title: "Bluetooth: watch Creators' App switch Wi-Fi on",
                     summary: "Every notification of the camera's 8000CC00 service on, then record what the camera reports while Creators' App imports and after it is quit; no CC08 write (about 10 min).") { r in try await r.bleWatch() },
        GuidedScript(id: "ble.join", group: "Bluetooth (session S3)", title: "Bluetooth: join with the camera's Wi-Fi on",
                     summary: "The 1.0 fallback: with PC Remote's network up, read its details over Bluetooth (never logged), join, import the newest ARW, timed from Start; nothing written to the camera (about 10 min).") { r in try await r.bleJoin() },
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

    /// Network, join and camera IP: on the camera's access point a join over Bluetooth first
    /// (joinCameraOverBluetooth), then the QR code or Settings if that didn't work; on the home LAN the IP.
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
        // The camera's network: over Bluetooth first; the QR code or Settings only if that didn't work.
        let viaBluetooth = try await joinCameraOverBluetooth(context: homeLAN == nil ? "Wi-Fi run, camera access point chosen"
                                                                                     : "Wi-Fi run, camera's network (from the camera mode)")
        if viaBluetooth.joined { return }
        let scans = wireless.qrScans
        // The SSID from an earlier scan stays in memory for the whole launch: only a new scan (or a newly typed
        // SSID) means the app should join; Done with nothing new means the tester joined in Settings.
        let ssidBefore = wireless.joinSSID
        let scanned = try await waitInTabs("Join the camera's network",
                                           "Joining over Bluetooth didn't work (\(viaBluetooth.reason)). On the camera, open the screen with its QR code (Smartphone Connect) or its network name and password (PC Remote over Wi-Fi Direct). Scan the code on the Wi-Fi tab, or join the camera's network in Settings › Wi-Fi, then tap Done here.",
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
    /// `bluetoothFailure`: why the join over Bluetooth just before didn't work, to start the question with.
    private func findCameraJoinedOutsideApp(bluetoothFailure: String? = nil) async throws {
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
                                      (bluetoothFailure.map { "Joining over Bluetooth didn't work (\($0)). " } ?? "")
                                        + "Nothing answered at \(hosts.joined(separator: " or ")) on port 15740. In Settings › Wi-Fi, join the camera's network (the name and password on the camera's screen), wait for the tick, then come back and tap Try again.",
                                      buttons: ["Try again", "Skip this section"])
            if retry != "Try again" { break }
        }
        throw GuidedStop("not on the camera's network")
    }

    /// Gets the phone onto the camera's own network without the QR code or Settings. If the camera already answers a
    /// 2 s TCP connect at 192.168.122.1:15740 (or the stored camera IP), that is noted and the camera IP set, with no
    /// Bluetooth and nothing recorded. Otherwise: connect and list the services over Bluetooth, read the network name
    /// and password (CC06, CC07; no subscriptions, no CC08 write, nothing written to the camera), join with them
    /// (NEHotspotConfiguration, one iOS prompt), wait up to 60 s for the camera at 192.168.122.1:15740, set Camera AP
    /// and that camera IP, and disconnect Bluetooth. The details exist only in this call and reach the log only as
    /// `HandoverCredentials.description` and HotspotJoiner's redacted lines. Records `ptpip.ap.bluetoothJoin` (yes:
    /// on the camera's network through the details read over Bluetooth) and, on success,
    /// `ptpip.ap.bluetoothJoin.toCameraPort` [s] from this call's start to the camera answering, both only when apply
    /// really joined (an "already associated" answer means iOS had put the phone on the network itself: noted, not
    /// recorded). A Bluetooth or join failure (camera not found, no network set up on the camera, join failed, no
    /// answer at the port) is logged, Bluetooth is disconnected (only a link this call connected) and the result says
    /// why in a few words, so the caller can fall back; "Cancel run" still throws. `waitFirst` (seconds): first give
    /// iOS that long to rejoin the camera's network by itself, polling 192.168.122.1:15740 under a waiting alert (after
    /// a camera restart or a long lock). A Bluetooth operation already running (the Bluetooth tab's) is waited for up
    /// to 60 s; if it doesn't end, the result is a fallback with nothing recorded.
    private func joinCameraOverBluetooth(context: String, waitFirst: Double = 0) async throws -> BluetoothJoin {
        let clock = ContinuousClock()
        let started = clock.now
        let usual = "192.168.122.1"

        // Give iOS time to rejoin a known network by itself before the Bluetooth join.
        if waitFirst > 0 {
            step("Waiting for the phone to rejoin the camera's network (TCP \(usual):15740, up to \(Int(waitFirst)) s)")
            let rejoin = try await pollCameraPort(host: usual, title: "Waiting for the camera's network",
                                                  message: "Giving iOS up to \(Int(waitFirst)) s to rejoin the camera's network by itself; if it doesn't, the app joins it over Bluetooth.",
                                                  timeout: waitFirst)
            if let after = rejoin.answeredAfter {
                UserDefaults.standard.set(usual, forKey: "ptpip.host")
                log.note("  guided: \(context): the phone rejoined the camera's network by itself: \(usual):15740 answered after \(fmt(after)) s (\(rejoin.attempts) TCP connect(s)); camera IP set to \(usual); no Bluetooth join needed")
                return BluetoothJoin(joined: true, reason: "")
            }
            log.note("  guided: \(context): nothing answered at \(usual):15740 within \(Int(waitFirst)) s (\(rejoin.attempts) TCP connect(s); last: \(rejoin.lastError))")
        }

        // Already on the camera's network (joined earlier, or rejoined by itself)?
        let stored = (UserDefaults.standard.string(forKey: "ptpip.host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = stored.isEmpty || stored == usual ? [usual] : [usual, stored]
        step("Is the phone on the camera's network? (TCP \(hosts.joined(separator: " or ")):15740)")
        // Quiet: a refused or timed-out connect here is the expected case, and the note below says so.
        let quiet: PTPIPClient.Logger = { _, _ in }
        for host in hosts {
            if let seconds = try? await PTPIPClient.probePort(host: host, timeout: 2, log: quiet) {
                UserDefaults.standard.set(host, forKey: "ptpip.host")
                log.note("  guided: \(context): already on the camera's network: \(host):15740 answered in \(fmt(seconds, 2)) s; camera IP set to \(host); no Bluetooth join needed")
                return BluetoothJoin(joined: true, reason: "")
            }
        }
        let checkSeconds = (clock.now - started).inSeconds
        log.note("  guided: \(context): nothing answered at \(hosts.joined(separator: " or ")):15740 (2 s each); joining the camera's network over Bluetooth")

        // A Bluetooth-tab operation still running would refuse Connect: wait for it rather than record a failed join.
        if handover.busy {
            let free = try await waitUntil("Waiting for Bluetooth", "Another Bluetooth operation (Bluetooth tab) is running; waiting up to 60 s for it to finish before joining the camera's network over Bluetooth.",
                                           timeout: 60) { !self.handover.busy }
            if !free {
                log.warn("  guided: \(context): another Bluetooth operation was still running after 60 s; no join over Bluetooth, ptpip.ap.bluetoothJoin not recorded")
                return BluetoothJoin(joined: false, reason: "another Bluetooth operation was running")
            }
        }
        // Only a link this call connects is dropped at the end; one the Bluetooth tab holds is left as it is.
        let ownLink = !handover.isConnected

        // How far it got, for the fallback's message; the log gets the full reason.
        var short = "the camera wasn't found over Bluetooth"
        var joinText = "no join attempted"
        do {
            _ = try await connectHandover(record: nil) { short = "the camera's Bluetooth services couldn't be listed" }
            // The network name and password: only in this scope.
            let details: HandoverCredentials
            do {
                details = try await bluetooth("Reading the network details", "Reading the camera's network name and password over Bluetooth. They are never shown or logged; nothing is written to the camera.",
                                              timeout: 60, detail: false) { try await self.handover.readCredentials(record: nil) }
            } catch let stop as GuidedStop {
                // With the link still up the read itself failed: the camera answers ATT error 0x9D when no network
                // is set up on it.
                short = handover.isConnected ? "no Wi-Fi network is set up on the camera" : "the network details read didn't finish"
                throw stop
            }
            log.note("  guided: \(context): network details read over Bluetooth: \(details.description)")
            guard !details.ssid.isEmpty, HandoverCredentials.isValidPassphrase(details.passphrase) else {
                short = "the network details read over Bluetooth aren't usable"
                throw GuidedStop("the network details read over Bluetooth aren't usable (\(details.description))")
            }
            short = "the join didn't work"
            try await wifi("Join the camera's network", "Joining with the details read over Bluetooth. Accept the system prompt if iOS asks.", timeout: 90) {
                wireless.joinHandover(ssid: details.ssid, passphrase: details.passphrase, source: "Bluetooth join, \(context)")
            }
            let already = wireless.lastJoinAlreadyAssociated
            joinText = joinOutcome(already)
            guard already != nil else { throw GuidedStop("the join failed (see the log)") }
            let host = usual
            if let gateway = wireless.lastJoinGateway, gateway != host {
                log.warn("  guided: \(context): the join reported gateway \(gateway), not \(host); waiting at \(host) anyway")
            }
            short = "the camera didn't answer on its network"
            step("Waiting for the camera at \(host):15740")
            let port = try await pollCameraPort(host: host, title: "Waiting for the camera",
                                                message: "Waiting for the camera to answer at \(host):15740 on its own network (up to 60 s).",
                                                timeout: 60)
            guard let after = port.answeredAfter else {
                throw GuidedStop("nothing answered at \(host):15740 within 60 s of the join (\(port.attempts) TCP connect(s); last: \(port.lastError))")
            }
            UserDefaults.standard.set("ap", forKey: "ptpip.net")
            UserDefaults.standard.set(host, forKey: "ptpip.host")
            let total = (clock.now - started).inSeconds
            if already == true {
                // iOS had already put the phone on the camera's network (after the check above): the details read over
                // Bluetooth didn't get it there, so neither name is recorded.
                log.note("  guided: \(context): apply answered already associated: iOS had rejoined the camera's network by itself after the \(fmt(checkSeconds)) s check; \(host):15740 answered \(fmt(after)) s later; network Camera AP, camera IP set to \(host); ptpip.ap.bluetoothJoin and its time not recorded")
            } else {
                log.note("  guided: \(context): on the camera's network over Bluetooth: \(host):15740 answered \(fmt(after)) s after the join, \(fmt(total)) s after the start; network Camera AP, camera IP set to \(host)")
                log.flag("ptpip.ap.bluetoothJoin", true,
                         context: "\(context); details read over Bluetooth (\(details.description)); \(joinText); the camera answered at \(host):15740 \(fmt(after)) s after the join")
                log.measure("ptpip.ap.bluetoothJoin.toCameraPort", total, "s",
                            context: "\(context); from the start of the join over Bluetooth (including the \(fmt(checkSeconds)) s check for the camera on the current network and any tap on iOS's join prompt) to the camera answering at \(host):15740; \(joinText)")
            }
        } catch let stop as GuidedStop {
            log.warn("  guided: \(context): joining over Bluetooth didn't work: \(stop.reason); falling back to the QR code or Settings")
            log.flag("ptpip.ap.bluetoothJoin", false, context: "\(context); \(joinText); \(stop.reason)")
            disconnectAfterBluetoothJoin(ownLink: ownLink)
            return BluetoothJoin(joined: false, reason: short)
        } catch {
            // "Cancel run" (or anything else unexpected): Bluetooth off, then let it end the run.
            disconnectAfterBluetoothJoin(ownLink: ownLink)
            throw error
        }
        disconnectAfterBluetoothJoin(ownLink: ownLink)
        return BluetoothJoin(joined: true, reason: "")
    }

    /// Bluetooth off after joinCameraOverBluetooth, unless the link is already down and nothing is running, or the
    /// link was up before the join (`ownLink` false: the Bluetooth tab's), which is left as it is.
    private func disconnectAfterBluetoothJoin(ownLink: Bool) {
        guard handover.isConnected || handover.busy else { return }
        guard ownLink else {
            log.note("  guided: the Bluetooth link was up before the join (Bluetooth tab), so it is left connected; the network details are dropped")
            return
        }
        handover.disconnect()
        log.note("  guided: Bluetooth disconnected (\(handover.status)); the network details are dropped")
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
            let onCameraAP = wifiTarget().net == "ap"
            try await ask("Restart the camera", "Switch the camera off and on, put it back in the same Wi-Fi mode, and wait for its Wi-Fi screen. "
                            + (onCameraAP ? "If the phone doesn't rejoin the camera's network by itself within about 15 s, the app joins it over Bluetooth."
                                          : "If the phone doesn't rejoin the camera's network by itself, rejoin it in Settings."),
                          buttons: ["Done"])
            // On the camera's network: rejoin over Bluetooth first; the wait below then answers at once.
            var bluetoothFailure: String?
            if onCameraAP {
                let viaBluetooth = try await joinCameraOverBluetooth(context: "Wi-Fi GUID run, after the camera restart", waitFirst: 15)
                if !viaBluetooth.joined { bluetoothFailure = viaBluetooth.reason }
            }
            try await waitForCameraPort(bluetoothFailure: bluetoothFailure)
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
    /// `bluetoothFailure`: why the join over Bluetooth just before didn't work, to start the alert's message with.
    private func waitForCameraPort(bluetoothFailure: String? = nil) async throws {
        let host = wifiTarget().host
        step("Waiting for the camera at \(host):15740")
        let state = try await pollCameraPort(host: host, title: "Switch the camera's Wi-Fi on",
                                             message: (bluetoothFailure.map { "Joining over Bluetooth didn't work (\($0)). " } ?? "")
                                                + "After a restart the camera's Wi-Fi is off: switch it back on in PC Remote. If the phone moved to your home Wi-Fi, join the camera's network again in Settings › Wi-Fi.",
                                             timeout: 300)
        if let after = state.answeredAfter {
            log.note("  guided: the camera answered at \(host):15740 \(fmt(after)) s after the restart was confirmed (\(state.attempts) TCP connect(s), 2 s timeout each)")
            return
        }
        log.warn("  guided: nothing answered at \(host):15740 within 300 s (\(state.attempts) TCP connect(s); last: \(state.lastError))")
        let choice = try await ask("The camera didn't answer", "Nothing answered at \(host) on port 15740 for 5 minutes. Check that the camera's Wi-Fi is on in PC Remote and that the phone is on the camera's network, then try the reconnect anyway, or stop this section.",
                                   buttons: ["Reconnect anyway", "Stop"])
        if choice != "Reconnect anyway" { throw GuidedStop("the camera didn't answer at \(host):15740 after the restart") }
    }

    /// Tries a 2 s TCP connect to `host`:15740 every 2 s under a waiting alert (`title`, `message`) until one
    /// succeeds or `timeout` seconds pass. Logs nothing itself; the result says how long and how many tries.
    private func pollCameraPort(host: String, title: String, message: String, timeout: Double) async throws -> PortWait {
        let state = PortWait()
        let clock = ContinuousClock()
        let started = clock.now
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
        try await waitUntil(title, message, timeout: timeout) { state.answeredAfter != nil }
        return state
    }

    /// The Wi-Fi runs after *Wi-Fi: one camera mode* need a session, and a new build (or any app restart) leaves
    /// none (2 Nov, 23:07: resume stopped at "connect first"). Opens one if the camera answers: Sony's whole-card
    /// contents transfer (PC Remote), else a plain session. `joined`: the caller has just put the phone on the
    /// network (wifiJoin), so the join and the probes are skipped.
    private func ensureWiFiSession(joined: Bool = false) async throws {
        guard !wireless.isConnected else { return }
        log.note("  guided: no Wi-Fi session (the app restarted?); opening one")
        // On the camera's network: over Bluetooth first, then the probes and the question about Settings. The home
        // LAN keeps the probes alone (the camera's own network has nothing to do with it).
        if !joined {
            var onCameraNetwork = false
            var bluetoothFailure: String?
            if wifiTarget().net == "ap" {
                let viaBluetooth = try await joinCameraOverBluetooth(context: "no Wi-Fi session, opening one")
                onCameraNetwork = viaBluetooth.joined
                if !viaBluetooth.joined { bluetoothFailure = viaBluetooth.reason }
            }
            if !onCameraNetwork { try await findCameraJoinedOutsideApp(bluetoothFailure: bluetoothFailure) }
        }
        try await wifi("Contents transfer: whole card", "Opening Sony's whole-card session (PC Remote) on the camera's network.", timeout: 180) {
            wireless.connectContentsTransfer(wifiTarget(), mode: .wholeCard)
        }
        if !wireless.isConnected {
            try await wifi("Connect", "The whole-card session didn't open; trying a plain session.", timeout: 120) {
                wireless.connect(wifiTarget())
            }
        }
        guard wireless.isConnected else { throw GuidedStop("couldn't open a Wi-Fi session with the camera (see the log)") }
    }

    func wifiResume() async throws {
        try await section("Resume after Wi-Fi off", "The partial read probe if it hasn't run on this network in this kind of session, a reference download, then a read that pauses at 50 % for you to turn Wi-Fi off and on, then the resume. About 5–8 minutes.") {
            try await ensureWiFiSession()
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
        try await section("Lock during a Wi-Fi transfer", "Opens a session and lists the card if needed (phone on the camera's network). About 8 minutes.") {
            try await ensureWiFiSession()
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

            // Two minutes locked has likely ended the PTP/IP session: start the second half on a fresh one. On the
            // camera's network the app rejoins over Bluetooth first if the phone isn't on it; Settings otherwise.
            var rejoined = false
            var bluetoothFailure: String?
            if wifiTarget().net == "ap" {
                let viaBluetooth = try await joinCameraOverBluetooth(context: "Wi-Fi lock run, before the reconnect", waitFirst: 15)
                rejoined = viaBluetooth.joined
                if !rejoined { bluetoothFailure = viaBluetooth.reason }
            }
            if !rejoined {
                try await ask("Reconnect", (bluetoothFailure.map { "Joining over Bluetooth didn't work (\($0)). " } ?? "")
                                + "Make sure the phone is back on the camera's network (Settings › Wi-Fi), then tap OK to reconnect.",
                              buttons: ["OK"])
            }
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
        let candidates = scanner.advertisedServiceUUIDs
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

    // MARK: - Bluetooth: Wi-Fi handover

    /// Runs one SonyWiFiHandover call under a waiting alert and returns its result. A throw, or no answer within
    /// `timeout`, stops the section (and disconnects Bluetooth on a timeout); "Cancel run" disconnects too.
    /// `detail` false leaves the error's text out of the stop reason (the credentials read).
    private func bluetooth<T>(_ title: String, _ message: String, timeout: Double, detail: Bool = true,
                              _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        step(title)
        let call = HandoverCall<T>()
        let task = Task { @MainActor in
            do {
                call.result = .success(try await work())
            } catch {
                call.result = .failure(error)
            }
        }
        let finished: Bool
        do {
            finished = try await waitUntil(title, message, timeout: timeout) { call.result != nil }
        } catch {
            task.cancel()
            handover.disconnect()
            throw error
        }
        guard finished, let result = call.result else {
            task.cancel()
            handover.disconnect()
            throw GuidedStop("\(title): no answer within \(Int(timeout)) s (Bluetooth: \(handover.status))")
        }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw GuidedStop(detail ? "\(title) failed: \(error)" : "\(title) failed (\(type(of: error)); details left out of the log)")
        }
    }

    /// Connects over Bluetooth and lists the camera's services (the section stops without 8000CC00); `connected`
    /// runs as soon as the link is up, so a run knows it reached the camera even if the listing fails. `record`: the
    /// prefix the listing is recorded under (`<record>.services`, `<record>.cameraControl`), nil for none.
    private func connectHandover(record: String? = "ble.handover", _ connected: () -> Void) async throws -> HandoverInventory {
        // Connect's own worst case: 30 s for Bluetooth power, 20 s per route tried, a 10 s scan.
        let name = try await bluetooth("Connecting over Bluetooth", "Finding the camera and connecting (up to about a minute). Allow Bluetooth if iOS asks.",
                                       timeout: 120) { try await self.handover.connect(timeout: 20) }
        connected()
        log.note("  guided: Bluetooth connected: \(name)")
        let inventory = try await bluetooth("Listing services", "Discovering the camera's services and characteristics.",
                                            timeout: 45) { try await self.handover.discover(record: record) }
        let found = inventory.found.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value ? "yes" : "no")" }.joined(separator: ", ")
        log.note("  guided: Bluetooth inventory: services \(inventory.services); characteristics \(inventory.characteristics); 8000CC00 \(inventory.hasCameraControl ? "present" : "absent"); found: \(found.isEmpty ? "none" : found); can notify: \(inventory.notifiable.isEmpty ? "none" : inventory.notifiable.joined(separator: ", "))")
        guard inventory.hasCameraControl else { throw GuidedStop("no 8000CC00 service") }
        return inventory
    }

    /// Reconnects and lists the services again when the Bluetooth link is down (the camera may drop it after the
    /// CC08 write, or while another app is in front). Subscriptions don't carry over to the new link.
    private func ensureHandoverLink(_ when: String) async throws {
        guard !handover.isConnected else { return }
        log.note("  guided: the Bluetooth link is down \(when); reconnecting")
        _ = try await bluetooth("Reconnecting over Bluetooth", "The Bluetooth link dropped; connecting again (up to about a minute).",
                                timeout: 120) { try await self.handover.connect(timeout: 20) }
        let again = try await bluetooth("Listing services again", "Discovering the camera's services and characteristics.",
                                        timeout: 45) { try await self.handover.discover() }
        guard again.hasCameraControl else { throw GuidedStop("no 8000CC00 service after reconnecting") }
    }

    /// At the start of a Bluetooth run: a link the Bluetooth tab left up (its Connect, or Read details and join) is
    /// dropped, its notifications turned off first, so the run's connect, its times from Start and "connected this
    /// run" are its own. A Bluetooth-tab operation still running is waited for (60 s), else the run stops.
    private func dropEarlierHandoverLink(_ run: String) async throws {
        if handover.busy {
            let free = try await waitUntil("Waiting for Bluetooth", "Another Bluetooth operation (Bluetooth tab) is running; waiting up to 60 s for it to finish.",
                                           timeout: 60) { !self.handover.busy }
            if !free { throw GuidedStop("another Bluetooth operation (Bluetooth tab) is still running") }
        }
        guard handover.isConnected else { return }
        log.note("  guided: \(run): a Bluetooth link from before the run is up (Bluetooth tab); turning its notifications off and dropping it, so this run connects on its own")
        try await turnNotificationsOff()
        handover.disconnect()
        // Disconnect closes a link with notifications just turned off 2 s later: let it close before the run connects.
        try? await Task.sleep(for: .seconds(3))
    }

    /// A Subscribe call's worst case: 10 s per notifiable characteristic, the 1 s collection, and some slack.
    private func subscribeTimeout() -> Double {
        Double(max(handover.notifiableCodes.count, SonyWiFiHandover.sonyNotificationCodes.count)) * 10 + 30
    }

    /// One CC08 write (`attempt`, after the tester has confirmed it) and what the camera shows, recorded as `flag`
    /// (not when the tester answers that its Wi-Fi was already on), with whether CC09's notifications were on at the
    /// write. Returns the tester's answer.
    private func handoverAttempt(_ attempt: String, flag: String, statusBefore: Int?) async throws -> String {
        let clock = ContinuousClock()
        let started = clock.now
        // switchWiFiOn's own worst case: a 10 s CC09 subscription, a 15 s status read, a 15 s acknowledgement, then
        // 30 s from the write plus a 5 s poll.
        let on = try await bluetooth("Switching the camera's Wi-Fi on", "Attempt \(attempt): writing 01 to CC08, then waiting up to 30 s for the camera to report its Wi-Fi on.",
                                     timeout: 100) { try await self.handover.switchWiFiOn(timeout: 30, attempt: attempt) }
        let seconds = (clock.now - started).inSeconds
        let linkUp = handover.isConnected
        let sequence = handover.lastStatusSequence
        log.note("  guided: attempt \(attempt): CC08 = 01 written; the camera reported its Wi-Fi \(on ? "on" : "not on") after \(fmt(seconds)) s; \(sequence); Bluetooth link \(linkUp ? "still up" : "dropped") (Bluetooth: \(handover.status))")
        let shows = try await ask("On the camera", "What does the camera show now? (Including anything that showed for a moment after you tapped Write.)",
                                  buttons: ["Wi-Fi came on", "It was already on", "Something showed briefly, then went", "Nothing changed", "Something else"])
        let cc09Notifying = handover.lastCC09Notifying.map { $0 ? "yes" : "no" } ?? "unknown"
        let atWrite = handover.lastSubscribedAtWrite
        // Only this app's switches on this link are known: a bonded camera may keep others on from earlier runs or
        // from Creators' App, which would show as notifications "not subscribed by this app on this link".
        let subscribedText = "this app's notifications on at the write: \(atWrite.isEmpty ? "none" : atWrite.joined(separator: ", ")) (earlier runs or Creators' App may have left others on at the camera)"
        let context = "attempt \(attempt): after CC08 = 01; CC09 notifications on at the write: \(cc09Notifying); \(subscribedText); switchWiFiOn returned \(on ? "on" : "not on") after \(fmt(seconds)) s; \(sequence); Bluetooth link \(linkUp ? "up" : "dropped"); CC09 status at the harmless reads \(statusText(statusBefore)); camera shows: \(shows)"
        if shows == "It was already on" {
            log.note("  guided: \(flag) not recorded: the camera's Wi-Fi was already on (\(context))")
        } else {
            log.flag(flag, shows == "Wi-Fi came on", context: context)
        }
        return shows
    }

    /// A Wi-Fi status for a log line or context: masked like the handover's other values, "not reported" when nil.
    private func statusText(_ status: Int?) -> String {
        status == nil ? "not reported" : SonyWiFiHandover.shownStatus(status)
    }

    /// Logs the CC09 status byte remembered from an earlier run and offers to forget it, so one wrong guess can't
    /// steer every later run.
    private func reviewStatusByte() async throws {
        guard let index = SonyWiFiHandover.savedStatusByte() else {
            log.note("  guided: no CC09 status byte remembered; this run learns it if CC09 changes")
            return
        }
        let source = SonyWiFiHandover.savedStatusByteSource()
        log.note("  guided: CC09 status byte remembered: [\(index)] (\(source))")
        let answer = try await ask("CC09 status byte",
                                   "The app remembers byte [\(index)] of CC09 as the camera's Wi-Fi status (\(source)). Keep it, or forget it so this run learns it again?",
                                   buttons: ["Keep", "Forget"])
        if answer == "Forget" { handover.forgetRememberedStatusByte("guided run") }
    }

    /// Before Bluetooth disconnects: turns every notification off and waits for the camera to confirm each (5 s
    /// each), so none stays on for this bonded phone; those turned on over an earlier link (the camera dropped it and
    /// the run reconnected) are turned on and off again over this one (15 s each). If that doesn't finish, Disconnect
    /// turns any left on this link off without waiting.
    private func turnNotificationsOff() async throws {
        let earlier = handover.earlierLinkCodes
        guard handover.isConnected else {
            log.note("  guided: the Bluetooth link is down at the end, so the notifications can't be turned off now (any this app turned on may stay on for this phone\(earlier.isEmpty ? "" : ": \(earlier.joined(separator: ", "))"))")
            return
        }
        let current = handover.notifyingCount
        let count = current + earlier.count
        guard count > 0 else { return }
        do {
            let left = try await bluetooth("Turning notifications off", "Turning off the \(count) notification(s) on, waiting for the camera to confirm each (up to 5 s each; up to 15 s for one turned on before the link dropped).",
                                           timeout: Double(current) * 5 + Double(earlier.count) * 15 + 15) { try await self.handover.unsubscribeAll() }
            log.note("  guided: notifications off: \(left.isEmpty ? "all \(count) confirmed" : "not confirmed: \(left.joined(separator: ", "))")")
        } catch let stop as GuidedStop {
            log.warn("  guided: turning the notifications off didn't finish (\(stop.reason)); Disconnect turns off any left without waiting")
        }
    }

    /// One harmless CC09 read for the watch (`why` names it); nil when CC09 can't be read or the link is down. A
    /// failure doesn't stop the run, so the watch's results are still recorded.
    private func watchStatusRead(_ why: String) async throws -> Int? {
        guard handover.isConnected else { return nil }
        do {
            return try await bluetooth("Reading the camera's status", "Reading CC09, the camera's status (\(why)). Nothing is written.",
                                       timeout: 30) { try await self.handover.readStatus(why) }
        } catch let stop as GuidedStop {
            log.warn("  guided: the CC09 read \(why) didn't work (\(stop.reason)); going on without it")
            return nil
        }
    }

    /// Did iOS show a Bluetooth pairing request while this run was connected? Recorded as `flag`, with the app's own
    /// hints (including one from before a reconnect) in the question and the context.
    private func askPairingPrompt(flag: String, earlierHint: String?, steps: String, context: String) async throws {
        var hints: [String] = []
        for hint in [earlierHint, handover.lastPairingHint].compactMap({ $0 }) where !hints.contains(hint) { hints.append(hint) }
        let hintText = hints.isEmpty ? "none (no ATT error or unanswered read suggested one)" : hints.joined(separator: "; ")
        let paired = try await ask("Did iOS show a Bluetooth pairing request?",
                                   "At any point while the app was connected to the camera over Bluetooth (\(steps))?\(hints.isEmpty ? "" : " The app noticed: \(hintText)")",
                                   buttons: ["Yes", "No"])
        log.flag(flag, paired == "Yes", context: "\(context); the app's hint: \(hintText)")
    }

    /// Watches, over this app's own Bluetooth connection (iOS shares the link), what the camera notifies while
    /// Creators' App switches its Wi-Fi on: every 8000CC00 notification on (if not already), a harmless CC09 read as
    /// the baseline, a timeline mark, then you import in Creators' App and come back, and CC09 is read again. Asks
    /// whether Creators' App imported (`<prefix>.creatorsAppImported`, yes only for an import), then flags
    /// `<prefix>.cc09Launched` (the status byte or tag 0x0001 reached 2; without a remembered status byte, the byte
    /// that went 0 → 1 → 2, which is then remembered), measures `<prefix>.notifications` and `<prefix>.launchLatency`
    /// (CC09's first change to its change to status 2). Then watches 15 s after you quit Creators' App and reads CC09:
    /// `<prefix>.wifiStaysAfterQuit` (status 2 at the end), recorded only when the status is known; when it isn't 2
    /// or is unknown, you're asked whether the camera's Wi-Fi is still on. Returns whether the camera's Wi-Fi is on
    /// after the quit (the status, else your answer). This app is in the background meanwhile: the bluetooth-central
    /// background mode keeps the notifications coming, and the timeline's ContinuousClock keeps the times right; a
    /// link the camera drops keeps the timeline, so what came before the drop is still recorded.
    private func watchCreatorsApp(prefix: String) async throws -> Bool {
        if !handover.subscribedToAll {
            let codes = try await bluetooth("Subscribing to every notification",
                                            "Turning on every notification in the camera's 8000CC00 service (\(handover.notifiableCodes.count), up to 10 s each), then collecting the first ones for 1 s.",
                                            timeout: subscribeTimeout()) { try await self.handover.subscribe(nil) }
            log.note("  guided: subscribed to \(codes.count): \(codes.isEmpty ? "none" : codes.joined(separator: ", "))")
        }
        // A CC09 value to compare the watch's notifications with (a reconnect starts without one).
        let statusAtMark = try await watchStatusRead("before the watch")
        let backgroundBefore = lifecycle.backgroundEntries
        handover.markTimeline("Creators' App")
        try await ask("Import in Creators' App",
                      "Switch to Creators' App and import as you normally do. Wait until the first photo has arrived (or a minute has passed), then come back here.",
                      buttons: ["I'm back"])
        let away = lifecycle.backgroundEntries > backgroundBefore ? "this app went to the background" : "this app never left the foreground"
        let linkUp = handover.isConnected
        // Read too: iOS may not have delivered every notification while this app was in the background.
        let statusBack = try await watchStatusRead("after the watch")
        handover.timelineSummary()
        let watch = handover.cc09Watch()
        let drop = handover.linkDroppedAt.map { "Bluetooth link dropped at +\(fmt($0, 2)) s" } ?? (linkUp ? "Bluetooth link up" : "Bluetooth link dropped")
        let imported = try await ask("Did Creators' App import?", "Did Creators' App connect to the camera over Wi-Fi and import the photo?",
                                     buttons: ["Yes, it imported", "It connected, but no import", "It couldn't connect to the camera"])
        let base = "\(watch.notifications) notification(s), CC09 ×\(watch.cc09Notifications); status byte \(watch.position.map { "[\($0)]" } ?? "unknown") (\(watch.positionSource)): \(watch.sequence); CC09 read before the watch \(statusText(statusAtMark)), after it \(linkUp ? statusText(statusBack) : "not read (link down)"); \(away); \(drop); Creators' App: \(imported)"
        let reached = watch.sawLaunched || statusBack == 2
        let launchedText = watch.launchedAt.map { "status 2 at +\(fmt($0, 2)) s" }
            ?? (reached ? "status 2 seen, but no change to it from a known other status" : "no status 2 seen")
        log.flag("\(prefix).creatorsAppImported", imported == "Yes, it imported", context: "during the watch; \(launchedText); \(base)")
        log.flag("\(prefix).cc09Launched", reached, context: "while Creators' App was in front: \(launchedText)\(statusAtMark == 2 ? " (status was already 2 before the watch)" : ""); \(base)")
        log.measure("\(prefix).notifications", Double(watch.notifications), "count", context: "while Creators' App was in front; \(base)")
        if let launched = watch.launchedAt, let first = watch.firstChangeAt, launched >= first {
            log.measure("\(prefix).launchLatency", launched - first, "s",
                        context: "CC09's first change (+\(fmt(first, 2)) s) to status 2 (+\(fmt(launched, 2)) s) while Creators' App switched the Wi-Fi on; \(base)")
        }
        try await ask("Quit Creators' App", "Now quit Creators' App (swipe it away in the app switcher), come back here and tap Done. This app then watches the camera's status for 15 s.",
                      buttons: ["Done"])
        let watchedQuit = handover.isConnected
        if watchedQuit {
            handover.markTimeline("Creators' App quit")
        } else {
            log.warn("  guided: the Bluetooth link is down after the watch, so the 15 s after the quit can't be watched over Bluetooth")
        }
        let clock = ContinuousClock()
        let end = clock.now + .seconds(15)
        try await waitUntil("Watching the camera's status", "15 s: does the camera keep its Wi-Fi on without Creators' App?",
                            timeout: 20) { clock.now >= end }
        var after: CC09Watch?
        if watchedQuit {
            handover.timelineSummary()
            after = handover.cc09Watch()
        }
        // The status from a read at the end, not from the last notification; the notification only if CC09 can't be read.
        let statusEnd = try await watchStatusRead("15 s after Creators' App was quit")
        let linkAtEnd = handover.isConnected
        let known: Int? = statusEnd ?? (linkAtEnd ? after?.current : nil)
        let source = statusEnd != nil ? "read" : (known != nil ? "latest notification" : "unknown")
        var testerSays: String?
        if known != 2 {
            testerSays = try await ask("Is the camera's Wi-Fi still on?",
                                       "The app \(known == nil ? "can't see the camera's Wi-Fi status" : "doesn't see the Wi-Fi status as on") over Bluetooth. Look at the camera: is its Wi-Fi still on (Wi-Fi icon, or a network name on the screen)?",
                                       buttons: ["Yes, still on", "No, it's off", "Not sure"])
        }
        var onNetwork = await HotspotJoiner.onDirectNetwork().map { $0 ? "yes (iOS)" : "no (iOS)" }
        if onNetwork == nil {
            let answer = try await ask("Is the iPhone on the camera's network?",
                                       "Is the iPhone still joined to the camera's Wi-Fi network (Settings › Wi-Fi: a DIRECT-… network ticked)?",
                                       buttons: ["Yes", "No", "Not sure"])
            onNetwork = answer == "Not sure" ? "not sure" : "\(answer.lowercased()) (tester)"
        }
        let context = "15 s after Creators' App was quit: status \(statusText(known)) (\(source); status byte \(after?.position.map { "[\($0)]" } ?? "unknown"): \(after?.sequence ?? "not watched, link down")); \(after.map { "\($0.notifications) notification(s) since the quit" } ?? "notifications not watched"); Bluetooth link \(linkAtEnd ? "up" : "dropped"); iPhone still on a DIRECT- network: \(onNetwork ?? "unknown")\(testerSays.map { "; camera's Wi-Fi still on, tester: \($0)" } ?? "")"
        if let known {
            log.flag("\(prefix).wifiStaysAfterQuit", known == 2, context: context)
        } else {
            log.note("  guided: \(prefix).wifiStaysAfterQuit not recorded: the camera's status is unknown (\(context))")
        }
        return known == 2 || testerSays == "Yes, still on"
    }

    /// Joins the camera's network with `details`, waits for the camera at 192.168.122.1:15740, opens Sony's
    /// whole-card contents transfer, lists the card and downloads the newest ARW; with `joinAgain`, joins a second
    /// time. Flags `<prefix>.joinPrompt`, `<prefix>.import` and `<prefix>.joinPromptAgain`. With `started`, also
    /// measures `<prefix>.toCameraPort` and `<prefix>.toFirstFile` in seconds from it, less the time spent on the
    /// join-prompt question. `note` is added to the join-prompt, import and second join-prompt flags' contexts.
    private func joinAndImport(_ details: HandoverCredentials, prefix: String, what: String, note: String = "",
                               started: ContinuousClock.Instant? = nil, joinAgain: Bool) async throws {
        let clock = ContinuousClock()
        // A path monitor left running by an earlier Wi-Fi run would log every path change on this network.
        wireless.path.stop()
        // f. Join and find the camera.
        UserDefaults.standard.set("ap", forKey: "ptpip.net")
        // ptpip.ap.join's context names the run (never the network).
        let source = prefix == "ble.handover" ? "Bluetooth handover" : "Bluetooth join run (\(prefix))"
        try await wifi("Join the camera's network", "Accept the system prompt if iOS asks.", timeout: 90) {
            wireless.joinHandover(ssid: details.ssid, passphrase: details.passphrase, source: source)
        }
        let firstAlready = wireless.lastJoinAlreadyAssociated
        let asked = clock.now
        let prompted = try await ask("Did iOS ask to join?", "Did a system prompt ask to join the camera's network?", buttons: ["Yes", "No"])
        let questionSeconds = (clock.now - asked).inSeconds
        log.flag("\(prefix).joinPrompt", prompted == "Yes",
                 context: "first NEHotspotConfiguration join with the details from Bluetooth; " + joinOutcome(firstAlready) + note)
        let host = "192.168.122.1"
        if let gateway = wireless.lastJoinGateway, gateway != host {
            log.warn("  guided: the join reported gateway \(gateway), not \(host); waiting at \(host) anyway")
        }
        step("Waiting for the camera at \(host):15740")
        let port = try await pollCameraPort(host: host, title: "Waiting for the camera",
                                            message: "Waiting for the camera to answer at \(host):15740 on its own network (up to 60 s).",
                                            timeout: 60)
        guard let after = port.answeredAfter else {
            log.warn("  guided: nothing answered at \(host):15740 within 60 s of the join (\(port.attempts) TCP connect(s); last: \(port.lastError))")
            throw GuidedStop("the camera didn't answer at \(host):15740 after the join")
        }
        UserDefaults.standard.set(host, forKey: "ptpip.host")
        log.note("  guided: the camera answered at \(host):15740 \(fmt(after)) s after the join (\(port.attempts) TCP connect(s)); camera IP set to \(host)")
        if let started {
            log.measure("\(prefix).toCameraPort", (clock.now - started).inSeconds - questionSeconds, "s",
                        context: "from Start to the camera answering at \(host):15740, less \(fmt(questionSeconds)) s on the join-prompt question; " + joinOutcome(firstAlready))
        }

        // g. Import one file over a whole-card contents-transfer session.
        let t = wifiTarget()
        try await wifi("Contents transfer: whole card",
                       "SDIO_OpenSession, Sony's init sequence and the transfer mode, then waiting while the camera indexes the card (up to about 2 minutes). Accept on the camera if it asks.",
                       timeout: 180) {
            wireless.connectContentsTransfer(t, mode: .wholeCard)
        }
        try await listAfterContentsTransfer("whole card, \(what)")
        guard wireless.objects.contains(where: { $0.info.filename.uppercased().hasSuffix(".ARW") }) else {
            log.flag("\(prefix).import", false, context: "\(wireless.objects.count) objects listed, no ARW" + note)
            throw GuidedStop("no ARW listed on the card")
        }
        let hashStarted = Date()
        try await wifi("GetObject newest ARW", "Downloading the newest ARW and its SHA-256.", timeout: 300) { wireless.referenceHash() }
        let imported = log.entries.contains { $0.at >= hashStarted && $0.text.hasPrefix("Reference SHA-256 of ") }
        log.flag("\(prefix).import", imported,
                 context: (imported ? "GetObject of the newest ARW over the network joined from Bluetooth; \(wireless.objects.count) objects listed"
                                    : "GetObject of the newest ARW failed (see the log)") + note)
        if imported, let started {
            log.measure("\(prefix).toFirstFile", (clock.now - started).inSeconds - questionSeconds, "s",
                        context: "from Start to the newest ARW downloaded over the camera's network, less \(fmt(questionSeconds)) s on the join-prompt question; \(wireless.objects.count) objects listed")
        }
        guard joinAgain else { return }

        // h. Join again with the same details.
        try await wifi("Join again", "The same join a second time. Accept the system prompt if iOS asks.", timeout: 90) {
            wireless.joinHandover(ssid: details.ssid, passphrase: details.passphrase, source: "\(source), second join")
        }
        let secondAlready = wireless.lastJoinAlreadyAssociated
        if secondAlready == true {
            // apply answers "already associated" without a prompt, so the answer is known in advance.
            log.note("  guided: second join: apply answered already associated (the phone is still on the camera's network), so no prompt was possible; \(prefix).joinPromptAgain not recorded")
        } else {
            let again = try await ask("Did iOS ask again?", "Did a system prompt ask to join the camera's network this time?", buttons: ["Yes", "No"])
            log.flag("\(prefix).joinPromptAgain", again == "Yes",
                     context: "second join with the same details, while on the camera's network; " + joinOutcome(secondAlready) + note)
        }
    }

    /// Bluetooth: Wi-Fi handover. Can the app switch the camera's Wi-Fi on over Bluetooth (the one value written, CC08
    /// = 01, only after you confirm it), read its network name and password, join that network and import a file,
    /// with Creators' App still working afterwards? Build 11: first, if you agree, the status notifications Sony's app
    /// subscribes to (CC09, CC10, CC0F, CC03, CC0E); a second attempt with every 8000CC00 notification on; then, if the
    /// Wi-Fi still isn't on, a watch of Creators' App switching it on. The name and password stay in memory for the
    /// two joins and are then dropped: the log gets lengths, yes/no answers and the handover's redacted description
    /// only.
    func bleHandover() async throws {
        let ready = try await ask("Camera ready",
                                  "Set the camera up: switched on, its Wi-Fi OFF (Network › PC Remote Function off, so no Wi-Fi Direct network is up; to see whether Bluetooth switches the Wi-Fi on), Bluetooth on, Smartphone Connect set as Creators' App uses it (Bluetooth Function on, this phone paired), and a memory card with a few photos in it (Sony's app gives up switching the Wi-Fi on when the camera reports no media). Quit Creators' App (swipe it away). Then tap Ready.",
                                  buttons: ["Ready", "Skip"])
        guard ready == "Ready" else {
            log.note("◆ Bluetooth: Wi-Fi handover: skipped")
            return
        }
        let remote = try await ask("Bluetooth Rmt Ctrl", "On the camera (Network › Bluetooth): is Bluetooth Rmt Ctrl on?",
                                   buttons: ["On", "Off", "Not sure"])
        log.note("◆ Wi-Fi handover: camera Wi-Fi off at the start (PC Remote off), Smartphone Connect as Creators' App uses it, photos on the card, Creators' App quit, Bluetooth Rmt Ctrl \(remote)")
        try await reviewStatusByte()
        try await dropEarlierHandoverLink("Wi-Fi handover run")

        var disconnected = false
        defer { if !disconnected { handover.disconnect() } }
        // The network name and password: held only from the read to the end of the joins.
        var credentials: HandoverCredentials?
        // Whether this run reached the camera over Bluetooth and tried the CC08 write: the pairing and Creators' App
        // questions are asked only when it connected, and their flags say whether it wrote.
        var connectedThisRun = false
        var triedCC08 = false
        // A pairing hint from before a reconnect (Connect starts each attempt without one).
        var earlierHint: String?
        // How the camera's Wi-Fi came on in this run; nil while it isn't (known to be) on.
        var wifiOnBy: String?
        var subscriptions = "none"
        var watched = false

        try await section("Switch the camera's Wi-Fi on over Bluetooth",
                          "Connect, list the camera's services, harmless reads (model, firmware, status), the status notifications Sony's app subscribes to (you choose), then the one write, CC08 = 01, which you confirm first. If the Wi-Fi doesn't come on: a second try with every notification on, then you can watch Creators' App switch it on. Then the network details are read. Nothing about the network is shown or logged except lengths and yes/no answers.") {
            // b. Connect and discover. The inventory's count of notifiable characteristics outlives a dropped link.
            let inventory = try await connectHandover { connectedThisRun = true }

            // c. Harmless reads (up to four, 15 s each). Whether iOS asked to pair is asked after this section.
            let status = try await bluetooth("Harmless reads", "Reading the model name, firmware and Wi-Fi status. Nothing is written.",
                                             timeout: 75) { try await self.handover.safeReads() }
            log.note("  guided: harmless reads done; status value \(statusText(status)) (Bluetooth: \(handover.status))")
            let alreadyOn = status == 2
            if alreadyOn {
                log.warn("  guided: CC09 already reports Wi-Fi status 2 (on) before the write; the run expects the camera's Wi-Fi off")
            }

            // d. Sony's subscriptions, if the tester agrees: only the notification switches are written.
            let sony = SonyWiFiHandover.sonyNotificationCodes
            let subscribe = try await ask("Subscribe to the camera's status notifications?",
                                          "Sony's app subscribes to the camera's status notifications when it connects, and the camera may want that before it brings its Wi-Fi up. Subscribe the same way? This writes only the notification switches of \(sony.joined(separator: ", ")) (status, battery, media, transfer, initial setting); they are turned off at the end.",
                                          buttons: ["Subscribe", "Skip"])
            // Which of Sony's set took: all of it (sonySet), some (sonySetPartial), or none (as if skipped: cc09Only).
            var sonyTook: [String] = []
            if subscribe == "Subscribe" {
                let codes = try await bluetooth("Subscribing to the camera's notifications",
                                                "Turning on notifications for \(sony.joined(separator: ", ")) (up to 10 s each), then collecting the first ones for 1 s.",
                                                timeout: subscribeTimeout()) { try await self.handover.subscribe(sony) }
                sonyTook = sony.filter { codes.contains($0) }
                subscriptions = "Sony's set (\(codes.isEmpty ? "none took" : codes.joined(separator: ", ")))"
                log.note("  guided: subscribed to \(codes.isEmpty ? "none" : codes.joined(separator: ", "))\(sonyTook.count == sony.count ? "" : "; \(sonyTook.count) of Sony's \(sony.count) took")")
            } else {
                log.note("  guided: no subscriptions before the first attempt but CC09's, which the write turns on itself")
            }

            // e. The one write, only after the tester confirms it: up to two attempts.
            let write = try await ask("Switch the camera's Wi-Fi on?",
                                      (alreadyOn ? "The camera already reports its Wi-Fi as on (CC09 status 2). Switch its Wi-Fi off on the camera first if you can, or write anyway. " : "")
                                        + "Write 01 to CC08 to switch the camera's Wi-Fi on? It is the only value written; the app also turns on CC09's status notifications if they aren't on, and every notification is turned off at the end. Watch the camera's screen as you tap Write: it may show something for only about 2 s.",
                                      buttons: ["Write", "Skip"])
            if write == "Write" {
                triedCC08 = true
                var outcomes: [String] = []
                // Without Sony's set, the write still turns on CC09's notifications: the minimal form of the hypothesis.
                // Only the whole set counts as Sony's; some of it is recorded apart, none of it as CC09 only.
                let firstLabel: String
                let firstFlag: String
                if !sonyTook.isEmpty && sonyTook.count == sony.count {
                    firstLabel = "Sony's notifications"
                    firstFlag = "ble.handover.wifiOn.sonySet"
                } else if !sonyTook.isEmpty {
                    firstLabel = "part of Sony's notifications (\(sonyTook.joined(separator: ", ")))"
                    firstFlag = "ble.handover.wifiOn.sonySetPartial"
                } else {
                    firstLabel = "CC09 notifications only"
                    firstFlag = "ble.handover.wifiOn.cc09Only"
                }
                let first = try await handoverAttempt("1, \(firstLabel)", flag: firstFlag, statusBefore: status)
                outcomes.append("attempt 1 (\(firstLabel), CC09 notifying at the write \(handover.lastCC09Notifying.map { $0 ? "yes" : "no" } ?? "unknown")): camera shows \(first)")
                switch first {
                case "Wi-Fi came on": wifiOnBy = "CC08, attempt 1"
                case "It was already on": wifiOnBy = "already on"
                default: break
                }
                if wifiOnBy == nil {
                    // After a dropped link notifiableCodes is empty until the reconnect: use the first listing's count.
                    let notifiable = handover.notifiableCodes.isEmpty ? inventory.notifiable.count : handover.notifiableCodes.count
                    let again = try await ask("Try again with every 8000CC00 notification on?",
                                              "The camera's Wi-Fi didn't come on. Try once more with every notification the camera's 8000CC00 service offers turned on (\(notifiable) characteristics)? This writes only their notification switches, turned off at the end, then 01 to CC08 again. Watch the camera's screen as you tap: it may show something for only about 2 s.",
                                              buttons: ["Try again", "Skip"])
                    if again == "Try again" {
                        if !handover.isConnected { earlierHint = earlierHint ?? handover.lastPairingHint }
                        try await ensureHandoverLink("before the second attempt")
                        let codes = try await bluetooth("Subscribing to every notification",
                                                        "Turning on every notification in the camera's 8000CC00 service (\(handover.notifiableCodes.count), up to 10 s each), then collecting the first ones for 1 s.",
                                                        timeout: subscribeTimeout()) { try await self.handover.subscribe(nil) }
                        subscriptions = "every 8000CC00 notification (\(codes.count))"
                        log.note("  guided: subscribed to \(codes.count): \(codes.isEmpty ? "none" : codes.joined(separator: ", "))")
                        let second = try await handoverAttempt("2, all notifications", flag: "ble.handover.wifiOn.allNotifications",
                                                               statusBefore: status)
                        outcomes.append("attempt 2 (all notifications): camera shows \(second)")
                        switch second {
                        case "Wi-Fi came on": wifiOnBy = "CC08, attempt 2"
                        case "It was already on": wifiOnBy = "already on"
                        default: break
                        }
                    }
                }
                // ble.handover.wifiOn: did a CC08 write switch the camera's Wi-Fi on in this run (either attempt)?
                let context = "after CC08 = 01; \(outcomes.joined(separator: "; ")); CC09 status at the harmless reads \(statusText(status))"
                if wifiOnBy == "already on" {
                    log.note("  guided: ble.handover.wifiOn not recorded: the camera's Wi-Fi was already on (\(context))")
                } else {
                    log.flag("ble.handover.wifiOn", wifiOnBy != nil, context: context)
                }

                // f. Still off: watch Creators' App do it, on the same connection.
                if wifiOnBy == nil {
                    let watch = try await ask("Watch Creators' App switch the Wi-Fi on?",
                                              "The camera's Wi-Fi is still off. This app can stay connected with every 8000CC00 notification on and record what the camera reports while you import in Creators' App, which switches the camera's Wi-Fi on. Only notification switches are written.",
                                              buttons: ["Watch", "Skip"])
                    if watch == "Watch" {
                        if !handover.isConnected { earlierHint = earlierHint ?? handover.lastPairingHint }
                        try await ensureHandoverLink("before the watch")
                        watched = true
                        subscriptions = "every 8000CC00 notification (watch)"
                        if try await watchCreatorsApp(prefix: "ble.handover") {
                            wifiOnBy = "Creators' App (still on after it was quit)"
                        }
                    }
                }
            } else {
                log.note("◆ Wi-Fi handover: CC08 not written (skipped); reading the network details as the camera is")
                wifiOnBy = "not switched by this run (CC08 skipped)"
            }

            guard let route = wifiOnBy else {
                log.note("◆ Wi-Fi handover: the camera's Wi-Fi isn't on, so no network details, join or import")
                return
            }
            log.note("  guided: the camera's Wi-Fi: \(route); reading the network details")

            // g. The network details: compared in memory with the Wi-Fi tab's fields, never logged. The camera may
            // have dropped Bluetooth when its Wi-Fi came on, so reconnect first if it did.
            if !handover.isConnected { earlierHint = earlierHint ?? handover.lastPairingHint }
            try await ensureHandoverLink("before the network details read")
            let read = try await bluetooth("Reading the network details", "Reading the camera's network name and password over Bluetooth. They are never shown or logged.",
                                           timeout: 60, detail: false) { try await self.handover.readCredentials() }
            log.note("  guided: network details read: \(read.description)")
            let ssidOK = !read.ssid.isEmpty
            let passphraseShape = (8...63).contains(read.passphrase.count)
                && read.passphrase.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
            log.note("  guided: SSID \(HotspotJoiner.ssidSummary(read.ssid)); password \(read.passphrase.count) characters, 8–63 printable ASCII \(passphraseShape ? "yes" : "no"); BSSID \(read.bssidPresent ? "present" : "absent")")
            let typedSSID = wireless.joinSSID.trimmingCharacters(in: .whitespacesAndNewlines)
            if typedSSID.isEmpty {
                log.note("  guided: no SSID in the Wi-Fi tab, so no SSID comparison")
            } else {
                let same = read.ssid == typedSSID
                log.note("  guided: SSID equals the Wi-Fi tab's: \(same ? "yes" : "no")")
                log.flag("ble.handover.ssidMatchesTyped", same, context: "compared in memory with the Wi-Fi tab's SSID (typed or scanned); neither logged")
            }
            if wireless.joinPassphrase.isEmpty {
                log.note("  guided: no passphrase in the Wi-Fi tab, so no password comparison")
            } else {
                let same = read.passphrase == wireless.joinPassphrase
                log.note("  guided: password equals the Wi-Fi tab's passphrase: \(same ? "yes" : "no")")
                log.flag("ble.handover.passwordMatchesTyped", same, context: "compared in memory with the Wi-Fi tab's passphrase (typed or scanned); neither logged")
            }
            guard ssidOK else { throw GuidedStop("the camera gave no network name over Bluetooth (was its Wi-Fi on?)") }
            credentials = read
        }

        // Pairing: asked whenever this run reached the camera, whatever happened after; the app's hint is context.
        if connectedThisRun {
            try await askPairingPrompt(flag: "ble.handover.pairingPrompt", earlierHint: earlierHint,
                                       steps: "connect, reads, notification switches\(triedCC08 ? ", the write" : "")",
                                       context: "during this run's Bluetooth steps (CC08 write \(triedCC08 ? "attempted" : "not attempted"); subscriptions: \(subscriptions))")
        }

        if credentials == nil {
            log.note("◆ Wi-Fi handover: no network details from Bluetooth, so no join or import")
        } else {
            try await section("Join the camera's network and import",
                              "Join with the details from Bluetooth, wait for the camera at 192.168.122.1, connect for the whole card, list it, download the newest ARW, then join a second time.") {
                guard let details = credentials else { throw GuidedStop("no network details from Bluetooth") }
                try await joinAndImport(details, prefix: "ble.handover", what: "after the Bluetooth handover",
                                        note: "; camera's Wi-Fi: \(wifiOnBy ?? "unknown")", joinAgain: true)
            }
        }
        // Done with the joins: drop the network name and password.
        credentials = nil

        // i. Bluetooth off, and is Creators' App unharmed? Asked only when this run connected to the camera.
        if wireless.isConnected {
            try await wifi("Disconnect PTP/IP", "Closing the Wi-Fi session, so Creators' App can connect.", timeout: 30) { wireless.disconnect() }
        }
        try await turnNotificationsOff()
        step("Disconnect Bluetooth")
        handover.disconnect()
        disconnected = true
        log.note("  guided: Bluetooth disconnected (\(handover.status))")
        guard connectedThisRun else {
            log.note("  guided: this run never connected to the camera over Bluetooth, so ble.handover.creatorsAppStillWorks isn't asked")
            return
        }
        let works = try await ask("Creators' App", "Open Creators' App and check that it still connects to the camera as before. Then come back here. Does it?",
                                  buttons: ["Yes", "No"])
        log.flag("ble.handover.creatorsAppStillWorks", works == "Yes",
                 context: "after the handover run; CC08 write \(triedCC08 ? "attempted" : "not attempted"); subscriptions: \(subscriptions); watched Creators' App \(watched ? "yes" : "no"); Bluetooth Rmt Ctrl \(remote)")
    }

    /// Bluetooth: watch Creators' App switch Wi-Fi on. No CC08 write: with every 8000CC00 notification on, this app
    /// records what the camera reports while you import in Creators' App, to show the status sequence that works and
    /// any characteristic that changes first. Only notification switches are written, and they are turned off at the
    /// end.
    func bleWatch() async throws {
        let ready = try await ask("Camera ready",
                                  "Set the camera up: switched on, its Wi-Fi OFF (Network › PC Remote Function off), Bluetooth on, a few photos on the card. Quit Creators' App (swipe it away). Then tap Ready.",
                                  buttons: ["Ready", "Skip"])
        guard ready == "Ready" else {
            log.note("◆ Bluetooth: watch Creators' App: skipped")
            return
        }
        log.note("◆ Watch Creators' App: camera Wi-Fi off at the start (PC Remote off), photos on the card, Creators' App quit")
        try await reviewStatusByte()
        try await dropEarlierHandoverLink("watch run")

        var disconnected = false
        defer { if !disconnected { handover.disconnect() } }
        var connectedThisRun = false
        var subscribed = false

        try await section("Watch Creators' App switch the camera's Wi-Fi on",
                          "Connect, list the camera's services, harmless reads, every 8000CC00 notification turned on (you confirm), then you import in Creators' App while this app records what the camera reports, and quit it. Only notification switches are written; nothing else.") {
            // The listing is logged, not recorded: ble.handover.services and .cameraControl belong to the handover run.
            let inventory = try await connectHandover(record: nil) { connectedThisRun = true }
            let status = try await bluetooth("Harmless reads", "Reading the model name, firmware and Wi-Fi status. Nothing is written.",
                                             timeout: 75) { try await self.handover.safeReads() }
            log.note("  guided: harmless reads done; status value \(statusText(status)) (Bluetooth: \(handover.status))")
            guard !inventory.notifiable.isEmpty else { throw GuidedStop("nothing in 8000CC00 can notify, so there is nothing to watch") }
            let go = try await ask("Subscribe to every notification?",
                                   "Turn on every notification the camera's 8000CC00 service offers (\(inventory.notifiable.count): \(inventory.notifiable.joined(separator: ", ")))? Only their notification switches are written, and they are turned off at the end.",
                                   buttons: ["Subscribe", "Skip"])
            guard go == "Subscribe" else { throw GuidedStop("no subscriptions, so nothing to watch") }
            subscribed = true
            let stays = try await watchCreatorsApp(prefix: "ble.watch")
            log.note("  guided: watch done; the camera's Wi-Fi \(stays ? "stayed on" : "didn't stay on (or couldn't be seen)") after Creators' App was quit")
        }

        if connectedThisRun {
            try await askPairingPrompt(flag: "ble.watch.pairingPrompt", earlierHint: nil,
                                       steps: "connect, reads\(subscribed ? ", notification switches" : "")",
                                       context: "during the watch run's Bluetooth steps (no CC08 write; notifications \(subscribed ? "on" : "not turned on"))")
        }
        try await turnNotificationsOff()
        step("Disconnect Bluetooth")
        handover.disconnect()
        disconnected = true
        log.note("  guided: Bluetooth disconnected (\(handover.status))")
        guard connectedThisRun else {
            log.note("  guided: this run never connected to the camera over Bluetooth, so ble.watch.creatorsAppStillWorks isn't asked")
            return
        }
        let works = try await ask("Creators' App", "Open Creators' App and check that it still connects to the camera as before. Then come back here. Does it?",
                                  buttons: ["Yes", "No"])
        log.flag("ble.watch.creatorsAppStillWorks", works == "Yes",
                 context: "after the watch run; no CC08 write; notifications \(subscribed ? "on during the run, turned off at the end" : "not turned on")")
    }

    /// Bluetooth: join with the camera's Wi-Fi on. The 1.0 fallback end to end: you switch the camera's Wi-Fi Direct
    /// network on in PC Remote; the app reads its name and password over Bluetooth (no subscriptions, no CC08 write),
    /// joins, and imports the newest ARW, timed from Start. The details stay in memory only until the join and import
    /// are done.
    func bleJoin() async throws {
        let ready = try await ask("Camera's Wi-Fi on",
                                  "On the camera, switch PC Remote on with its Wi-Fi Direct network up (Network › PC Remote Function), so it shows its network name. Don't join that network in Settings. For a clean measurement of iOS's join prompt, forget the camera's network in Settings › Wi-Fi first (optional). Quit Creators' App (swipe it away). Then tap Ready.",
                                  buttons: ["Ready", "Skip"])
        guard ready == "Ready" else {
            log.note("◆ Bluetooth: join with the camera's Wi-Fi on: skipped")
            return
        }
        let forgot = try await ask("Network forgotten?", "Did you forget the camera's network in Settings › Wi-Fi before this run?",
                                   buttons: ["Forgotten", "Not forgotten"])
        let setup = "camera's network \(forgot == "Forgotten" ? "forgotten in Settings first" : "not forgotten in Settings")"
        log.note("◆ Join with the camera's Wi-Fi on: PC Remote's Wi-Fi Direct network up, Creators' App quit, \(setup)")
        // Before Start: a link left up by the Bluetooth tab would leave the connect out of the times from Start.
        try await dropEarlierHandoverLink("join run")

        var disconnected = false
        defer { if !disconnected { handover.disconnect() } }
        var connectedThisRun = false

        try await section("Join with the camera's Wi-Fi on",
                          "Start starts the clock. The app connects over Bluetooth, lists the services, reads the camera's network name and password (never shown or logged; nothing is written to the camera), joins the network, waits for the camera at 192.168.122.1, connects for the whole card, lists it and downloads the newest ARW.") {
            let clock = ContinuousClock()
            let started = clock.now
            // Recorded as ble.join.* by this run, not as the handover run's ble.handover.* names.
            _ = try await connectHandover(record: nil) { connectedThisRun = true }
            // The network name and password: only in this scope, dropped when the section ends.
            let read: HandoverCredentials
            do {
                read = try await bluetooth("Reading the network details", "Reading the camera's network name and password over Bluetooth. They are never shown or logged.",
                                           timeout: 60, detail: false) { try await self.handover.readCredentials(record: nil) }
            } catch let stop as GuidedStop {
                // With the link still up, the read itself failed: the camera answers 0x9D when no network is set up.
                guard handover.isConnected else { throw stop }
                log.flag("ble.join.credentials", false, context: "the network details read failed with the Bluetooth link up (no network configured on the camera?); \(setup)")
                throw GuidedStop("the camera has no network configured: switch its Wi-Fi on first")
            }
            log.measure("ble.join.toDetails", (clock.now - started).inSeconds, "s",
                        context: "from Start: Bluetooth connect, discovery and the network details read; \(read.description)")
            let usable = !read.ssid.isEmpty && HandoverCredentials.isValidPassphrase(read.passphrase)
            log.flag("ble.join.credentials", usable, context: "\(read.description); \(setup)")
            guard usable else { throw GuidedStop("the network details from Bluetooth aren't usable (see the layout line in the log)") }
            try await joinAndImport(read, prefix: "ble.join", what: "Bluetooth join with the camera's Wi-Fi on", note: "; \(setup)",
                                    started: started, joinAgain: false)
        }

        // Asked whenever the run connected: an unseen pairing request would be inside ble.join.toDetails.
        if connectedThisRun {
            try await askPairingPrompt(flag: "ble.join.pairingPrompt", earlierHint: nil, steps: "connect, the network details read",
                                       context: "during the join run's Bluetooth steps (no subscriptions, no CC08 write; a request would be inside ble.join.toDetails); \(setup)")
        }
        if wireless.isConnected {
            try await wifi("Disconnect PTP/IP", "Closing the Wi-Fi session.", timeout: 30) { wireless.disconnect() }
        }
        step("Disconnect Bluetooth")
        handover.disconnect()
        disconnected = true
        log.note("  guided: Bluetooth disconnected (\(handover.status)); the network details are dropped")
    }

    /// How a join answered, for a join-prompt flag's context.
    private func joinOutcome(_ alreadyAssociated: Bool?) -> String {
        switch alreadyAssociated {
        case .some(true): return "apply answered already associated (no prompt expected)"
        case .some(false): return "apply joined"
        case .none: return "the join failed (see the log)"
        }
    }
}

extension GuidedRunner {
    /// GuidedCopyAll.swift's way to a Wi-Fi session (ensureWiFiSession is private to this file): with none open,
    /// wifiJoin first, which asks which network (and stores it as ptpip.net), joins the camera's own network over
    /// Bluetooth with the QR code or Settings as the fallback, or takes the camera's IP on the home LAN.
    func ensureWiFiSessionForCopy() async throws {
        guard !wireless.isConnected else { return }
        try await wifiJoin()
        try await ensureWiFiSession(joined: true)
    }
}
