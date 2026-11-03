import Foundation
import NetworkExtension

/// Day 9: join the camera's access point with NEHotspotConfiguration (the user confirms a system prompt), then
/// wait for the phone's Wi-Fi path to come up on the new network and report its gateway: on the camera's own AP
/// the gateway is the camera (Sony uses 192.168.122.1). Needs the Hotspot Configuration entitlement
/// (Spike.entitlements has it).
///
/// The passphrase is never logged; log lines show "••••". The BSSID (a MAC address) never is either: only whether
/// it is present and MAC-shaped.
///
/// Build 10, Bluetooth handover (`redacted`): the SSID and passphrase were read from the camera over Bluetooth, and
/// the repository is public, so on that path the SSID, the BSSID and any error text that might quote them never
/// reach the log either: the SSID shows only as its length and whether it starts with "DIRECT-".
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
    ///
    /// `redacted`: the Bluetooth handover path (see the type's comment). `ptpip.ap.join` then carries `source` as its
    /// context ("Bluetooth handover" by default; the caller names the run or tab) and no SSID. `source` must never hold
    /// the SSID or passphrase.
    static func join(ssid rawSSID: String, passphrase: String, log: SpikeLog, redacted: Bool = false,
                     source: String = "Bluetooth handover") async -> Outcome? {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        // How the log names the network: the SSID itself on the typed or scanned path, never on the handover path.
        let network = redacted ? "the camera's network (\(ssidSummary(ssid)))" : "\"\(ssid)\""
        // Error texts on the handover path, in case NetworkExtension quotes the SSID or passphrase in one.
        let clean: (String) -> String = { text in
            redacted ? HotspotJoiner.scrub(text, ssid: ssid, passphrase: passphrase) : text
        }
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

        log.note("Join: applying NEHotspotConfiguration for \(network)\(redacted ? " from Bluetooth (\(source))" : "") (passphrase \(passphrase.isEmpty ? "none" : "••••")); confirm the system prompt. Gateway before: \(gatewayBefore ?? "none")")
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
                log.error(String(format: "Join failed after %.1f s: %@", (clock.now - started).inSeconds, clean(describe(ns))))
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
            if redacted {
                // Only yes/no answers about the joined network: its SSID and BSSID stay out of the log.
                log.note("Join: current Wi-Fi SSID is the handover's: \(current.ssid == ssid ? "yes" : "no"); BSSID \(current.bssid.isEmpty ? "absent" : "present, MAC-shaped \(isMACShaped(current.bssid) ? "yes" : "no")")")
            } else {
                // The BSSID is the access point's MAC address (the camera's, on its own network): never logged.
                log.note("Join: current Wi-Fi is \"\(current.ssid)\" (BSSID \(current.bssid.isEmpty ? "absent" : "present, MAC-shaped \(isMACShaped(current.bssid) ? "yes" : "no")"))")
            }
        } else {
            log.note("Join: NEHotspotNetwork.fetchCurrent() returned nil (needs the Access Wi-Fi Information entitlement); SSID not confirmed")
        }

        guard let snapshot else {
            log.warn("Join: no Wi-Fi path with a new gateway within 20 s of apply returning (gateway before: \(gatewayBefore ?? "none")); not timed. Check Settings → Wi-Fi.")
            return Outcome(alreadyAssociated: alreadyAssociated, seconds: nil, gateway: nil)
        }
        let gateway = snapshot.firstIPv4Gateway
        if alreadyAssociated {
            log.note("Join: already on \(network); gateway \(gateway ?? "?"). Not timed: forget the network in Settings → Wi-Fi to time a fresh join.")
        } else {
            log.measure("ptpip.ap.join", total, "s",
                        context: String(format: "%@; apply returned after %.1f s (includes the user's tap on the prompt); Wi-Fi path with gateway %@ after %.1f s",
                                        redacted ? source : "\"\(ssid)\"", applied, gateway ?? "?", total))
        }
        // The path summary lists IPv6 gateways too, and a link-local one can be built from the camera's MAC.
        let pathText = redacted ? "on Wi-Fi with IPv4 gateway \(gateway ?? "?") (full path left out on the handover path)" : snapshot.summary
        log.note("Join: path now \(pathText). The first connection to the camera should show the Local Network prompt if it hasn't appeared yet.")
        return Outcome(alreadyAssociated: alreadyAssociated, seconds: alreadyAssociated ? nil : total, gateway: gateway)
    }

    /// Build 11: whether the iPhone's current Wi-Fi network has a DIRECT- name (a camera's Wi-Fi Direct network);
    /// nil when iOS doesn't say (fetchCurrent answers only for networks this app configured, without the Access
    /// Wi-Fi Information entitlement). Only yes/no leaves this function: never the SSID or the BSSID.
    static func onDirectNetwork() async -> Bool? {
        guard let current = await NEHotspotNetwork.fetchCurrent() else { return nil }
        return current.ssid.hasPrefix("DIRECT-")
    }

    /// An SSID as the handover path logs it: "12 characters, DIRECT- prefix yes", never the name itself.
    nonisolated static func ssidSummary(_ ssid: String) -> String {
        "\(ssid.count) characters, DIRECT- prefix \(ssid.hasPrefix("DIRECT-") ? "yes" : "no")"
    }

    /// Six groups of one or two hex digits separated by ":" or "-" (iOS may drop leading zeros).
    nonisolated static func isMACShaped(_ text: String) -> Bool {
        let groups = text.split(separator: ":", omittingEmptySubsequences: false)
        let parts = groups.count == 6 ? groups : text.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { part in
            (1...2).contains(part.count) && part.allSatisfy { $0.isHexDigit }
        }
    }

    /// `text` with any occurrence of the SSID or passphrase replaced, for error texts on the handover path.
    private nonisolated static func scrub(_ text: String, ssid: String, passphrase: String) -> String {
        var out = text
        if !passphrase.isEmpty { out = out.replacingOccurrences(of: passphrase, with: "(passphrase)") }
        if !ssid.isEmpty { out = out.replacingOccurrences(of: ssid, with: "(SSID)") }
        return out
    }

    /// Removes the configuration this app added (so the next join is a fresh one). Apple promises to disassociate only
    /// for a joinOnce configuration (join uses joinOnce false), and a network saved in Settings keeps the iPhone on it,
    /// so whether the iPhone left has to be seen on the Wi-Fi path; removeConfiguration gives no result. `redacted`
    /// (build 14, the Bluetooth handover path, see the type's comment): the SSID shows in the log only as its length
    /// and whether it starts with "DIRECT-".
    static func forget(ssid: String, log: SpikeLog, redacted: Bool = false) {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: trimmed)
        let left = "iOS gives no result, and the iPhone may still be on the network"
        if redacted {
            log.note("Join: asked iOS to remove this app's configuration for the camera's network (\(ssidSummary(trimmed))); \(left)")
        } else {
            log.note("Join: asked iOS to remove this app's configuration for \"\(trimmed)\"; \(left)")
        }
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
