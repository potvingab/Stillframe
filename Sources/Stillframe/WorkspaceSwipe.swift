import SwiftUI

struct TabSwipeGesture {
    private var distance = CGPoint.zero
    private var tracking = false

    mutating func begin(allowed: Bool) {
        distance = .zero
        tracking = allowed
    }

    mutating func update(x: CGFloat, y: CGFloat) -> WorkspaceTab? {
        guard tracking else { return nil }
        distance.x += x
        distance.y += y
        let horizontal = abs(distance.x), vertical = abs(distance.y)
        if vertical >= 12 && vertical > horizontal {
            tracking = false
        } else if horizontal >= 64 && horizontal > vertical * 1.6 {
            tracking = false
            return distance.x < 0 ? .collections : .pictures
        }
        return nil
    }
}

struct WorkspaceSwipe: NSViewRepresentable {
    let select: (WorkspaceTab) -> Void
    var back: (() -> Void)?
    func makeNSView(context: Context) -> SwipeView { SwipeView() }
    func updateNSView(_ view: SwipeView, context: Context) { view.select = select; view.back = back }
    static func dismantleNSView(_ view: SwipeView, coordinator: ()) { view.stop() }

    final class SwipeView: NSView {
        var select: ((WorkspaceTab) -> Void)?
        var back: (() -> Void)?
        private var gesture = TabSwipeGesture()
        private var monitor: Any?
        private var targetsBack = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.track(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            gesture.begin(allowed: false)
        }

        private func track(_ event: NSEvent) {
            guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  NSApp.modalWindow == nil, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
            if event.phase.contains(.began) {
                let point = event.locationInWindow
                let toolbar = Self.allowsTabSwipe(at: point, in: window)
                targetsBack = back != nil && Self.allowsBack(at: point, in: window)
                gesture.begin(allowed: targetsBack || toolbar)
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                gesture.begin(allowed: false)
            } else if event.phase.contains(.changed) || event.phase.contains(.began) {
                let x = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                if let tab = gesture.update(x: x, y: event.scrollingDeltaY) {
                    if targetsBack {
                        if tab == .pictures { back?() }
                    } else { select?(tab) }
                }
            }
        }

        static func allowsBack(at point: NSPoint, in window: NSWindow) -> Bool {
            window.contentLayoutRect.contains(point)
        }

        static func allowsTabSwipe(at point: NSPoint, in window: NSWindow) -> Bool {
            point.y >= window.contentLayoutRect.maxY && window.frame.contains(window.convertPoint(toScreen: point))
        }
    }
}
