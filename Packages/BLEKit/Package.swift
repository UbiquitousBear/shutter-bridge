// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BLEKit",
    platforms: [
        .iOS(.v26), .macOS(.v15),
    ],
    products: [
        .library(name: "BLEKit", targets: ["BLEKit"]),
    ],
    targets: [
        .target(name: "BLEKit"),
        .testTarget(
            name: "BLEKitTests",
            dependencies: ["BLEKit"]
        ),
    ]
)
