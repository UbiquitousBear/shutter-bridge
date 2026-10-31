// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PTPKit",
    platforms: [
        .iOS(.v26), .macOS(.v15),
    ],
    products: [
        .library(name: "PTPKit", targets: ["PTPKit"]),
    ],
    targets: [
        .target(name: "PTPKit"),
        .testTarget(
            name: "PTPKitTests",
            dependencies: ["PTPKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
