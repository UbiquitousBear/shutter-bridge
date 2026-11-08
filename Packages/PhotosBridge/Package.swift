// swift-tools-version: 6.2
import PackageDescription

// Where imported files end up: the import destination protocol, its result and the Photos access rule. The Photos
// library destination (`PHAssetCreationRequest`) and the Files folder destination (section 5 of
// docs/iteration-1-backlog.md, decision 9) arrive in their own pull request, the first behind
// `#if canImport(Photos)`, so the shapes and rules keep building and testing on Linux.
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
