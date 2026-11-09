import CameraTransport
import Foundation
import Synchronization

// The live composition's Wi-Fi connector (wireless plan W16): `WiFiConnecting` over W11's `WirelessSession` and W6's `IPLink`,
// built from the radio pieces through their protocols only (`GATTConnector`, `HotspotJoining`, `WiFiPathWatching`,
// `ForegroundSignal`, `ByteChannelFactory`). Plain Swift, so it is tested on Linux with fakes; the app hands it
// `BluetoothCentral` (through `OnDemandBluetooth`), `NEHotspotJoiner`, `NWPathGateway`, `SceneForegroundSignal` and
// `NWByteChannelFactory` (LiveRoot.swift).

/// Where a new link's events are forwarded before it opens (`WiFiCameraSource.observe(_:for:)`), so the Local Network wait
/// reported during `open()` is seen.
public protocol WiFiLinkObserving: AnyObject, Sendable {
    func observe(_ link: any CameraLink, for id: CameraDescriptor.ID) async
}

extension WiFiCameraSource: WiFiLinkObserving {}

/// The app's `WiFiConnecting`: one `WirelessSession` per camera on its own network, and the typed-address open on the
/// phone's network.
///
/// - Each camera's session is made once and kept, so the Wi-Fi recovery (`recoverySession(for:)`) reaches the session the
///   source opened the job's link through.
/// - Every link is an `IPLink` with the camera's initiator GUID (`WiFiCameraEntry.guid`, never changed), at
///   192.168.122.1:15740 for a paired camera or the typed address, opened only after the observer has its events, and closed
///   again when it doesn't open (so no half-open connection lingers between the session's tries).
/// - No serial is given to the link (`knownSerial` nil): the app keeps only the serial's hash, as the key, and the source
///   compares that after the open; within one link's life the link holds every reopen to the first session's serial.
/// - Every session and link records its steps to `trace` (W20; the app's is `TransportTrace.bench(_:)` over the bench log),
///   which changes nothing they do.
public final class WirelessConnections: WiFiConnecting, Sendable {
    private struct State {
        var sessions: [CameraDescriptor.ID: WirelessSession] = [:]
        weak var observer: (any WiFiLinkObserving)?
    }

    private let connector: any GATTConnector
    private let joiner: any HotspotJoining
    private let path: any WiFiPathWatching
    private let foreground: any ForegroundSignal
    private let channels: any ByteChannelFactory
    private let clock: any Clock<Duration>
    private let trace: TransportTrace
    private let state = Mutex(State())

    /// - Parameters:
    ///   - connector: Bluetooth (the app's one central, `OnDemandBluetooth`).
    ///   - joiner: NetworkExtension (`NEHotspotJoiner`).
    ///   - path: the Wi-Fi path (`NWPathGateway`).
    ///   - foreground: the scene (`SceneForegroundSignal`).
    ///   - channels: TCP (`NWByteChannelFactory`, Wi-Fi only).
    ///   - clock: the sessions' and the links' waits.
    ///   - trace: the sessions' and the links' bench-log events (`TransportTrace.bench(_:)` in the app).
    public init(connector: any GATTConnector, joiner: any HotspotJoining, path: any WiFiPathWatching,
                foreground: any ForegroundSignal, channels: any ByteChannelFactory,
                clock: any Clock<Duration> = ContinuousClock(), trace: TransportTrace = .none) {
        self.connector = connector
        self.joiner = joiner
        self.path = path
        self.foreground = foreground
        self.channels = channels
        self.clock = clock
        self.trace = trace
    }

    /// Forwards each new link's events to `observer` before the link opens (the source, once it exists). Held weakly.
    public func attach(observer: any WiFiLinkObserving) {
        state.withLock { $0.observer = observer }
    }

    public func session(for camera: WiFiCameraEntry) -> any WirelessControlling {
        state.withLock { s in
            if let made = s.sessions[camera.id] { return made }
            let made = WirelessSession(
                camera: WirelessCamera(peripheral: camera.peripheral), connector: connector, joiner: joiner, path: path,
                foreground: foreground,
                openLink: { [weak self] (reopening: Bool) async throws(CameraLinkFailure) -> any CameraLink in
                    guard let self else { throw CameraLinkFailure(.disconnected, detail: "wifi: the app let go") }
                    return try await self.openLink(for: camera, endpoint: .cameraNetwork, reopening: reopening)
                },
                clock: clock, trace: trace)
            s.sessions[camera.id] = made
            return made
        }
    }

    public func openTyped(_ address: TypedCameraAddress, for camera: WiFiCameraEntry) async throws(CameraLinkFailure)
        -> any CameraLink {
        try await openLink(for: camera, endpoint: address.endpoint, reopening: false)
    }

    /// The session made for the camera, as the Wi-Fi recovery uses it; nil before the camera was first opened, and for a
    /// typed-address camera (it joins nothing, so there is nothing to recover by Bluetooth).
    public func recoverySession(for id: CameraDescriptor.ID) -> (any WiFiRecoverySession)? {
        state.withLock { $0.sessions[id] }
    }

    /// How many sessions have been made (for tests).
    var sessionCount: Int { state.withLock { $0.sessions.count } }

    private func openLink(for camera: WiFiCameraEntry, endpoint: PTPIPEndpoint, reopening: Bool)
        async throws(CameraLinkFailure) -> any CameraLink {
        var configuration = IPLink.Configuration(guid: camera.guid, endpoint: endpoint)
        configuration.reopening = reopening
        let link = IPLink(descriptor: camera.descriptor, configuration: configuration, channels: channels, clock: clock,
                          trace: trace)
        let observer = state.withLock { $0.observer }
        await observer?.observe(link, for: camera.id)
        do throws(CameraLinkFailure) {
            try await link.open()
        } catch {
            await link.close()
            throw error
        }
        return link
    }
}
