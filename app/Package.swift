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
        // The `lore` command (#254). Not named `lore`: on a case-insensitive
        // volume that is the same file as `Lore` in .build and in Contents/MacOS.
        // build.sh copies it into the bundle as Contents/Helpers/lore.
        .executable(
            name: "lore-cli",
            targets: ["LoreCLI"]
        ),
    ],
    dependencies: [
        // Exact: pre-1.0 patches have changed ASR defaults. No traits: the NeMo normalizer serves TTS/ITN, never ASR (#269).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4", traits: []),
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
        // What the `lore` command and the app share: the wire and the words.
        // Foundation only — the command links it.
        .target(
            name: "LoreCLIKit",
            path: "Sources/LoreCLIKit"
        ),
        .target(
            name: "LoreKit",
            dependencies: [
                "ObjCExceptionCatcher",
                "LoreCLIKit",
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
        .executableTarget(
            name: "LoreCLI",
            dependencies: ["LoreCLIKit"],
            path: "Sources/LoreCLI"
        ),
        .testTarget(
            name: "LoreTests",
            dependencies: ["LoreKit", "LoreCLIKit"],
            path: "Tests/LoreTests"
        ),
    ]
)
