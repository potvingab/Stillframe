import SwiftUI

extension ToolbarContent {
    @ToolbarContentBuilder func withoutSharedGlass() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

struct KeepToolbarInFullScreen: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.windowToolbarFullScreenVisibility(.visible)
        } else {
            content
        }
    }
}

struct HeaderCapsule: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 0.75).allowsHitTesting(false))
        }
    }
}

struct HeaderActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title)
        }.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11).frame(height: 30)
            .modifier(HeaderCapsule()).contentShape(Capsule())
    }
}

struct HeaderAction: View {
    let title: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { HeaderActionLabel(title: title, symbol: symbol) }
            .buttonStyle(.plain).accessibilityLabel(title).fixedSize()
    }
}

struct WorkspaceSwitcher: View {
    let tab: WorkspaceTab
    let select: (WorkspaceTab) -> Void
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 1) {
            ForEach(WorkspaceTab.allCases, id: \.self) { item in
                Button { select(item) } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .labelStyle(.titleAndIcon).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item == tab ? Palette.ink : Palette.secondary)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background {
                            if item == tab {
                                Capsule().fill(Color.primary.opacity(0.10))
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7))
                                    .matchedGeometryEffect(id: "activeTab", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(item == tab ? .isSelected : [])
                    .keyboardShortcut(item == .pictures ? "1" : "2")
            }
        }.padding(3).fixedSize().modifier(HeaderCapsule())
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: tab)
    }
}

// Draw a small reflection inside each native button and let AppKit draw its color and hover glyph.
struct WindowLightHighlights: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.scheduleInstall() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.removeHighlights() }

    final class Probe: NSView {
        private var highlights: [Reflection] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleInstall()
        }
        func scheduleInstall() {
            DispatchQueue.main.async { [weak self] in self?.install() }
        }
        func removeHighlights() {
            for highlight in highlights { highlight.removeFromSuperview() }
            highlights.removeAll()
        }
        private func install() {
            guard let window else { removeHighlights(); return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            if highlights.count == buttons.count && zip(highlights, buttons).allSatisfy({ $0.superview === $1 }) { return }
            removeHighlights()
            for button in buttons {
                let reflection = Reflection(frame: button.bounds)
                reflection.autoresizingMask = [.width, .height]
                reflection.setAccessibilityElement(false)
                button.addSubview(reflection)
                highlights.append(reflection)
            }
        }
    }

    private final class Reflection: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                    center.addObserver(self, selector: #selector(redraw), name: name, object: window)
                }
            }
        }
        @objc private func redraw() { needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            guard window?.isMainWindow == true, (superview as? NSButton)?.isEnabled == true,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
            let diameter = min(13, bounds.width, bounds.height)
            let shine = NSRect(x: bounds.midX - diameter * 0.31, y: bounds.midY + diameter * 0.12,
                               width: diameter * 0.62, height: diameter * 0.28)
            NSGradient(starting: .white.withAlphaComponent(0.52), ending: .white.withAlphaComponent(0.04))?
                .draw(in: NSBezierPath(ovalIn: shine), angle: -90)
        }
    }
}
