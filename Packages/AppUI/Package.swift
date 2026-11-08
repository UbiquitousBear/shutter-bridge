// swift-tools-version: 6.2
import PackageDescription

// The app's screens. The view models (`@Observable`, main actor), the copy, the Copy as JPEG source rule and its
// temporary folders are plain Swift and Foundation, so they build and test on Linux against fake links. The SwiftUI
// screens, the pasteboard, the share sheet, Core Image and ImageIO, OSLog and the `USBCameraBrowser` conformance sit
// behind `#if canImport(...)`. Section 6 of docs/iteration-1-backlog.md: the thin Browse slice with Copy as JPEG
// and Share as JPEG… (8 Nov) is here; the full Browse, Import and Settings follow.
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
    ],
    targets: [
        .target(
            name: "AppUI",
            dependencies: [
                .product(name: "ImportEngine", package: "ImportEngine"),
                .product(name: "CameraTransport", package: "CameraTransport"),
            ]
        ),
        .testTarget(name: "AppUITests", dependencies: ["AppUI"]),
    ],
    swiftLanguageModes: [.v6]
)
