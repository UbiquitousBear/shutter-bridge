import Foundation
import ImageCaptureCore

// The guided *Copy all RAW to Files* run (Guided tab, group "Copy to Files"): every ARW on the card into a new folder
// in the Files app, over USB-C or Wi-Fi, inside a continued task. It calls the same functions as the Wired and Wi-Fi
// tabs' Copy all RAW to Files buttons. Nothing is written to the Photos library.

extension GuidedRunner {
    func copyAllToFiles() async throws {
        let destination = FilesDestination.shared
        let link = try await ask("Copy all RAW to Files",
                                 "Copies every RAW (ARW) on the card into a new folder in the Files app. Nothing on the card or already in Files is changed or deleted, and nothing goes to the Photos library. Which link?",
                                 buttons: ["USB-C", "Wi-Fi"])
        let overUSB = link == "USB-C"
        step("Copy all RAW to Files over \(link)")

        // A session with the card listed.
        var items: [CopyAllItem]
        if overUSB {
            items = try await copyAllUSBSession()
        } else {
            if !wireless.isConnected || wireless.contentsMode != .wholeCard {
                // Only PC Remote's whole-card contents transfer has listed the whole card (spike-findings.md).
                try await ask("Camera on Wi-Fi",
                              "On the camera: Network › Cnct./PC Remote › PC Remote Function on, with PC Remote Cnct Method set to Wi-Fi Direct (or Wi-Fi Access Point for your home network). That is the mode that lists the whole card; Smartphone Connect doesn't. Then join its network in Settings › Wi-Fi if the phone isn't on it.",
                              buttons: ["Done"])
            }
            items = try await copyAllWiFiSession()
        }

        // Where the copies go.
        let tab = overUSB ? "Wired" : "Wi-Fi"
        // So a chosen folder that has gone (or is now in Recently Deleted) shows as a problem before the tester agrees.
        destination.checkFolder()
        while true {
            let useThis = destination.isPicked ? "Use this folder" : "Use this folder (deleted with \(FilesDestination.appFolderName))"
            var buttons = [useThis, "Choose a folder"]
            if destination.isPicked { buttons.append("Use the default folder") }
            let caveat = destination.isPicked ? "" : "\n\n" + FilesDestination.defaultCaveat
            let problem = destination.problem.map { "\n\n\($0)" } ?? ""
            let choice = try await ask("Where to copy",
                                       "The photos go to \(destination.locationDescription), into a new folder named by the start time (\"Copy 2026-11-03 01.23.45\"), so nothing there is overwritten.\(caveat)\(problem)",
                                       buttons: buttons)
            if choice == useThis { break }
            if choice == "Use the default folder" {
                destination.useDefault()
                continue
            }
            let before = destination.changes
            let answer = try await waitInTabs("Choose a folder",
                                              "Open the \(tab) tab, go to Copy all RAW to Files and tap Choose folder…, pick a folder (iCloud Drive, On My iPhone or an external drive, not the camera's card \"Untitled\") and tap Open. Then come back to the Guided tab.",
                                              timeout: 900) { destination.changes != before }
            if answer == "timeout" { log.warn("  guided: no folder chosen within 15 min") }
        }
        log.note("  guided: copying to \(destination.locationDescription)")

        // How much, and the go-ahead from a tap (the continued task needs one).
        // What the spike measured: about 38 MB/s on the cable, 11.7–15.5 MB/s on the camera's Wi-Fi.
        let rate: Double = overUSB ? 38 : 13
        if !overUSB {
            // Choosing a folder can take long enough for the camera to drop the session (about 30 s in PC Remote).
            let relinked = try await reconnectWiFiIfDropped()
            if relinked { items = try await copyAllWiFiSession() }
        }
        let linkName = overUSB ? "usb" : "ptpip.\(wireless.sessionNet ?? wifiTarget().net)"
        do {
            try destination.checkSpace(for: items, link: linkName)
        } catch {
            throw GuidedStop(CopyAllFormat.describe(error))
        }
        let bytes = items.reduce(UInt64(0)) { $0 + $1.size }
        let minutes = max(1, Int((Double(bytes) / 1e6 / rate / 60).rounded(.up)))
        // checkSpace has resolved the folder (a chosen one that can't be used refuses above), so this is where they go.
        let go = try await ask("Ready to copy",
                               "\(items.count) ARW, \(CopyAllFormat.gb(bytes)), into \(destination.locationDescription): about \(minutes) min at \(Int(rate)) MB/s. Tap Start, then lock the phone once the copy shows on the Lock Screen or in the Dynamic Island: it carries on while locked. Keep the camera on and \(overUSB ? "plugged in" : "close to the phone").",
                               buttons: ["Start", "Not now"])
        if go != "Start" { throw GuidedStop("not started") }
        let finishedBefore = destination.runsFinished
        let returns = lifecycle.foregroundReturns
        let entries = lifecycle.backgroundEntries
        try await startContinued("The copy") {
            if overUSB {
                usb.session?.copyAllARW(using: continued)
            } else {
                wireless.copyAllARW()
            }
        }

        // Until it ends: no limit shorter than an hour, then the choice to keep waiting.
        step("Copying \(items.count) ARW (about \(minutes) min)")
        do {
            while true {
                let ended = try await waitUntil("Copying \(items.count) ARW",
                                                "Lock the phone now if you like: the copy carries on, and this run picks up when it ends (about \(minutes) min). Cancel run stops it; what has been copied stays.",
                                                timeout: 3600) { !self.continued.isRunning }
                if ended { break }
                let progress = destination.run?.progressLine ?? continued.state
                let next = try await ask("Still copying", "After an hour: \(progress). Keep waiting?", buttons: ["Keep waiting", "Stop the copy"])
                if next == "Stop the copy" {
                    continued.stop()
                    try await waitUntil("Stopping", "Stopping after the file in flight.", timeout: 600) { !self.continued.isRunning }
                    break
                }
            }
        } catch is GuidedCancelled {
            // Cancel run has stopped the copy: let it record its measurements before the report is made.
            let deadline = Date().addingTimeInterval(120)
            while continued.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
            throw GuidedCancelled()
        }
        if lifecycle.backgroundEntries > entries {
            log.note(String(format: "  guided: the app left the foreground during the copy%@", lifecycle.foregroundReturns > returns ? String(format: " (away %.0f s the last time)", lifecycle.lastAwaySeconds) : ""))
        }

        guard destination.runsFinished != finishedBefore, let outcome = destination.lastOutcome else {
            throw GuidedStop("the copy didn't run (continued task: \(continued.state); see the log)")
        }
        log.note("◆ Copy all RAW to Files: \(outcome.summary)")
        guard outcome.copied > 0 else { throw GuidedStop("nothing was copied: \(outcome.stopReason ?? "see the log")") }

        // The tester checks the result in Files.
        let place = outcome.destination == FilesDestination.defaultDescription
            ? "Browse › On My iPhone › \(FilesDestination.appFolderName) › \(FilesDestination.defaultFolderName)"
            : "the folder you chose, \(destination.pickedName ?? outcome.destination)"
        let check = try await ask("Check in Files",
                                  "Open the Files app and go to \(place) › \(outcome.folderName). Are the \(outcome.copied) photos there, and do a few of them open? Then come back here.",
                                  buttons: ["All there and they open", "Some missing or won't open", "Couldn't find the folder"])
        log.flag("\(outcome.prefix).verifiedInFiles", check == "All there and they open",
                 context: "tester: \(check); \(outcome.copied) of \(outcome.total) copied into \(outcome.destinationLabel)")
    }

