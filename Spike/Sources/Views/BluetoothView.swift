import SwiftUI

/// Day 6 over Bluetooth LE: what the camera advertises in each power state and pairing context (snapshot →
/// Fixtures/a7c2/ble/), which service UUID the proximity reminder filters on, and the proximity go/no-go test
/// itself (background scan, relaunch, reminder, action). Every button logs to the Log tab.
struct BluetoothView: View {
    @Environment(SpikeLog.self) private var log
    @Environment(ProximityWatcher.self) private var watcher
    /// Created by the app and shared with the Guided tab's runner.
    @Environment(AdvertisementScanner.self) private var scanner
    /// Build 10: created by the app and shared with the Guided tab's runner.
    @Environment(SonyWiFiHandover.self) private var handover
    /// For Read details and join: the same join as the guided runs' (NEHotspotConfiguration, redacted).
    @Environment(WirelessLab.self) private var wireless
    @AppStorage(ProximityWatcher.Keys.serviceUUID) private var serviceUUID = ""
    @AppStorage("ble.snapshot.power") private var powerRaw = AdvertisementScanner.PowerState.on.rawValue
    @AppStorage("ble.snapshot.pairing") private var pairingRaw = AdvertisementScanner.PairingContext.connected.rawValue
    @State private var typedUUID = ""
    @State private var confirmKill = false
    @State private var gattCandidate: UUID?
    @State private var confirmWiFiOn = false
    /// The redacted description of the last Wi-Fi details read (lengths and yes/no only); the values aren't kept.
    @State private var handoverDetails: String?
    /// Read details and join is running (it spans several handover operations and the join).
    @State private var joiningOverBluetooth = false
    /// Read details and join's outcome in one redacted line: never the network's name or password.
    @State private var bluetoothJoinOutcome: String?

    private var power: AdvertisementScanner.PowerState { AdvertisementScanner.PowerState(rawValue: powerRaw) ?? .on }
    private var pairing: AdvertisementScanner.PairingContext {
        AdvertisementScanner.PairingContext(rawValue: pairingRaw) ?? .connected
    }

