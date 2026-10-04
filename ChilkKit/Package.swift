// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChilkKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ChilkCore", targets: ["ChilkCore"]),
        .library(name: "ChilkRender", targets: ["ChilkRender"]),
        .executable(name: "chilk-render", targets: ["chilk-render"]),
    ],
    targets: [
        // Pure, deterministic logic: springs, character simulation, edge placement. No AppKit.
        .target(name: "ChilkCore"),
        // CoreGraphics/CoreText renderer shared by the edge panel, the AppIcon tool and previews.
        .target(name: "ChilkRender", dependencies: ["ChilkCore"]),
        // Renders AppIcon PNGs and preview frames headlessly (no window server needed).
        .executableTarget(name: "chilk-render", dependencies: ["ChilkRender"]),
        .testTarget(name: "ChilkCoreTests", dependencies: ["ChilkCore"]),
        // Pixel-level checks of the renderer against the redraw logic (no ghost pixels).
        .testTarget(name: "ChilkRenderTests", dependencies: ["ChilkCore", "ChilkRender"]),
    ]
)
