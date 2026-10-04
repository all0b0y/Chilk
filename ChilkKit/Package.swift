// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChilkKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ChilkCore", targets: ["ChilkCore"]),
        .library(name: "ChilkRender", targets: ["ChilkRender"]),
        .library(name: "ChilkBrain", targets: ["ChilkBrain"]),
        .library(name: "ChilkEars", targets: ["ChilkEars"]),
        .executable(name: "chilk-render", targets: ["chilk-render"]),
        .executable(name: "chilk-voice", targets: ["chilk-voice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        // Pure, deterministic logic: springs, character simulation, balance director, edge placement. No AppKit.
        .target(name: "ChilkCore"),
        // CoreGraphics/CoreText renderer shared by the edge panel, the AppIcon tool and previews.
        .target(name: "ChilkRender", dependencies: ["ChilkCore"]),
        // Codex app-server client (JSON-RPC over stdio) and Чилк's isolated Codex profile. Foundation only.
        .target(name: "ChilkBrain", dependencies: ["ChilkCore"]),
        // WebRTC voice-activity detector, statically linked (vendored libfvad, BSD-3-Clause).
        .target(name: "CFvad", exclude: ["LICENSE", "PATENTS", "AUTHORS", "README.md"],
                publicHeadersPath: "include", cSettings: [.headerSearchPath(".")]),
        // One audio input shared by local wake recognition and live Apple dictation.
        .target(name: "ChilkEars", dependencies: ["ChilkCore", "CFvad", .product(name: "WhisperKit", package: "WhisperKit")]),
        .testTarget(name: "ChilkEarsTests", dependencies: ["ChilkEars", "ChilkCore"]),
        // Renders AppIcon PNGs and preview frames headlessly (no window server needed).
        .executableTarget(name: "chilk-render", dependencies: ["ChilkRender"]),
        // Voice/brain checks without the app: real Codex turns, dictation of audio files.
        .executableTarget(name: "chilk-voice", dependencies: ["ChilkBrain", "ChilkEars", "ChilkCore"]),
        .testTarget(name: "ChilkCoreTests", dependencies: ["ChilkCore"]),
        // Pixel-level checks of the renderer against the redraw logic (no ghost pixels).
        .testTarget(name: "ChilkRenderTests", dependencies: ["ChilkCore", "ChilkRender"]),
        // The Codex client against a scripted fake app-server.
        .testTarget(name: "ChilkBrainTests", dependencies: ["ChilkBrain"], exclude: ["FakeAppServer.py"]),
    ]
)
