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
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
        // Pinned to 1.1.x: single-maintainer library, patched at runtime for
        // fullscreen visibility (see DynamicNotchPromptWindow) — verify the
        // patch against upstream before bumping the minor.
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", .upToNextMinor(from: "1.1.0")),
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LoreKit",
            dependencies: [
                "ObjCExceptionCatcher",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ],
            path: "Sources/Lore",
            exclude: ["Info.plist", "Lore.entitlements", "Assets", "Resources"],
        ),
        .executableTarget(
            name: "LoreAppExecutable",
            dependencies: ["LoreKit"],
            path: "Sources/LoreApp"
        ),
        .testTarget(
            name: "LoreTests",
            dependencies: ["LoreKit"],
            path: "Tests/LoreTests"
        ),
    ]
)
