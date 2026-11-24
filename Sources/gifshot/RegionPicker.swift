import AppKit

/// One transparent overlay per screen. Drag a rectangle, release to choose it; Esc cancels.
final class RegionPicker {
    /// `rect` is in global screen coordinates (points, bottom-left origin).
    typealias Completion = (_ selection: (rect: NSRect, screen: NSScreen)?) -> Void

    private let completion: Completion
    private var windows: [OverlayWindow] = []
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    init(completion: @escaping Completion) {
        self.completion = completion
    }

    func begin() {
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let window = OverlayWindow(frame: screen.frame)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onSelect = { [weak self] rect in
                self?.finish(with: (rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screen))
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }  // Esc
            return nil
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with selection: (rect: NSRect, screen: NSScreen)?) {
        guard !windows.isEmpty else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        previousApp?.activate()
        completion(selection)
    }
}

/// Borderless window that sits above everything and can take key focus.
class OverlayWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onSelect: ((NSRect) -> Void)?
    private var origin: NSPoint?
    private var selection: NSRect? { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        origin = clamped(event)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = clamped(event)
        selection = NSRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                           width: abs(point.x - origin.x), height: abs(point.y - origin.y)).integral
    }

    override func mouseUp(with event: NSEvent) {
        defer { origin = nil }
        guard let selection, selection.width >= 8, selection.height >= 8 else {
            self.selection = nil  // a click or a tiny drag: keep picking
            return
        }
        onSelect?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let scale = window?.backingScaleFactor ?? 1
        let label = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        let size = label.size(withAttributes: attributes)
        let y = selection.minY - size.height - 4 >= 0 ? selection.minY - size.height - 4 : selection.minY + 4
        label.draw(at: NSPoint(x: selection.minX, y: y), withAttributes: attributes)
    }

    private func clamped(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}

/// Thin red frame drawn just outside the region being recorded. gifshot excludes its own
/// windows from capture, so it never shows up in the GIF.
final class BorderWindow: OverlayWindow {
    static let width: CGFloat = 3

    init(around rect: NSRect, on screen: NSScreen) {
        super.init(frame: rect.insetBy(dx: -Self.width, dy: -Self.width).intersection(screen.frame))
        level = .statusBar
        ignoresMouseEvents = true
        sharingType = .none
        contentView = BorderView()
    }

    override var canBecomeKey: Bool { false }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: BorderWindow.width / 2, dy: BorderWindow.width / 2))
            path.lineWidth = BorderWindow.width
            path.stroke()
        }
    }
}
