import AppKit

/// The whole of a long answer (decision 2026-10-05): opened by «Подробнее» under his bubble, beside him.
/// Scrolls, the text can be selected and copied; Esc, a click elsewhere or Chilk leaving closes it.
@MainActor
final class AnswerPanel {
    private var panel: Panel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var text = ""

    var isOpen: Bool { panel != nil }

    /// - Parameters: `chilk` — his window on screen; `edge` — the side he lives on (the panel opens towards the middle).
    func show(_ text: String, beside chilk: NSRect, onLeftEdge: Bool) {
        close()
        self.text = text
        let width: CGFloat = 420, pad: CGFloat = 16, buttonHeight: CGFloat = 28
        let font = NSFont.systemFont(ofSize: 14)
        let body = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Self.ink])
        let textHeight = ceil(body.boundingRect(with: NSSize(width: width - 2 * pad - 10, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 12
        let screen = NSScreen.screens.first { $0.frame.intersects(chilk) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? chilk
        let height = min(textHeight + 3 * pad + buttonHeight, min(520, screen.height - 40))
        var x = onLeftEdge ? chilk.maxX - 40 : chilk.minX - width + 40
        x = min(max(x, screen.minX + 12), screen.maxX - width - 12)
        var y = chilk.midY - height / 2
        y = min(max(y, screen.minY + 12), screen.maxY - height - 12)

        let panel = Panel(contentRect: NSRect(x: x, y: y, width: width, height: height))
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.paper.cgColor
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 2
        root.layer?.borderColor = Self.ink.cgColor

        let scroll = NSScrollView(frame: NSRect(x: pad, y: 2 * pad + buttonHeight - 4, width: width - 2 * pad,
                                                height: height - 3 * pad - buttonHeight + 4))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textStorage?.setAttributedString(body)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        root.addSubview(scroll)

        let copy = NSButton(title: String(localized: "Скопировать"), target: self, action: #selector(copyAll))
        copy.bezelStyle = .rounded
        copy.sizeToFit()
        copy.frame.origin = NSPoint(x: width - pad - copy.frame.width, y: pad)
        root.addSubview(copy)

        panel.contentView = root
        panel.onResignKey = { [weak self] in self?.close() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.close(); return nil }                                       // Esc
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
                if view.selectedRange().length > 0 { view.copy(nil) } else { self.copyAll() }
                return nil
            }
            return event
        }
        // A click in another app does not always take key from a non-activating panel: close on it explicitly.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        guard let panel else { return }
        self.panel = nil
        panel.onResignKey = nil
        panel.orderOut(nil)
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Sticker palette from SPEC (В31, В32): dark outline, light paper.
    private static let ink = NSColor(srgbRed: 0x2B / 255, green: 0x29 / 255, blue: 0x38 / 255, alpha: 1)
    private static let paper = NSColor(srgbRed: 1, green: 0.98, blue: 0.96, alpha: 1)

    /// Borderless and non-activating (the user's app keeps focus), but it can take keys: Esc and ⌘C work.
    private final class Panel: NSPanel {
        var onResignKey: (() -> Void)?
        init(contentRect: NSRect) {
            super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
            isReleasedWhenClosed = false
            hidesOnDeactivate = false
        }
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func resignKey() {
            super.resignKey()
            onResignKey?()
        }
    }
}
