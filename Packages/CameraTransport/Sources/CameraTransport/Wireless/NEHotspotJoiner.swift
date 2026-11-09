#if canImport(NetworkExtension) && os(iOS)
import BLEKit
import Foundation
import NetworkExtension

/// Joins and leaves the camera's network with NetworkExtension's hotspot API: the real `HotspotJoining` that
/// `WirelessSession` is given in the app. Compiled only for iOS (CI's Xcode 27 job); its error mapping is
/// `HotspotErrorMapping`, tested on Linux. The spike's `HotspotJoiner` (day 9 and the Bluetooth hand-off runs) proved
/// these calls on the camera.
///
/// What it adds to the protocol's contract:
/// - `apply` builds `NEHotspotConfiguration(ssid:passphrase:isWEP: false)` with `joinOnce = false`: the configuration is
///   saved, so a second import inside the stay re-applies it without iOS's prompt (4 Nov 01:12), and a join-once
///   configuration is dropped soon after the app leaves the foreground (Apple's documentation), which an import that
///   carries on in the background can't allow. The name and password are used exactly as the camera gave them (no
///   trimming).
/// - "Already associated" is success. Every other error becomes a `JoinFailure` by its domain and code only: iOS's text is
///   dropped, so the network's name and password can't reach an error or a log through it. `JoinFailure` carries no text
///   at all, which is stricter than scrubbing the text the spike logged.
/// - Already associated through a configuration this app didn't make (the person joined the camera's network in Settings,
///   Wi-Fi): whether iOS saves this app's configuration then, and so whether `leave` removes anything and the phone leaves,
///   is `unverified`. The spike saw "already associated" only with its own configuration saved (bench check, Iteration 3,
///   week 1).
/// - A task cancelled before the call throws `.cancelled` without applying. Once iOS has the configuration, `apply` waits
///   for the person's answer whatever happens to the task: the prompt can't be withdrawn.
/// - Needs the Hotspot Configuration entitlement (`App/ShutterBridge.entitlements`) and the capability on the App ID.
///   Without the entitlement iOS refuses every `apply`; how is unverified (no build has run without it).
///
/// Never reads the current network (`NEHotspotNetwork.fetchCurrent()`): the session confirms a join by the camera's gateway
/// on the Wi-Fi path, and the app has no Access Wi-Fi Information entitlement.
public struct NEHotspotJoiner: HotspotJoining {
    public init() {}

    public func apply(_ credentials: SonyWiFiCredentials) async throws(JoinFailure) {
        if Task.isCancelled { throw .cancelled }
        let configuration = NEHotspotConfiguration(
            ssid: credentials.ssid, passphrase: credentials.passphrase, isWEP: false
        )
        configuration.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            let nsError = error as NSError
            if let failure = HotspotErrorMapping.failure(domain: nsError.domain, code: nsError.code) {
                throw failure
            }
            // Already associated: the phone is on the camera's network.
        }
    }

    /// Removes this app's configuration for `ssid`. In the spike the phone left the camera's network straight after the
    /// removal, with the app in front (0.1 s on 3 Nov 22:43, 0.2 s on 5 Nov 01:13). iOS gives no result, so the only
    /// confirmation is the Wi-Fi path. Removing it brings iOS's prompt back on the next join (4 Nov 01:08). An empty
    /// name does nothing. Whether this works with the app in the background is untested (backlog section 8:
    /// Iteration 3, week 1).
    public func leave(ssid: String) async {
        guard !ssid.isEmpty else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }
}
#endif
