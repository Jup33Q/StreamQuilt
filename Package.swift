// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LKGQuilt",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LKGQuilt", targets: ["LKGQuilt"]),
        .executable(name: "lkg-demo", targets: ["lkg-demo"]),
        .executable(name: "lkg-ai-demo", targets: ["lkg-ai-demo"]),
    ],
    targets: [
        .target(
            name: "LKGQuilt",
            path: "Sources/LKGQuilt"
        ),
        .executableTarget(
            name: "lkg-demo",
            dependencies: ["LKGQuilt"],
            path: "Sources/lkg-demo"
        ),
        .executableTarget(
            name: "lkg-ai-demo",
            dependencies: ["LKGQuilt"],
            path: "Sources/lkg-ai-demo"
        ),
    ]
)
