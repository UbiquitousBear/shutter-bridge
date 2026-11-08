// swift-tools-version: 6.2
import PackageDescription

// The actor that runs an import job: its public surface, progress and selection. The five stages (discover, open,
// enumerate and diff, download, commit) and the pause, continue and retry rules (section 3 of
// docs/iteration-1-backlog.md) arrive in their own pull request. They are transport-neutral, so the engine has no
// Apple-only code and its tests run on Linux with fake links, stores and destinations.
let package = Package(
    name: "ImportEngine",
    platforms: [
        // iOS 27 is the app's deployment target; tools 6.2 has no `.v27` case, hence the string form. macOS 26 is
        // only so `swift test` runs on a Mac (see AGENTS.md, "Platforms").
        .iOS("27.0"), .macOS(.v26),
    ],
    products: [
        .library(name: "ImportEngine", targets: ["ImportEngine"]),
    ],
    dependencies: [
        .package(path: "../CameraTransport"),
        .package(path: "../Catalogue"),
        .package(path: "../PhotosBridge"),
    ],
    targets: [
        .target(
            name: "ImportEngine",
            dependencies: [
                .product(name: "CameraTransport", package: "CameraTransport"),
                .product(name: "Catalogue", package: "Catalogue"),
                .product(name: "PhotosBridge", package: "PhotosBridge"),
            ]
        ),
        .testTarget(name: "ImportEngineTests", dependencies: ["ImportEngine"]),
    ],
    swiftLanguageModes: [.v6]
)
