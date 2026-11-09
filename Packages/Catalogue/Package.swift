// swift-tools-version: 6.2
import PackageDescription

// The import ledger (section 4 of docs/iteration-1-backlog.md): object identity, the store protocol, an in-memory
// store, and the SwiftData schema (`CatalogueSchemaV1`, `CatalogueSchemaV2` since Iteration 3,
// `CatalogueMigrationPlan`) with its `ModelActor` store (`SwiftDataCatalogue`). The SwiftData part sits behind
// `#if canImport(SwiftData)`, so identity, the storage mapping and the store contract (run against the in-memory
// store) keep building and testing on Linux; CI runs the same contract against the SwiftData store in the iOS
// Simulator.
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
