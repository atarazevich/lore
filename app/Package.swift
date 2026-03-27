// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Lore",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "LoreKit",
            targets: ["LoreKit"]
        ),
        .executable(
            name: "Lore",
            targets: ["LoreAppExecutable"]
        ),
        .executable(
            name: "Benchmark",
            targets: ["Benchmark"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        // Fork with relaxed swift-transformers constraint (from: "1.1.6" instead of upToNextMinor)
        // to allow coexistence with FluidAudio 0.12.5 which requires swift-transformers >= 1.2.0.
        // TODO: Switch back to argmaxinc/WhisperKit once upstream relaxes the constraint.
        .package(url: "https://github.com/yazins-ai/WhisperKit.git", branch: "fix/swift-transformers-compat"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "LoreKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "Sources/Lore",
            exclude: ["Info.plist", "Lore.entitlements", "Assets", "Resources"],
        ),
        .executableTarget(
            name: "LoreAppExecutable",
            dependencies: ["LoreKit"],
            path: "Sources/LoreApp"
        ),
        .executableTarget(
            name: "Benchmark",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Benchmark"
        ),
        .testTarget(
            name: "LoreTests",
            dependencies: ["LoreKit"],
            path: "Tests/LoreTests"
        ),
    ]
)
