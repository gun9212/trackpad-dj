// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackpadDJ",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-atomics.git",
            exact: "1.2.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "TrackpadDJ",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Sources/TrackpadDJ"
        ),
        .testTarget(
            name: "TrackpadDJTests",
            dependencies: ["TrackpadDJ"]
        )
    ]
)