    /// An open USB session with ImageCaptureCore's catalogue complete: the one already open, or a new one. Returns the
    /// ARW to copy.
    private func copyAllUSBSession() async throws -> [CopyAllItem] {
        if let session = usb.session, session.isOpen, session.catalogComplete, !session.removed, !session.linkStalled {
            log.note("  guided: using the open USB session (\(session.files.count) files)")
        } else {
            log.note("  guided: Image Transfer (MSC) lists the card in about 7 s and downloads a little faster than MTP (65 s to list)")
            try await prepareMode("Image Transfer (MSC) or (MTP)")
            try await openSession(wait: true)
            // A session already open without waiting for the catalogue (the Wired tab's toggle off): openSession
            // returns at once ("Session already open"), so wait for the catalogue here.
            if let s = usb.session, s.isOpen, !s.catalogComplete {
                try await waitUntil("Waiting for the catalogue",
                                    "ImageCaptureCore is still listing the card (about 7 s in MSC, 65 s in MTP).",
                                    timeout: 900) {
                    self.usb.session?.catalogComplete == true || self.usb.session?.removed == true
                        || self.usb.session?.linkStalled == true
                }
            }
        }
        guard let session = usb.session, session.isOpen, session.catalogComplete else {
            throw GuidedStop("the USB session isn't open with the card catalogued (see the log)")
        }
        let items = session.copyAllItems
        guard !items.isEmpty else { throw GuidedStop("no ARW on the card (\(session.files.count) files)") }
        return items
    }

    /// A Wi-Fi session with the card listed, preferably Sony's whole-card contents transfer (the only session that has
    /// listed the whole card so far). Returns the ARW to copy.
    private func copyAllWiFiSession() async throws -> [CopyAllItem] {
        try await ensureWiFiSessionForCopy()
        try await reconnectWiFiIfDropped()
        if wireless.contentsMode != .wholeCard {
            let choice = try await ask("Whole-card session?",
                                       "The open Wi-Fi session isn't Sony's whole-card contents transfer, which is the session that lists the whole card (PC Remote). Reconnect in it?",
                                       buttons: ["Reconnect for the whole card", "Use this session"])
            if choice.hasPrefix("Reconnect") {
                try await wifi("Contents transfer: whole card",
                               "SDIO_OpenSession, Sony's init sequence and the transfer mode, then waiting while the camera indexes the card (up to about 2 minutes).",
                               timeout: 180) {
                    wireless.connectContentsTransfer(wifiTarget(), mode: .wholeCard)
                }
            }
            guard wireless.isConnected else { throw GuidedStop("not connected: \(wireless.connectionState)") }
        }
        if wireless.objects.isEmpty {
            try await wifi("List card", "GetStorageIDs, GetObjectHandles, then GetObjectInfo for every object.", timeout: 900) { wireless.listCard() }
        }
        let items = wireless.copyAllItems
        guard !items.isEmpty else { throw GuidedStop("no ARW listed (\(wireless.objects.count) objects; see the log)") }
        return items
    }

    /// isConnected stays true after a silent drop (the camera slept, or the app was away while a folder was chosen):
    /// reconnects in the same kind of session, which empties the list, so the caller lists the card again. True when it
    /// reconnected.
    @discardableResult
    private func reconnectWiFiIfDropped() async throws -> Bool {
        guard let c = wireless.client else { return false }
        let failure = await c.linkFailure
        guard failure != nil else { return false }
        try await wifi("Reconnect", "The Wi-Fi session had dropped; reconnecting in the same kind of session.", timeout: 180) {
            wireless.reconnect(wifiTarget())
        }
        guard wireless.isConnected else { throw GuidedStop("couldn't reconnect: \(wireless.connectionState)") }
        return true
    }
}
