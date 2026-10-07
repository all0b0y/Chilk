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
        .library(name: "ChilkApple", targets: ["ChilkApple"]),
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
        .executableTarget(name: "chilk-voice", dependencies: ["ChilkBrain", "ChilkEars", "ChilkCore", "CFvad"]),
        .testTarget(name: "ChilkCoreTests", dependencies: ["ChilkCore"]),
        // Pixel-level checks of the renderer against the redraw logic (no ghost pixels).
        .testTarget(name: "ChilkRenderTests", dependencies: ["ChilkCore", "ChilkRender"]),
        // The Codex client against a scripted fake app-server.
        .testTarget(name: "ChilkBrainTests", dependencies: ["ChilkBrain"], exclude: ["FakeAppServer.py"]),
        // Slice 8a: adapters to Apple's apps (Reminders now; Calendar, Notes, the «Чилк» shortcut later).
        .target(name: "ChilkApple", dependencies: ["ChilkBrain"]),
        // A fake EventKit store calling back on its own queue, like EventKit. Swift 5 mode: the fake adds no runtime
        // isolation checks of its own, so a crash in the test is the adapter's.
        .target(name: "EventKitFakes", path: "Tests/EventKitFakes", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ChilkAppleTests", dependencies: ["ChilkApple", "EventKitFakes", "ChilkBrain"]),
    ]
)
