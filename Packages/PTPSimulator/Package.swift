// swift-tools-version: 6.2
import PackageDescription

// A fake camera for the integration suite (section 7 of docs/iteration-1-backlog.md), test-only: nothing that ships
// depends on this package.
//
// - `PTPSimulator` depends on PTPKit only, as the workspace's rule says: the scripted card, the pure PTP responder and
//   PTP/IP core (tested on Linux), the captured α7C II datasets as resources, and the PTP/IP server on
//   Network.framework behind `#if canImport(Network)` (compiled and tested in the iOS Simulator by CI).
// - `SimulatedLink` is a second, test-support target: an in-process `CameraLink` over the scripted card that behaves
//   like ImageCaptureCore (suspension, removal, a slow catalogue, injected failures), so it also depends on
//   CameraTransport. It lives here rather than in CameraTransport so that no production package ever names the
//   simulator, and so the arrow keeps pointing from test support to production code.
// - `IntegrationTests` runs ImportEngine end to end against `SimulatedLink`; the suite lives here for now, which makes
//   this package a test-only leaf above the production graph. Other packages may still take `PTPSimulator` or
//   `SimulatedLink` as a test dependency: SwiftPM (tools 6.2, SwiftPM 6.4) accepts a package-level cycle when the
//   target graph has none. Confirm with Xcode's resolver before relying on that there.
let package = Package(
    name: "PTPSimulator",
    platforms: [
        // iOS 27 is the app's deployment target; tools 6.2 has no `.v27` case, hence the string form. macOS 26 is
        // only so `swift test` runs on a Mac (see AGENTS.md, "Platforms").
        .iOS("27.0"), .macOS(.v26),
    ],
    products: [
        .library(name: "PTPSimulator", targets: ["PTPSimulator"]),
        .library(name: "SimulatedLink", targets: ["SimulatedLink"]),
    ],
    dependencies: [
        .package(path: "../PTPKit"),
        .package(path: "../CameraTransport"),
        // For IntegrationTests only.
        .package(path: "../ImportEngine"),
        .package(path: "../Catalogue"),
        .package(path: "../PhotosBridge"),
    ],
    targets: [
        .target(
            name: "PTPSimulator",
            dependencies: [.product(name: "PTPKit", package: "PTPKit")],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "SimulatedLink",
            dependencies: [
                "PTPSimulator",
                .product(name: "PTPKit", package: "PTPKit"),
                .product(name: "CameraTransport", package: "CameraTransport"),
            ]
        ),
        .testTarget(name: "PTPSimulatorTests", dependencies: ["PTPSimulator"]),
        .testTarget(name: "SimulatedLinkTests", dependencies: ["SimulatedLink"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "SimulatedLink",
                "PTPSimulator",
                .product(name: "CameraTransport", package: "CameraTransport"),
                .product(name: "ImportEngine", package: "ImportEngine"),
                .product(name: "Catalogue", package: "Catalogue"),
                .product(name: "PhotosBridge", package: "PhotosBridge"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
