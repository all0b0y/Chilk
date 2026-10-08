import AppKit

/// Transparent, borderless, never-key panel hugging a screen edge. Clicks pass through it
/// everywhere except Чилк's body (the controller toggles `ignoresMouseEvents` every frame).
final class EdgePanel: NSPanel {
    /// Slice 9d (decision 30): he belongs to one desktop, so a swipe takes him away with the old one instead of
    /// redrawing him on every desktop (the blink). The controller brings the window to the new desktop and he peeks out.
    /// Not in Exposé / Cmd-Tab. (Full-screen apps are desktops too: an accessory app's panel shows there — spike 9d.)
    static let oneDesk: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
    /// The way before slice 9d, kept for what is shown on every desktop: stages 3–4, a guided break, the shade, the
    /// eye-gymnastics flight.
    static let allDesks: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = Self.oneDesk
        isMovable = false
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Onto the active desktop. Through a throwaway marker ordered in there: a child window joins its parent's desktop
    /// and stays once let go (the same public trick as `move(toDeskOf:)`). Review 9d probe (`9d-fix/spike5`): toggling
    /// `.moveToActiveSpace` and setting the behavior back in the same pass leaves the window where it was; the marker
    /// moves it every time. On every desktop (`.canJoinAllSpaces`) he is already here: only ordered front — the two
    /// behaviors must never be combined (AppKit treats them as exclusive).
    func moveToActiveDesk() {
        guard !collectionBehavior.contains(.canJoinAllSpaces) else { return orderFrontRegardless() }
        let here = Self.marker(at: frame.origin)
        here.orderFrontRegardless()
        here.addChildWindow(self, ordered: .above)
        here.removeChildWindow(self)
        here.orderOut(nil)
        orderFrontRegardless()
    }

    /// Onto `home`'s desktop, even when it is not the active one (spike 9d: a child window joins its parent's desktop
    /// and stays there once let go).
    func move(toDeskOf home: NSWindow) {
        home.addChildWindow(self, ordered: .above)
        home.removeChildWindow(self)
    }

    /// An invisible 1 pt marker of his home desktop (one desk, decision 31): ordered in on the active desktop, it stays
    /// there; `isOnActiveSpace` says whether the user is home. `.stationary`: no part in Mission Control or «Show
    /// Desktop» (review 9d; probe `9d-fix/spike4`: at 1×1 and alpha 0 `isOnActiveSpace` is 1 on its desktop and 0 on
    /// another, and the child-window move still takes the panel there).
    static func homeMarker(at origin: CGPoint) -> NSPanel {
        let p = marker(at: origin)
        p.orderFrontRegardless()
        return p
    }

    private static func marker(at origin: CGPoint) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 1, height: 1)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.alphaValue = 0
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.canHide = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        return p
    }
}
