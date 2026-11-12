import CameraTransport
import Catalogue
import Foundation

/// Several camera sources as one (wireless plan W15): USB's browser and the Wi-Fi cameras today. The Cameras model reads
/// one stream, and a camera's link, key and failure text come from the source that listed it.
///
/// - **Events.** Each source's `discoveries` is read for the composite's life and passed on in the order it arrives,
///   after the composite has noted which source the camera belongs to. A camera's events keep their order (one source
///   sends them); different sources interleave as they happen.
/// - **Starting.** `start()` starts every source at once and waits for all of them; a source that fails doesn't stop
///   the others. If any failed, it throws the failure of the first one in `sources` order, so USB, listed first, keeps its
///   Camera Access message and its Try Again exactly as before, while the Wi-Fi cameras list regardless. Starting again
///   starts every source again (each ignores a start it has already made), which is what Try Again does after a source
///   failed.
/// - **Links.** `cameraLink(for:)` goes to the source that listed the camera, and throws `disconnected` for a camera no
///   source lists (it went away), as `USBCameraBrowser` does.
///
/// IDs are the sources' own and are assumed not to collide: USB's come from a device identifier, Wi-Fi's from an
/// initiator GUID with a `wifi-` prefix.
public actor CompositeDiscovery: CameraDiscovery {
    public nonisolated let discoveries: AsyncStream<CameraDiscoveryEvent>
    private let sink: AsyncStream<CameraDiscoveryEvent>.Continuation
    private let sources: [any CameraDiscovery]
    private var routes: [CameraDescriptor.ID: Int] = [:]
    private var relays: [Task<Void, Never>] = []

    /// - Parameter sources: In priority order: the first source's failure to start is the one the Cameras screen shows.
    public init(sources: [any CameraDiscovery]) {
        self.sources = sources
        (discoveries, sink) = AsyncStream.makeStream()
    }

    deinit {
        sink.finish()
        for relay in relays { relay.cancel() }
    }

    /// Each source's stream is read from the first `start()` on. A source buffers what it sends before then, so nothing
    /// is missed.
    private func startRelays() {
        guard relays.isEmpty else { return }
        relays = sources.enumerated().map { index, source in
            let stream = source.discoveries
            return Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    await self.relay(event, from: index)
                }
            }
        }
    }

    public func start() async throws(CameraLinkFailure) {
        startRelays()
        let sources = self.sources
        let failures = await withTaskGroup(of: (Int, CameraLinkFailure?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do throws(CameraLinkFailure) {
                        try await source.start()
                        return (index, nil)
                    } catch {
                        return (index, error)
                    }
                }
            }
            var failed: [Int: CameraLinkFailure] = [:]
            for await (index, failure) in group {
                if let failure { failed[index] = failure }
            }
            return failed
        }
        if let first = failures.keys.min(), let failure = failures[first] { throw failure }
    }

    public func cameraLink(for id: CameraDescriptor.ID) async throws(CameraLinkFailure) -> any CameraLink {
        guard let index = routes[id] else { throw CameraLinkFailure(.disconnected, detail: "composite: no source lists it") }
        return try await sources[index].cameraLink(for: id)
    }

    public func knownKey(for id: CameraDescriptor.ID) async -> CameraKey? {
        guard let index = routes[id] else { return nil }
        return await sources[index].knownKey(for: id)
    }

    public func openFailureText(for id: CameraDescriptor.ID) async -> String? {
        guard let index = routes[id] else { return nil }
        return await sources[index].openFailureText(for: id)
    }

    public func openWasDeclined(for id: CameraDescriptor.ID) async -> Bool {
        guard let index = routes[id] else { return false }
        return await sources[index].openWasDeclined(for: id)
    }

    /// From the source that listed the camera; a camera no source lists isn't connected.
    public func isConnected(_ id: CameraDescriptor.ID) async -> Bool {
        guard let index = routes[id] else { return false }
        return await sources[index].isConnected(id)
    }

    private func relay(_ event: CameraDiscoveryEvent, from index: Int) {
        switch event {
        case let .appeared(camera): routes[camera.id] = index
        case let .disappeared(id): routes[id] = nil
        }
        sink.yield(event)
    }
}
