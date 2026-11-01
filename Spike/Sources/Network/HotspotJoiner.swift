import Foundation
import NetworkExtension

/// Day 9: join the camera's access point with NEHotspotConfiguration (the user confirms a system prompt), then
/// wait for the phone's Wi-Fi path to come up on the new network and report its gateway: on the camera's own AP
/// the gateway is the camera (Sony uses 192.168.122.1). Needs the Hotspot Configuration entitlement
/// (Spike.entitlements has it).
///
/// The passphrase is never logged; log lines show "••••".
@MainActor
enum HotspotJoiner {
    struct Outcome: Sendable {
        let alreadyAssociated: Bool
        /// From calling apply to a Wi-Fi path with a gateway on the new network (includes the user's tap on the
        /// system prompt).
        let seconds: Double?
        let gateway: String?
    }

    /// Applies the configuration and waits up to 20 s for the new Wi-Fi path. Records `ptpip.ap.join` for a real
    /// join; `alreadyAssociated` counts as success but is not timed (forget the network in Settings to time it).
    static func join(ssid rawSSID: String, passphrase: String, log: SpikeLog) async -> Outcome? {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            log.warn("Join: enter or scan an SSID first")
            return nil
        }
        if !passphrase.isEmpty, passphrase.count < 8 || passphrase.count > 63 {
            log.warn("Join: a WPA passphrase must be 8–63 characters; this one isn't, so iOS will reject it")
        }
        let configuration = passphrase.isEmpty
            ? NEHotspotConfiguration(ssid: ssid)
            : NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        configuration.joinOnce = false

        // The Wi-Fi gateway before joining, so the wait below can tell the new network from the old one.
        let before = await PathMonitor.waitForWiFi(timeout: 0.5) { _ in true }
        let gatewayBefore: String? = (before?.isSatisfied ?? false) ? before?.firstIPv4Gateway : nil

        log.note("Join: applying NEHotspotConfiguration for \"\(ssid)\" (passphrase \(passphrase.isEmpty ? "none" : "••••")); confirm the system prompt. Gateway before: \(gatewayBefore ?? "none")")
        let clock = ContinuousClock()
        let started = clock.now
        var alreadyAssociated = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
        } catch {
            let ns = error as NSError
            if ns.domain == NEHotspotConfigurationErrorDomain, ns.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                alreadyAssociated = true
            } else {
                log.error(String(format: "Join failed after %.1f s: %@", (clock.now - started).inSeconds, describe(ns)))
                return nil
            }
        }
        let applied = (clock.now - started).inSeconds
        log.note(String(format: "Join: apply returned after %.1f s%@", applied, alreadyAssociated ? " (already associated with this network)" : ""))

        let isAlready = alreadyAssociated
        let snapshot = await PathMonitor.waitForWiFi(timeout: 20) { s in
            guard s.isSatisfied, let gateway = s.firstIPv4Gateway else { return false }
            return isAlready || gateway != gatewayBefore
        }
        let total = (clock.now - started).inSeconds

        if let current = await NEHotspotNetwork.fetchCurrent() {
            log.note("Join: current Wi-Fi is \"\(current.ssid)\" (BSSID \(current.bssid))")
        } else {
            log.note("Join: NEHotspotNetwork.fetchCurrent() returned nil (needs the Access Wi-Fi Information entitlement); SSID not confirmed")
        }

        guard let snapshot else {
            log.warn("Join: no Wi-Fi path with a new gateway within 20 s of apply returning (gateway before: \(gatewayBefore ?? "none")); not timed. Check Settings → Wi-Fi.")
            return Outcome(alreadyAssociated: alreadyAssociated, seconds: nil, gateway: nil)
        }
        let gateway = snapshot.firstIPv4Gateway
        if alreadyAssociated {
            log.note("Join: already on \"\(ssid)\"; gateway \(gateway ?? "?"). Not timed: forget the network in Settings → Wi-Fi to time a fresh join.")
        } else {
            log.measure("ptpip.ap.join", total, "s",
                        context: String(format: "\"%@\"; apply returned after %.1f s (includes the user's tap on the prompt); Wi-Fi path with gateway %@ after %.1f s",
                                        ssid, applied, gateway ?? "?", total))
        }
        log.note("Join: path now \(snapshot.summary). The first connection to the camera should show the Local Network prompt if it hasn't appeared yet.")
        return Outcome(alreadyAssociated: alreadyAssociated, seconds: alreadyAssociated ? nil : total, gateway: gateway)
    }

    /// Removes the configuration this app added (so the next join is a fresh one).
    static func forget(ssid: String, log: SpikeLog) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: trimmed)
        log.note("Join: removed this app's configuration for \"\(trimmed)\"")
    }

    private static func describe(_ error: NSError) -> String {
        guard error.domain == NEHotspotConfigurationErrorDomain else {
            return "\(error.domain) \(error.code): \(error.localizedDescription)"
        }
        let reason: String
        switch NEHotspotConfigurationError(rawValue: error.code) {
        case .some(.userDenied): reason = "the user tapped Cancel on the join prompt"
        case .some(.invalidSSID): reason = "invalid SSID"
        case .some(.invalidWPAPassphrase): reason = "invalid WPA passphrase"
        case .some(.pending): reason = "an earlier join is still pending"
        case .some(.systemConfiguration): reason = "system configuration error (Wi-Fi off? MDM?)"
        case .some(.applicationIsNotInForeground): reason = "app not in the foreground"
        case .some(.joinOnceNotSupported): reason = "joinOnce not supported here"
        case .some(.unknown): reason = "unknown error (the network may be out of range)"
        default: reason = "NEHotspotConfigurationError \(error.code)"
        }
        return "\(reason) [\(error.localizedDescription)]"
    }
}
