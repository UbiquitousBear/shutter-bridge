// swift-tools-version: 6.2
import PackageDescription

// A fake camera for the integration suite, depending on PTPKit only (a test dependency of the other packages). For
// now the scripted card it serves, as pure Swift; the PTP/IP listener on Network.framework (section 7 of
// docs/iteration-1-backlog.md) arrives in its own pull request behind `#if canImport(Network)`.
let package = Package(
    name: "PTPSimulator",
    platforms: [
        // iOS 27 is the app's deployment target; tools 6.2 has no `.v27` case, hence the string form. macOS 26 is
        // only so `swift test` runs on a Mac (see AGENTS.md, "Platforms").
        .iOS("27.0"), .macOS(.v26),
    ],
    products: [
        .library(name: "PTPSimulator", targets: ["PTPSimulator"]),
    ],
    dependencies: [
        .package(path: "../PTPKit"),
    ],
    targets: [
        .target(
            name: "PTPSimulator",
            dependencies: [.product(name: "PTPKit", package: "PTPKit")]
        ),
        .testTarget(name: "PTPSimulatorTests", dependencies: ["PTPSimulator"]),
    ],
    swiftLanguageModes: [.v6]
)
