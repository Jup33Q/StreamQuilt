// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StreamQuilt",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StreamQuilt", targets: ["StreamQuilt"]),
        .executable(name: "sq-demo", targets: ["sq-demo"]),
        .executable(name: "sq-ai-demo", targets: ["sq-ai-demo"]),
        .executable(name: "streamquilt", targets: ["StreamQuiltApp"]),
    ],
    targets: [
        .target(
            name: "StreamQuilt",
            path: "Sources/StreamQuilt"
        ),
        .executableTarget(
            name: "sq-demo",
            dependencies: ["StreamQuilt"],
            path: "Sources/sq-demo"
        ),
        .executableTarget(
            name: "sq-ai-demo",
            dependencies: ["StreamQuilt"],
            path: "Sources/sq-ai-demo",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "StreamQuiltApp",
            dependencies: ["StreamQuilt"],
            path: "Sources/StreamQuiltApp",
            exclude: ["Info.plist"]
        ),
    ]
)
