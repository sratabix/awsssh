// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwssshApp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AwssshIcon",
            path: "Sources/AwssshIcon"
        ),
        .executableTarget(
            name: "AwssshApp",
            dependencies: ["AwssshIcon"],
            path: "Sources/AwssshApp"
        ),
        .executableTarget(
            name: "IconExport",
            dependencies: ["AwssshIcon"],
            path: "Sources/IconExport"
        ),
        .testTarget(
            name: "AwssshAppTests",
            dependencies: ["AwssshApp", "AwssshIcon"],
            path: "Tests/AwssshAppTests"
        ),
    ]
)
