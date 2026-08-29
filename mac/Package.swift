// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SecondSight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SecondSightMac", targets: ["SecondSightMac"]),
        .library(name: "SecondSightCore", targets: ["SecondSightCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift", from: "2.0.0")
    ],
    targets: [
        // Keep protocol and safety policy deterministic and independently testable.
        .target(
            name: "SecondSightCore"
        ),
        .executableTarget(
            name: "SecondSightMac",
            dependencies: [
                "SecondSightCore",
                .product(name: "LiveKit", package: "client-sdk-swift")
            ]
        ),
        .testTarget(
            name: "SecondSightCoreTests",
            dependencies: ["SecondSightCore"]
        )
    ]
)
