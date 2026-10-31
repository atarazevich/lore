// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Lore",
    // LoreFormat and LoreCore also build for iOS (#305); everything else only ever builds for the Mac.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // The shared core the iOS app links (#305).
        .library(
            name: "LoreCore",
            targets: ["LoreFormat", "LoreCore"]
        ),
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
        // lore's files on disk and the command's wire: what the Mac app, the
        // iOS app and the `lore` command all read. Foundation only (#305).
        .target(
            name: "LoreFormat",
            path: "Sources/LoreFormat"
        ),
        // Transcription, speakers, storage and diagnostics, shared by the Mac
        // and iOS apps (#305). No AppKit, no CoreAudio HAL.
        .target(
            name: "LoreCore",
            dependencies: [
                "LoreFormat",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LoreCore"
        ),
        // The `lore` command's Mac-only pieces: processes, the socket, herdr.
        // Foundation only — the command links it, never FluidAudio.
        .target(
            name: "LoreCLIKit",
            dependencies: ["LoreFormat"],
            path: "Sources/LoreCLIKit"
        ),
        .target(
            name: "LoreKit",
            dependencies: [
                "ObjCExceptionCatcher",
                "LoreFormat",
                "LoreCore",
                "LoreCLIKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ],
            path: "Sources/Lore",
            exclude: ["Info.plist", "Lore.entitlements", "Assets"],
        ),
        .executableTarget(
            name: "LoreAppExecutable",
            dependencies: ["LoreKit"],
            path: "Sources/LoreApp"
        ),
        .executableTarget(
            name: "LoreCLI",
            dependencies: ["LoreCLIKit", "LoreFormat"],
            path: "Sources/LoreCLI",
            // `lore skill` prints it (#301). A link to skills/lore/SKILL.md at
            // the repo root, where `bunx skills add` finds the same file.
            resources: [.embedInCode("SKILL.md")]
        ),
        .testTarget(
            name: "LoreTests",
            dependencies: ["LoreKit", "LoreCore", "LoreFormat", "LoreCLIKit"],
            path: "Tests/LoreTests"
        ),
    ]
)
