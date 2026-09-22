// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CleanerCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"])
    ],
    targets: [
        .target(
            name: "CleanerCore",
            path: "Sources/CleanerCore"
        ),
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore"],
            path: "Tests/CleanerCoreTests"
        )
    ]
)