    var body: some View {
        NavigationStack {
            List {
                advertisementSection
                seenSection
                filterSection
                proximitySection
                gattSection
                handoverSection
            }
            .navigationTitle("Bluetooth")
            .confirmationDialog("Open a GATT connection to this peripheral?", isPresented: gattDialogShown, titleVisibility: .visible) {
                Button("List services") {
                    if let id = gattCandidate { scanner.listServices(id) }
                    gattCandidate = nil
                }
                Button("Cancel", role: .cancel) { gattCandidate = nil }
            } message: {
                Text("Experimental: connects, lists service UUIDs only (no characteristic reads or writes) and disconnects. Creators' App may notice the connection.")
            }
        }
        .confirmationDialog("Kill the app to test a Bluetooth relaunch?", isPresented: $confirmKill, titleVisibility: .visible) {
            Button("Kill app", role: .destructive) { watcher.terminateForRelaunchTest() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Switch the camera off for a minute first. The app ends as if the system had stopped it; the latency is measured from this tap. Lock the phone and switch the camera on straight away, wait for the reminder, then reopen the app and check the log for willRestoreState.")
        }
        .task {
            scanner.log = log
            await watcher.refreshNotificationStatus()
        }
        .onChange(of: serviceUUID) { _, _ in
            watcher.serviceUUIDChanged()
        }
    }

    // MARK: - Day 6 · BLE advertisement

    private var advertisementSection: some View {
        Section("Day 6 · BLE advertisement") {
            LabeledContent("Scanner", value: scanner.state)
            Picker("Camera power", selection: $powerRaw) {
                ForEach(AdvertisementScanner.PowerState.allCases) { state in
                    Text(state.label).tag(state.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Picker("Pairing", selection: $pairingRaw) {
                ForEach(AdvertisementScanner.PairingContext.allCases) { context in
                    Text(context.label).tag(context.rawValue)
                }
            }
            Button("Scan (Sony only)") { scanner.log = log; scanner.start(sonyOnly: true) }
                .disabled(scanner.gattBusy)
            Button("Scan (everything)") { scanner.log = log; scanner.start(sonyOnly: false) }
                .disabled(scanner.gattBusy)
            Button("Stop and summarise") { scanner.stop() }
                .disabled(!scanner.isScanning || scanner.gattBusy)
            Button("Save snapshot") {
                scanner.saveSnapshot(power: power, pairing: pairing, proximityUUID: serviceUUID.isEmpty ? nil : serviceUUID)
            }
            .disabled(scanner.scanStartedAt == nil || scanner.gattBusy)
            Button("Check connected (other apps)") { scanner.checkConnected(extra: serviceUUID.isEmpty ? nil : serviceUUID) }
                .disabled(scanner.gattBusy)
            ForEach(scanner.connected) { c in
                Text("Connected to the system: \(c.name) [\(String(c.identifier.prefix(8)))] · \(c.state)\(c.isCamera ? " · camera" : "")")
                    .font(.caption)
            }
            Text("For each power state (camera on, asleep, powered off with Bluetooth Function and Remote Power ON/OFF on) and pairing context: set both pickers, Scan, wait 30 s or more, Save snapshot. It writes ble/advert-\(power.rawValue).json and ble/advert-\(power.rawValue)-\(pairing.rawValue).json and records ble.advert.\(power.rawValue).\(pairing.rawValue).seen, .rssi and .interval, and ble.connected.\(power.rawValue).\(pairing.rawValue).seen. If the camera isn't listed, try Scan (everything) and mark it by hand.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Seen

    private var seenSection: some View {
        Section("Seen (\(scanner.rows.count) of \(scanner.trackedCount))") {
            if scanner.rows.isEmpty {
                Text(scanner.isScanning ? "Nothing yet. Is the camera's Bluetooth Function on?" : "Not scanning.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.rows) { row in
                peripheralRow(row)
            }
        }
    }

    private func peripheralRow(_ row: AdvertisementScanner.Row) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if row.isMarked { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    Text(row.name).font(.headline)
                    if row.isCamera { Text("camera-like").font(.caption2).foregroundStyle(.tint) }
                }
                Text(statsLine(row)).font(.caption).monospacedDigit()
                Text("id \(String(row.id.uuidString.prefix(8))) · services: \(row.serviceUUIDs.isEmpty ? "none" : row.serviceUUIDs.joined(separator: ", "))")
                    .font(.caption)
                if !row.overflowUUIDs.isEmpty {
                    Text("overflow: \(row.overflowUUIDs.joined(separator: ", "))").font(.caption)
                }
                if !row.solicitedUUIDs.isEmpty {
                    Text("solicited: \(row.solicitedUUIDs.joined(separator: ", "))").font(.caption)
                }
                ForEach(row.serviceData, id: \.self) { line in
                    Text("data \(line)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if let mfg = row.manufacturerHex {
                    Text("mfg \(row.companyID ?? "") \(mfg)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if let gatt = row.gattServices {
                    Text("GATT services: \(gatt.isEmpty ? "none" : gatt.joined(separator: ", "))").font(.caption)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button(row.isMarked ? "Unmark as camera" : "Mark as camera") { scanner.toggleMarked(row.id) }
                ForEach(filterOptions(row), id: \.self) { uuid in
                    Button("Use \(uuid) as proximity filter") { serviceUUID = uuid }
                }
                Button("List services (GATT)…") { gattCandidate = row.id }
                    .disabled(scanner.gattBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// Advertised and overflow service UUIDs of a row, without duplicates. GATT-listed ones are left out: a
    /// background scan can't filter on a service the camera only shows after connecting.
    private func filterOptions(_ row: AdvertisementScanner.Row) -> [String] {
        Array(Set(row.serviceUUIDs + row.overflowUUIDs)).sorted()
    }

    private func statsLine(_ row: AdvertisementScanner.Row) -> String {
        var parts = ["×\(row.count)"]
        if let avg = row.rssiAverage, let lo = row.rssiMin, let hi = row.rssiMax {
            parts.append(String(format: "RSSI %.0f dBm (%ld…%ld)", avg, lo, hi))
        }
        if let interval = row.intervalMs { parts.append(String(format: "~%.0f ms", interval)) }
        if let tx = row.txPower { parts.append("tx \(tx)") }
        if let c = row.connectable { parts.append(c ? "connectable" : "not connectable") }
        parts.append("last \(row.lastSeen.formatted(date: .omitted, time: .standard))")
        return parts.joined(separator: " · ")
    }

    // MARK: - Day 6 · Proximity filter

    private var filterChoices: [String] {
        var choices = scanner.advertisedServiceUUIDs
        if !serviceUUID.isEmpty, !choices.contains(serviceUUID) { choices.append(serviceUUID) }
        return choices
    }

    private var filterSection: some View {
        Section("Day 6 · Proximity filter") {
            LabeledContent("Service UUID") {
                Text(serviceUUID.isEmpty ? "none" : serviceUUID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            if !filterChoices.isEmpty {
                Picker("Advertised", selection: $serviceUUID) {
                    Text("None").tag("")
                    ForEach(filterChoices, id: \.self) { uuid in
                        Text(uuid).font(.caption.monospaced()).tag(uuid)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            TextField("Or type one (FE2C or 128-bit)", text: $typedUUID)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.caption.monospaced())
            Button("Use typed UUID") {
                if let uuid = ProximityWatcher.normalizedServiceUUID(typedUUID) {
                    serviceUUID = uuid
                    typedUUID = ""
                } else {
                    log.warn("Not a service UUID: \"\(typedUUID)\" (4 or 8 hex digits, or a 128-bit UUID)")
                }
            }
            .disabled(typedUUID.isEmpty)
            Button("Clear filter", role: .destructive) { serviceUUID = "" }
                .disabled(serviceUUID.isEmpty)
            Text("Choose the UUID the camera advertises in every power state; background scans can only filter on a service UUID. It goes in the measurements table's BLE row.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Day 6 · Proximity go/no-go

    private var proximitySection: some View {
        Section("Day 6 · Proximity go/no-go") {
            Toggle("Watch in background", isOn: Binding(get: { watcher.enabled }, set: { watcher.setEnabled($0) }))
            LabeledContent("Bluetooth", value: watcher.centralState)
            LabeledContent("Scan", value: watcher.isScanning ? watcher.scanFilter : "not scanning")
            LabeledContent("Notifications", value: watcher.notificationStatus)
            Stepper(value: Binding(get: { watcher.debounceSeconds }, set: { watcher.setDebounce($0) }), in: 10 ... 1800, step: 10) {
                Text("Debounce: \(Int(watcher.debounceSeconds)) s")
            }
            Button("Camera switched on now") { watcher.markCameraSwitchedOn() }
                .disabled(!watcher.enabled)
            if let on = watcher.switchedOnAt {
                LabeledContent("Switched on", value: switchedOnText(on))
            }
            Button("Re-arm scan") { watcher.rearmNow() }
                .disabled(!watcher.enabled)
            Button("Send test reminder") { watcher.sendTestNotification() }
            detail("Last discovery", watcher.lastDiscovery)
            detail("Last connection event", watcher.lastConnectionEvent)
            detail("Last action", watcher.lastAction)
            detail("Restoration", watcher.restoration)
            if let until = watcher.snoozedUntil, until > Date() {
                LabeledContent("Snoozed until", value: until.formatted(date: .abbreviated, time: .shortened))
                Button("Clear snooze") { watcher.clearSnooze() }
            }
            Button("Kill app to test relaunch", role: .destructive) { confirmKill = true }
                .disabled(!watcher.enabled)
            Text("Pick the filter UUID, switch on Watch in background (allow Bluetooth and notifications), switch the camera off for a minute, then tap Camera switched on now as you switch it on and lock the phone. Wait for the reminder and pick an action. Repeat from the next room, with Creators' App connected and quit, and after Kill app to test relaunch (camera off first; Kill app re-arms the measurement like Camera switched on now, so lock the phone and switch the camera on straight away). Don't swipe the spike away in the app switcher: iOS won't relaunch an app the user force-quit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func switchedOnText(_ on: Date) -> String {
        var waiting: [String] = []
        if watcher.discoveryLatencyPending { waiting.append("discovery") }
        if watcher.connectionLatencyPending { waiting.append("connection event") }
        let time = on.formatted(date: .omitted, time: .standard)
        return waiting.isEmpty ? time : "\(time) · waiting for \(waiting.joined(separator: ", "))"
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }

    // MARK: - Experimental · GATT

    private var gattSection: some View {
        Section("Experimental · GATT") {
            LabeledContent("Status", value: scanner.gattStatus)
            Text("Only if the camera advertises no service UUID while paired: a row's … menu → List services opens a GATT connection to the camera, lists its service UUIDs (no characteristic reads or writes) and disconnects. Creators' App may notice the connection.")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Experimental · Wi-Fi handover

    /// Every action logs what it measured; failures are logged by SonyWiFiHandover itself, so the buttons drop them.
    private var handoverSection: some View {
        Section("Experimental · Wi-Fi handover") {
            LabeledContent("Status") {
                Text(handover.status).font(.caption)
            }
            if let hint = handover.lastPairingHint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
            Button("Connect + discover") {
                Task {
                    do {
                        _ = try await handover.connect()
                        _ = try await handover.discover()
                    } catch {}
                }
            }
            .disabled(handover.busy)
            Button("Safe reads") {
                Task { _ = try? await handover.safeReads() }
            }
            .disabled(handover.busy || !handover.isConnected)
            Button("Subscribe (Sony's set)") {
                Task { _ = try? await handover.subscribe(SonyWiFiHandover.sonyNotificationCodes) }
            }
            .disabled(handover.busy || !handover.isConnected)
            Button("Subscribe (all 8000CC00)") {
                Task { _ = try? await handover.subscribe(nil) }
            }
            .disabled(handover.busy || !handover.isConnected)
            Button("Notification summary") {
                _ = handover.timelineSummary()
            }
            .disabled(handover.busy || !handover.isConnected)
            Button("Forget CC09 status byte") {
                handover.forgetRememberedStatusByte("Bluetooth tab")
            }
            .disabled(handover.busy)
            Button("Switch camera Wi-Fi on…") { confirmWiFiOn = true }
                .disabled(handover.busy || !handover.isConnected)
                .confirmationDialog("Switch the camera's Wi-Fi on?", isPresented: $confirmWiFiOn, titleVisibility: .visible) {
                    Button("Write 0x01 to CC08") {
                        Task { _ = try? await handover.switchWiFiOn() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Experimental: writes the single byte 0x01 to characteristic CC08 in service 8000CC00, which reverse-engineered notes (unverified on this camera) say switches the camera's Wi-Fi on. It is the only value the spike writes over Bluetooth; the app also turns on the camera's status notifications (CC09) if they aren't on, and Disconnect turns every notification off. The app then waits up to 30 s for the camera to report its Wi-Fi as on. Creators' App may notice.")
                }
            Button("Read Wi-Fi details") {
                Task {
                    if let credentials = try? await handover.readCredentials() {
                        handoverDetails = credentials.description
                    }
                }
            }
            .disabled(handover.busy || !handover.isConnected)
            if let handoverDetails {
                Text(handoverDetails).font(.caption)
            }
            Button(joiningOverBluetooth ? "Joining…" : "Read details and join") {
                joiningOverBluetooth = true
                bluetoothJoinOutcome = nil
                Task {
                    let outcome = await readDetailsAndJoin()
                    log.note("Bluetooth tab: Read details and join: \(outcome)")
                    bluetoothJoinOutcome = outcome
                    joiningOverBluetooth = false
                }
            }
            .disabled(joiningOverBluetooth || handover.busy || wireless.joining)
            if let bluetoothJoinOutcome {
                Text(bluetoothJoinOutcome).font(.caption)
            }
            Button("Disconnect", role: .destructive) {
                handoverDetails = nil
                bluetoothJoinOutcome = nil
                Task {
                    // Notifications off first, waiting for the camera's answers; while an operation runs, Disconnect
                    // cancels it at once and turns them off without waiting.
                    if !handover.busy && handover.isConnected
                        && (handover.notifyingCount > 0 || !handover.earlierLinkCodes.isEmpty) {
                        _ = try? await handover.unsubscribeAll()
                    }
                    handover.disconnect()
                }
            }
            .disabled(!handover.isConnected && !handover.busy)
            Text("Connects to the camera over Bluetooth (the link Creators' App holds, or a scan), lists every characteristic, reads only firmware, model and status, on request turns on the camera's notifications (Sony's set: CC09, CC10, CC0F, CC03, CC0E; or every one in 8000CC00; logged masked, turned off on Disconnect; Forget CC09 status byte makes the next run learn which byte of CC09 is the Wi-Fi status again), switches the camera's Wi-Fi on and reads the network name and password. Read details and join connects if needed, reads them (nothing written), disconnects Bluetooth again if it connected, and joins that network, then sets the Wi-Fi tab to Camera AP with the join's gateway as Camera IP; the camera's Wi-Fi network must be up (PC Remote). The name and password are never shown, logged or saved: only their lengths and yes/no checks, including whether they match what's typed on the Wi-Fi tab.")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// Read details and join: Connect + discover if not connected, the network details read, the join with them
    /// (WirelessLab.joinHandover), then Camera AP and the join's gateway as Camera IP, which is what the Wi-Fi tab's
    /// Join camera Wi-Fi and Use gateway as camera IP set. Returns a one-line outcome with no name or password; the
    /// details exist only in this call, made from the button's Task. Failures are also logged by the handover and
    /// HotspotJoiner themselves. Nothing is recorded under the handover run's ble.handover.* names (`ptpip.ap.join`
    /// says "Bluetooth tab"), and a Bluetooth link this call connected is dropped once the details are read, as the
    /// guided join does, so a later run connects on its own; a link that was already up is left as it is.
    private func readDetailsAndJoin() async -> String {
        guard !wireless.joining else { return "Not joined: another join is running" }
        let ownLink = !handover.isConnected
        let details: HandoverCredentials
        do {
            if ownLink {
                _ = try await handover.connect()
                _ = try await handover.discover(record: nil)
            }
            details = try await handover.readCredentials(record: nil)
        } catch {
            // Not while another operation runs: Disconnect would cancel it.
            if ownLink && handover.isConnected && !handover.busy { handover.disconnect() }
            if let e = error as? HandoverError, case .readFailed = e {
                return "Not joined: \(e). Is the camera's Wi-Fi network up (PC Remote)? With none set up the camera refuses the read (ATT error 0x9D)."
            }
            return "Not joined: \(SonyWiFiHandover.errorName(error))"
        }
        // Bluetooth isn't needed for the join itself.
        if ownLink { handover.disconnect() }
        guard !details.ssid.isEmpty, HandoverCredentials.isValidPassphrase(details.passphrase) else {
            return "Not joined: the details read aren't usable (\(details.description))"
        }
        let network = "the camera's network (\(HotspotJoiner.ssidSummary(details.ssid)))"
        wireless.joinHandover(ssid: details.ssid, passphrase: details.passphrase, source: "Bluetooth tab, Read details and join")
        while wireless.joining {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let already = wireless.lastJoinAlreadyAssociated else {
            return "Not joined: the join to \(network) failed (see the log)"
        }
        UserDefaults.standard.set("ap", forKey: "ptpip.net")
        guard let gateway = wireless.lastJoinGateway else {
            return "Joined \(network)\(already ? " (already on it)" : ""), but no Wi-Fi path with a gateway came up within 20 s; network set to Camera AP, Camera IP unchanged"
        }
        UserDefaults.standard.set(gateway, forKey: "ptpip.host")
        return "Joined \(network)\(already ? " (already on it)" : ""); network Camera AP, Camera IP \(gateway)"
    }

    private var gattDialogShown: Binding<Bool> {
        Binding(get: { gattCandidate != nil }, set: { if !$0 { gattCandidate = nil } })
    }
}
