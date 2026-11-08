// swift-tools-version: 6.2
import PackageDescription

// The app's screens and its composition root. The view models (`@Observable`, main actor), the copy, the selection
// and filter rules, the destination setting's store, the Copy as JPEG source rule and its temporary folders are plain
// Swift and Foundation, so they build and test on Linux against fakes (links, discovery, catalogue, Photos access,
// destinations). The SwiftUI screens, the pasteboard, the share sheet, Core Image and ImageIO, OSLog, UIKit, the
// `USBCameraBrowser` conformance and the composition root's live half (the SwiftData catalogue, the Photos library,
// the USB camera key) sit behind `#if canImport(...)`. Section 6 of docs/iteration-1-backlog.md: Cameras,
// Browse (selection, filters, the last-known card, the already-imported badge, Copy as JPEG and Share as JPEG…),
// Import and Settings.
let package = Package(
    name: "AppUI",
    platforms: [
        // iOS 27 is the app's deployment target; tools 6.2 has no `.v27` case, hence the string form. macOS 26 is
        // only so `swift test` runs on a Mac (see AGENTS.md, "Platforms").
        .iOS("27.0"), .macOS(.v26),
    ],
    products: [
        .library(name: "AppUI", targets: ["AppUI"]),
    ],
    dependencies: [
        .package(path: "../ImportEngine"),
        // The Cameras screen shows what discovery finds (`CameraDescriptor`, `USBMode`), which doesn't pass through
        // the engine.
        .package(path: "../CameraTransport"),
        // Browse reads the catalogue directly (the last-known card, the already-imported badge), and the Import and
        // Settings screens use PhotosBridge's destination rule and destinations.
        .package(path: "../Catalogue"),
        .package(path: "../PhotosBridge"),
        // For AppUITests only: the models driven end to end against the simulated camera (`SimulatedCameraLink`).
        // No product of this package names the simulator; PTPSimulator is a test-only package.
        .package(path: "../PTPSimulator"),
    ],
    targets: [
        .target(
            name: "AppUI",
            dependencies: [
                .product(name: "ImportEngine", package: "ImportEngine"),
                .product(name: "CameraTransport", package: "CameraTransport"),
                .product(name: "Catalogue", package: "Catalogue"),
                .product(name: "PhotosBridge", package: "PhotosBridge"),
            ]
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: [
                "AppUI",
                .product(name: "SimulatedLink", package: "PTPSimulator"),
                // The scripted card the simulated link serves.
                .product(name: "PTPSimulator", package: "PTPSimulator"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
