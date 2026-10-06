import AppKit

/// Acceptance only: a PNG of one of Chilk's OWN windows as the window server composited it — SwiftUI content, glass,
/// controls and all. No Screen Recording is needed for an app's own windows. `CGWindowListCreateImage` is obsoleted in
/// the macOS 15 SDK but still exported, so it is looked up at run time; `cacheDisplay` draws SwiftUI windows empty.
@MainActor
enum WindowSnapshot {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// `false` = not written.
    @discardableResult
    static func write(_ window: NSWindow, to url: URL) -> Bool {
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let create = createImage,
              let image = create(.null, includingWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?
                .takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? png.write(to: url)) != nil
    }
}
