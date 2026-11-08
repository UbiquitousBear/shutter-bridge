// swift-tools-version: 6.2
import PackageDescription

// The import ledger: object identity, the store protocol and an in-memory store. The SwiftData models and their
// `ModelActor` (section 4 of docs/iteration-1-backlog.md) arrive in their own pull request, behind
// `#if canImport(SwiftData)`, so identity and the store's rules keep building and testing on Linux.
let package = Package(
    name: "Catalogue",
    platforms: [
        // iOS 27 is the app's deployment target; tools 6.2 has no `.v27` case, hence the string form. macOS 26 is
        // only so `swift test` runs on a Mac (see AGENTS.md, "Platforms").
        .iOS("27.0"), .macOS(.v26),
    ],
    products: [
        .library(name: "Catalogue", targets: ["Catalogue"]),
    ],
    dependencies: [
        // For `PTPMediaKind` (the format column) and to build an identity from a `PTPObjectIdentity`.
        .package(path: "../PTPKit"),
    ],
    targets: [
        .target(
            name: "Catalogue",
            dependencies: [.product(name: "PTPKit", package: "PTPKit")]
        ),
        .testTarget(name: "CatalogueTests", dependencies: ["Catalogue"]),
    ],
    swiftLanguageModes: [.v6]
)
