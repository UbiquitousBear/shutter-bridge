import Foundation
import ImageCaptureCore

// The guided *Copy all RAW to Files* run (Guided tab, group "Copy to Files"): every ARW on the card into a new folder
// in the Files app, over USB-C or Wi-Fi, inside a continued task. It calls the same functions as the Wired and Wi-Fi
// tabs' Copy all RAW to Files buttons. Nothing is written to the Photos library.

extension GuidedRunner {
    func copyAllToFiles() async throws {
        let destination = FilesDestination.shared
        if let paused = destination.paused {
            // Build 14: one pause record at a time; said before any setup (the session, the join, the folder).
            throw GuidedStop("a paused copy is waiting (\(paused.summary)): Continue copy or Discard it on the \(paused.link == "usb" ? "Wired" : "Wi-Fi") tab first")
        }
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
                              "On the camera: Network › Cnct./PC Remote › PC Remote Function on, with PC Remote Cnct Method set to Wi-Fi Direct (or Wi-Fi Access Point for your home network). That is the mode that lists the whole card; Smartphone Connect doesn't. You don't need to join the camera's network yourself: if no Wi-Fi session is open, the next step asks which network, and on the camera's own network the app joins it over Bluetooth (the QR code or Settings › Wi-Fi only if that doesn't work).",
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

        // Build 14, Wi-Fi only: Creators' App (context for every copy measurement) and whether a recovery may use
        // Bluetooth. Asked before the reconnect check below, since quitting Creators' App takes the tester out of the app.
        var recovery = CopyAllRecovery()
        if !overUSB { recovery = try await askCopyRecovery(onCameraNetwork: (wireless.sessionNet ?? wifiTarget().net) == "ap") }

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
        // Build 14: the screen, recorded with every copy measurement.
        let screen = try await ask("Keep the screen on?",
                                   "Keep the screen on during the copy? With the app in front the phone then doesn't lock by itself (Auto-Lock), so iOS doesn't suspend the app; the side button still locks it. Your answer goes with every copy measurement.",
                                   buttons: ["Keep the screen on during the copy", "Let it lock as set"])
        let keepOn = screen == "Keep the screen on during the copy"
        destination.keepScreenOn = keepOn
        let bytes = items.reduce(UInt64(0)) { $0 + $1.size }
        let minutes = max(1, Int((Double(bytes) / 1e6 / rate / 60).rounded(.up)))
        // Worded from the screen answer, so a copy recorded as "screen kept on" isn't run locked.
        let startHint = keepOn
            ? "Tap Start, then leave the app in front and don't lock the phone (the screen stays on)."
            : "Tap Start, then lock the phone once the copy shows on the Lock Screen or in the Dynamic Island: it carries on while locked."
        // checkSpace has resolved the folder (a chosen one that can't be used refuses above), so this is where they go.
        let go = try await ask("Ready to copy",
                               "\(items.count) ARW, \(CopyAllFormat.gb(bytes)), into \(destination.locationDescription): about \(minutes) min at \(Int(rate)) MB/s. \(startHint) Keep the camera on and \(overUSB ? "plugged in" : "close to the phone").",
                               buttons: ["Start", "Not now"])
        if go != "Start" { throw GuidedStop("not started") }
        let finishedBefore = destination.runsFinished
        let discardsBefore = destination.discards
        let returns = lifecycle.foregroundReturns
        let entries = lifecycle.backgroundEntries
        var pausesSeen = destination.pausesSaved
        try await startContinued("The copy") {
            if overUSB {
                usb.session?.copyAllARW(using: continued)
            } else {
                wireless.copyAllARW(recovery: recovery)
            }
        }

        // Until it ends: no limit shorter than an hour, then the choice to keep waiting. Build 14: if the copy pauses (iOS
        // ended its continued task: an expiry, or Stop in the Live Activity), the run asks, once the app is in front again,
        // whether the tester stopped it and whether to continue, and waits again. A Continue that leaves the copy still
        // paused (the session didn't come back, or the folder or the space refused it) is offered again.
        step("Copying \(items.count) ARW (about \(minutes) min)")
        let lockHint = keepOn
            ? "Leave the app in front and don't lock the phone (the screen stays on)"
            : "Lock the phone now if you like"
        var continuing = false
        // The last Continue: whether its continued task started, and why it didn't (GuidedStop's reason).
        var continueStarted = false
        var continueFailure: String?
        while true {
            do {
                while true {
                    let ended = try await waitUntil("Copying \(items.count) ARW",
                                                    "\(lockHint): the copy carries on, and this run picks up when it ends (about \(minutes) min). Cancel run stops it; what has been copied stays.",
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
            // Paused (a pause record for this link, and the copy didn't end or wasn't discarded on a tab)?
            guard destination.runsFinished == finishedBefore, destination.discards == discardsBefore,
                  let paused = destination.paused,
                  overUSB ? paused.link == "usb" : paused.link.hasPrefix("ptpip") else { break }
            let camera = overUSB ? "Keep the camera on and plugged in." : "Keep the camera on, with its Wi-Fi up and the phone on its network."
            let question: String
            // iOS ended the Continue's own continued task during its reconnect (an expiry, or Stop in the Live Activity):
            // no new pause is saved, so it is asked about here.
            let endedDuringReconnect = continuing && continueStarted && destination.pausesSaved == pausesSeen
                && continued.state == "expired by system"
            if destination.pausesSaved != pausesSeen || endedDuringReconnect {
                let newPause = destination.pausesSaved != pausesSeen
                pausesSeen = destination.pausesSaved
                if !lifecycle.isInForeground {
                    try await waitUntil("Copy paused", "iOS ended the copy's continued task at \(paused.done) of \(paused.total). Open the app to continue it.",
                                        timeout: 86_400) { self.lifecycle.isInForeground }
                }
                let when = newPause ? "at \(paused.done) of \(paused.total) (pause \(paused.pauses))"
                    : "again while Continue was getting the session back (the copy is still paused at \(paused.done) of \(paused.total))"
                // iOS runs the same expiration handler for Stop in the Live Activity as for an expiry: only you can tell.
                let who = try await ask("Copy paused",
                                        "iOS ended the copy's continued task \(when). Did you stop it from the Lock Screen or the Dynamic Island?",
                                        buttons: ["No, I didn't", "Yes, I stopped it"])
                let byTester = who == "Yes, I stopped it"
                // The lock row's value of this absence, held back until now (LifecycleMonitor.holdNextRecord).
                lifecycle.resolvePending(stoppedByTester: byTester)
                let which = newPause ? "this pause's expired flag" : "the expired flag recorded during Continue's reconnect"
                log.flag("\(paused.link).copyAll.pause.stoppedByTester", byTester,
                         context: "tester, \(newPause ? "pause \(paused.pauses)" : "during Continue's reconnect after pause \(paused.pauses), before anything was copied") at \(paused.done) of \(paused.total) ARW: " + (byTester ? "Stop in the Live Activity, so \(which) is the tester's Stop" : "not stopped by the tester, so \(which) is an iOS expiry"))
                question = "The copy is paused at \(paused.done) of \(paused.total). \(camera) Continue?"
            } else if continuing {
                // The Continue didn't take: why, if the continued task didn't start; otherwise the session didn't come
                // back, or the folder or the free space refused it.
                let cause = continueFailure.map { "Continue didn't get the copy going: \($0)." }
                    ?? "Continue didn't get the copy going (the session didn't come back, or the folder or the free space refused it; see the log)."
                question = "\(cause) The copy is still paused at \(paused.done) of \(paused.total). \(camera) Try again?"
            } else {
                break
            }
            let answer = try await ask("Copy paused", question, buttons: ["Continue", "Stop here"])
            if destination.discards != discardsBefore {
                // Discard on a tab while the question was open: the copy is over, with its measurements recorded.
                log.note("  guided: the paused copy was discarded on the \(tab) tab while this run asked about it")
                break
            }
            guard answer == "Continue" else {
                throw GuidedStop("the copy is paused at \(paused.done) of \(paused.total) and wasn't continued: Continue copy (or Discard) on the \(tab) tab")
            }
            // The answer is a tap, so a new continued task may be asked for.
            continuing = true
            continueStarted = false
            continueFailure = nil
            do {
                if overUSB {
                    // The session may need opening again (a long lock, a replug): about 7 s in MSC, 65 s in MTP.
                    step("Getting the USB session back")
                    let reopened = GuidedFlag()
                    Task {
                        await self.usb.continuePausedCopy(using: self.continued)
                        reopened.value = true
                    }
                    try await waitUntil("Opening the session",
                                        "Getting the USB session back if it didn't survive the pause: waiting for ImageCaptureCore's catalogue, about 7 s in MSC, 65 s in MTP (longer for a bigger card).",
                                        timeout: 900) { reopened.value }
                    try await startContinued("The continued copy") {}
                } else {
                    try await startContinued("The continued copy") { wireless.continuePausedCopy(recovery: recovery) }
                }
                continueStarted = true
                step("Copying the \(paused.remaining.count) ARW left (\(paused.done) of \(paused.total) done)")
            } catch let stop as GuidedStop {
                // Not started, or ended before it was seen running: the check above says whether the copy is still paused.
                log.note("  guided: \(stop.reason)")
                continueFailure = stop.reason
            }
        }
        if lifecycle.backgroundEntries > entries {
            log.note(String(format: "  guided: the app left the foreground during the copy%@", lifecycle.foregroundReturns > returns ? String(format: " (away %.0f s the last time)", lifecycle.lastAwaySeconds) : ""))
        }

        guard destination.runsFinished != finishedBefore || destination.discards != discardsBefore,
              let outcome = destination.lastOutcome else {
            if destination.paused != nil {
                throw GuidedStop("the paused copy couldn't be continued (see the log); it is still paused: Continue copy or Discard on the \(tab) tab")
            }
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

    /// Build 14, Wi-Fi: whether Creators' App is quit or open in the background, for the context of every copy
    /// measurement (on 3 Nov, with it open in the background, the camera dropped its card storage 28 s into a copy, then
    /// its session and its Wi-Fi; at 11:54 it dropped Wi-Fi and Bluetooth 30 s after a Bluetooth switch-on), with the
    /// suggestion to quit it; then, once, whether the copy may switch the camera's Wi-Fi back on over Bluetooth if it goes
    /// off. That answer is the confirmation for the one write (CC08 = 01); the Wi-Fi tab's button never allows it. On
    /// the home LAN the Bluetooth question isn't asked (the recovery uses Bluetooth on the camera's own network only).
    private func askCopyRecovery(onCameraNetwork: Bool) async throws -> CopyAllRecovery {
        var app = try await ask("Creators' App",
                                "Is Creators' App quit, or open in the background? With it open in the background the camera dropped its card, then its session and its Wi-Fi, 28 s into a copy (3 Nov), so quitting it is suggested. Your answer goes with every copy measurement.",
                                buttons: ["It's quit", "I'll quit it now", "Leave it open"])
        if app == "I'll quit it now" {
            let done = try await ask("Quit Creators' App",
                                     "Swipe up from the bottom of the screen and pause to open the App Switcher, swipe Creators' App up and away, then come back here and tap Done.",
                                     buttons: ["Done", "Leave it open"])
            app = done == "Done" ? "It's quit" : done
        }
        let creatorsApp = app == "It's quit" ? "Creators' App quit" : "Creators' App open in the background"
        guard onCameraNetwork else {
            let note = "Bluetooth recovery not used (home LAN)"
            log.note("  guided: copy conditions: \(creatorsApp); \(note)")
            return CopyAllRecovery(bluetooth: nil, creatorsApp: creatorsApp, bluetoothNote: note)
        }
        let bluetooth = try await ask("If the camera's Wi-Fi goes off",
                                      "If the camera's Wi-Fi goes off during the copy, may the app switch it back on over Bluetooth? This writes CC08 = 01 and turns on Sony's five status notifications, turned off afterwards. If the phone then doesn't rejoin the camera's network by itself while the app is open, the app also reads the network details over Bluetooth and asks iOS to join, so a Join prompt may appear. Either way the copy waits for the camera's card and network to come back and carries on (up to three times).",
                                      buttons: ["Allow", "Don't"])
        let allowed = bluetooth == "Allow"
        log.note("  guided: copy conditions: \(creatorsApp); Bluetooth recovery \(allowed ? "allowed (CC08 = 01 only if the camera's Wi-Fi goes off during the copy)" : "not allowed")")
        return CopyAllRecovery(bluetooth: allowed ? handover : nil, creatorsApp: creatorsApp)
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
    /// listed the whole card so far). With none open, the network is asked for and joined first (wifiJoin, through
    /// ensureWiFiSessionForCopy). Returns the ARW to copy.
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
