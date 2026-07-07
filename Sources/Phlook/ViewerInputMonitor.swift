import AppKit

/// Local event monitor active only while the viewer is open.
/// Keys: ← → navigate, Esc closes, ⌘I toggles the sidebar.
/// Trackpad: horizontal two-finger swipe navigates (threshold + debounce).
@MainActor
final class ViewerInputMonitor {
    var onLeft: () -> Void = {}
    var onRight: () -> Void = {}
    var onEscape: () -> Void = {}
    var onToggleSidebar: () -> Void = {}
    var onDelete: () -> Void = {}
    var isSuspended: () -> Bool = { false }

    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var lastSwipe = Date.distantPast

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if self.isSuspended() { return event }
            switch event.type {
            case .keyDown:
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "i" {
                    self.onToggleSidebar(); return nil
                }
                switch event.keyCode {
                case 123: self.onLeft(); return nil    // ←
                case 124: self.onRight(); return nil   // →
                case 53:  self.onEscape(); return nil  // Esc
                case 51, 117: self.onDelete(); return nil  // Delete / Forward Delete
                default:  return event
                }
            case .scrollWheel:
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                self.accumulatedX += event.scrollingDeltaX
                if abs(self.accumulatedX) > 60,
                   Date().timeIntervalSince(self.lastSwipe) > 0.35 {
                    // Natural scrolling: swipe left (content moves left) → next item.
                    (self.accumulatedX > 0 ? self.onLeft : self.onRight)()
                    self.lastSwipe = Date()
                    self.accumulatedX = 0
                }
                if event.phase == .ended || event.momentumPhase == .ended {
                    self.accumulatedX = 0
                }
                return nil   // viewer swallows scroll; the grid must not move underneath
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
