// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickDown",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "QuickDownCore",
            path: "Sources/QuickDownCore"
        ),
        .executableTarget(
            name: "QuickDown",
            dependencies: ["QuickDownCore"],
            path: "Sources/QuickDown"
        ),
        .executableTarget(
            name: "QuickDownCLI",
            dependencies: ["QuickDownCore"],
            path: "Sources/QuickDownCLI"
        ),
        .testTarget(
            name: "QuickDownCoreTests",
            dependencies: ["QuickDownCore"],
            path: "Tests/QuickDownCoreTests"
        ),
    ]
)
