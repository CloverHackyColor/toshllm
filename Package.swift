// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ToshLLM",
    platforms: [.macOS(.v14)],
	dependencies: [
        // Dev deps
        .package(url: "https://github.com/CloverHackyColor/toshllm.git", from: "0.0.1"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.55.5"),
    ],
    targets: [
        .executableTarget(name: "ToshLLM", path: "Sources"),
        .testTarget(name: "ToshLLMTests", dependencies: ["ToshLLM"], path: "Tests"),
    ]
)
