// swift-tools-version: 6.2
import PackageDescription

// Where imported files end up (section 5 of docs/iteration-1-backlog.md, decision 9): the import destination
// protocol, the RAW+JPEG pairing rule, the destination setting and the rule that picks Photos or Files, the Files
// folder destination (pure Foundation) and the Photos destination's logic over a `PhotoLibraryClient` protocol. The
// real Photos library (`SystemPhotoLibrary`, `PHAssetCreationRequest`) and ImageIO's metadata reader sit behind
// `#if canImport(...)`, so everything else builds and tests on Linux.
let package = Package(
    name: "PhotosBridge",
    platforms: [
        // iOS 27 is the app's deployment target; tools 6.2 has no `.v27` case, hence the string form. macOS 26 is
        // only so `swift test` runs on a Mac (see AGENTS.md, "Platforms").
        .iOS("27.0"), .macOS(.v26),
    ],
    products: [
        .library(name: "PhotosBridge", targets: ["PhotosBridge"]),
    ],
    targets: [
        .target(name: "PhotosBridge"),
        .testTarget(name: "PhotosBridgeTests", dependencies: ["PhotosBridge"]),
    ],
    swiftLanguageModes: [.v6]
)
