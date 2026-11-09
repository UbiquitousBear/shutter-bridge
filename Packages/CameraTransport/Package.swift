// swift-tools-version: 6.2
import PackageDescription

// The camera links: the `CameraLink` protocol and the values it speaks in. `USBLink` and `USBCameraBrowser`
// (ImageCaptureCore, section 2 of docs/iteration-1-backlog.md) sit behind `#if canImport(ImageCaptureCore) && os(iOS)`
// with their pure logic outside it; `IPLink` (Network.framework, Iteration 3) follows the same rule, so the
// transport-neutral part keeps building and testing on Linux.
let package = Package(
    name: "CameraTransport",
    platforms: [
        // iOS 27 is the app's deployment target; tools 6.2 has no `.v27` case, hence the string form. macOS 26 is
        // only so `swift test` runs on a Mac (see AGENTS.md, "Platforms").
        .iOS("27.0"), .macOS(.v26),
    ],
    products: [
        .library(name: "CameraTransport", targets: ["CameraTransport"]),
    ],
    dependencies: [
        .package(path: "../PTPKit"),
        // Sony's Bluetooth values (CC09's entries, the network details, the CC08 write): the pure sequencers in
        // `Bluetooth/` are written against them (Iteration 3, W5).
        .package(path: "../BLEKit"),
    ],
    targets: [
        .target(
            name: "CameraTransport",
            dependencies: [
                .product(name: "PTPKit", package: "PTPKit"),
                .product(name: "BLEKit", package: "BLEKit"),
            ]
        ),
        .testTarget(name: "CameraTransportTests", dependencies: ["CameraTransport"]),
    ],
    swiftLanguageModes: [.v6]
)
