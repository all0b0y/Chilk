import AppKit

/// Transparent, borderless, never-key panel hugging a screen edge. Clicks pass through it
/// everywhere except Чилк's body (the controller toggles `ignoresMouseEvents` every frame).
final class EdgePanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // Every Space, not in Exposé/Cmd-Tab. No .fullScreenAuxiliary: he stays out of fullscreen apps (тактичность).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
