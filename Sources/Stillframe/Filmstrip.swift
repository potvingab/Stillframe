import SwiftUI

// Fixed-size thumbnails let AppKit lay out any visible range directly, even at the end of a large folder.
final class FilmstripLayout: NSCollectionViewLayout {
    static let tile = CGSize(width: 84, height: 58)
    static let stride: CGFloat = 90

    static func indices(in rect: CGRect, count: Int) -> Range<Int> {
        guard count > 0, rect.width > 0 else { return 0..<0 }
        let start = Int(min(CGFloat(count), max(0, floor(rect.minX / stride))))
        let end = Int(min(CGFloat(count), max(CGFloat(start), ceil(rect.maxX / stride))))
        return start..<end
    }

    static func frame(at index: Int) -> CGRect {
        CGRect(origin: CGPoint(x: CGFloat(index) * stride, y: 0), size: tile)
    }

    override var collectionViewContentSize: NSSize {
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        let width = count > 0 ? Self.frame(at: count - 1).maxX : 0
        return NSSize(width: max(width, collectionView?.enclosingScrollView?.contentSize.width ?? 0), height: Self.tile.height)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let count = collectionView?.numberOfItems(inSection: 0) ?? 0
        return Self.indices(in: rect, count: count).compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = Self.frame(at: indexPath.item)
        return attributes
    }
}

// The clip view may propose its own width during a resize. Preserve the entire horizontal document.
private final class FilmstripCollectionView: NSCollectionView {
    var stripWidth: CGFloat = 0

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(NSSize(width: max(stripWidth, size.width), height: FilmstripLayout.tile.height))
    }
}

// Overlay the scrubber on the thumbnails even when macOS uses legacy scrollbars.
final class FilmstripViewport: NSView {
    static let barHeight: CGFloat = 14
    let scroll = FilmstripScroll()
    let bar = FilmstripBar(frame: NSRect(x: 0, y: 0, width: 240, height: barHeight))
    private var hideTimer: Timer?
    private var dragging = false
    private var lastOffset: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(scroll)
        addSubview(bar)
        bar.scrollerStyle = .legacy
        bar.controlSize = .small
        bar.target = self
        bar.action = #selector(scrub)
        bar.alphaValue = 0
        bar.setAccessibilityLabel("Filmstrip position")
        bar.trackingChanged = { [weak self] tracking in
            self?.dragging = tracking
            self?.reveal()
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        synchronize()
    }

    private var travel: CGFloat { max(0, (scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width) }

    func synchronize() {
        let range = travel
        bar.isEnabled = range > 0
        bar.isHidden = range <= 0
        guard range > 0 else { return }
        let width = scroll.contentView.bounds.width
        bar.knobProportion = width / (width + range)
        bar.doubleValue = min(1, max(0, scroll.contentView.bounds.minX / range))
    }

    @objc private func scrolled() {
        synchronize()
        let offset = scroll.contentView.bounds.minX
        guard offset != lastOffset else { return }
        lastOffset = offset
        if window != nil { reveal() }
    }

    func reveal() {
        guard !bar.isHidden else { return }
        bar.alphaValue = 1
        if dragging {
            hideTimer?.invalidate()
            hideTimer = nil
        } else if let hideTimer {
            hideTimer.fireDate = Date(timeIntervalSinceNow: 1.35)
        } else {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hideTimer = nil
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                        self.bar.animator().alphaValue = 0
                    }
                }
            }
        }
    }

    @objc func scrub(_ sender: NSScroller) {
        let clip = scroll.contentView
        let x: CGFloat
        switch sender.hitPart {
        case .decrementPage: x = clip.bounds.minX - clip.bounds.width
        case .incrementPage: x = clip.bounds.minX + clip.bounds.width
        case .decrementLine: x = clip.bounds.minX - FilmstripLayout.stride
        case .incrementLine: x = clip.bounds.minX + FilmstripLayout.stride
        default: x = travel * sender.doubleValue
        }
        clip.scroll(to: NSPoint(x: min(travel, max(0, x)), y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
        synchronize()
        reveal()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hideTimer?.invalidate()
            hideTimer = nil
            bar.alphaValue = 0
        }
    }
}

final class FilmstripBar: NSScroller {
    var trackingChanged: ((Bool) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.01 ? super.hitTest(point) : nil
    }
    override func scrollWheel(with event: NSEvent) {
        (superview as? FilmstripViewport)?.scroll.scrollWheel(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        trackingChanged?(true)
        defer { trackingChanged?(false) }
        super.mouseDown(with: event)
    }
}

final class FilmstripScroll: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView, documentView.frame.width > contentView.bounds.width else {
            super.scrollWheel(with: event)
            return
        }
        let x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let delta = abs(x) >= abs(y) ? x : y
        guard delta != 0 else { return }
        (superview as? FilmstripViewport)?.reveal()
        let offset = delta * (event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll)
        let bounds = contentView.bounds
        let position = min(documentView.frame.width - bounds.width, max(0, bounds.minX - offset))
        contentView.scroll(to: NSPoint(x: position, y: bounds.minY))
        reflectScrolledClipView(contentView)
    }
}

struct Filmstrip: NSViewRepresentable {
    static let scrollIdentifier = NSUserInterfaceItemIdentifier("FilmstripScroll")
    let photos: PhotoList
    let selected: Int
    let library: Library
    var accent = Palette.accent
    let onSelect: (String) -> Void
    let onOpen: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FilmstripViewport {
        let viewport = FilmstripViewport()
        let scroll = viewport.scroll
        scroll.identifier = Self.scrollIdentifier
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .none

        let grid = FilmstripCollectionView()
        grid.autoresizingMask = [.height]
        grid.collectionViewLayout = FilmstripLayout()
        grid.backgroundColors = [.clear]
        grid.isSelectable = true
        grid.allowsEmptySelection = false
        grid.register(FilmstripCell.self, forItemWithIdentifier: FilmstripCell.identifier)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.openItem(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        grid.addGestureRecognizer(doubleClick)
        grid.setAccessibilityLabel("Filmstrip")
        scroll.documentView = grid
        return viewport
    }

    func updateNSView(_ viewport: FilmstripViewport, context: Context) {
        guard let grid = viewport.scroll.documentView as? NSCollectionView else { return }
        context.coordinator.update(self, grid: grid)
        viewport.synchronize()
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        private var parent: Filmstrip
        private var revision: Int?
        private var updating = false

        init(_ parent: Filmstrip) { self.parent = parent }

        func update(_ next: Filmstrip, grid: NSCollectionView) {
            let reload = revision == nil || parent.photos !== next.photos
            let selectionChanged = reload || parent.selected != next.selected
            let marksChanged = revision != next.library.markRevision || parent.accent != next.accent
            parent = next
            revision = next.library.markRevision
            updating = true
            defer { updating = false }
            if reload {
                (grid as? FilmstripCollectionView)?.stripWidth = next.photos.isEmpty ? 0 : FilmstripLayout.frame(at: next.photos.count - 1).maxX
                grid.reloadData()
                if let layout = grid.collectionViewLayout {
                    grid.setFrameSize(layout.collectionViewContentSize)
                }
            } else if marksChanged {
                for case let cell as FilmstripCell in grid.visibleItems() {
                    if let index = grid.indexPath(for: cell)?.item { configure(cell, at: index) }
                }
            }
            guard selectionChanged, next.photos.indices.contains(next.selected) else { return }
            let path = IndexPath(item: next.selected, section: 0)
            if grid.selectionIndexPaths != [path] { grid.selectionIndexPaths = [path] }
            let target = FilmstripLayout.frame(at: next.selected)
            if !grid.visibleRect.contains(target) { grid.scrollToVisible(target) }
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.photos.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FilmstripCell.identifier, for: indexPath)
            if let cell = item as? FilmstripCell { configure(cell, at: indexPath.item) }
            return item
        }

        private func configure(_ cell: FilmstripCell, at index: Int) {
            let photo = parent.photos[index]
            cell.configure(photo: photo, accent: parent.accent, marks: parent.library.collections(containing: photo.id),
                           select: { [weak self] in self?.parent.onSelect(photo.id) },
                           open: { [weak self] in self?.parent.onOpen(photo.url) })
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !updating, let index = indexPaths.first?.item, parent.photos.indices.contains(index) else { return }
            parent.onSelect(parent.photos[index].id)
        }

        @objc func openItem(_ gesture: NSClickGestureRecognizer) {
            guard let grid = gesture.view as? NSCollectionView,
                  let index = grid.indexPathForItem(at: gesture.location(in: grid))?.item,
                  parent.photos.indices.contains(index) else { return }
            parent.onOpen(parent.photos[index].url)
        }
    }
}

private final class FilmstripCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmstripThumbnail")
    private var photo: Photo?
    private var accent = Palette.accent
    private var marks: [PhotoCollection] = []
    override var isSelected: Bool { didSet { if isSelected != oldValue { render() } } }

    override func loadView() {
        let host = ThumbnailHost(rootView: FilmstripTile(photo: photo, marks: marks, selected: isSelected, accent: accent))
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.button)
        view = host
    }

    func configure(photo: Photo, accent: Color, marks: [PhotoCollection], select: @escaping () -> Void, open: @escaping () -> Void) {
        self.photo = photo
        self.accent = accent
        self.marks = marks
        render()
        (view as? ThumbnailHost)?.press = select
        view.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Open in default app") { open(); return true }])
        view.setAccessibilityLabel(photo.url.lastPathComponent)
        view.setAccessibilityValue(marks.map(\.name).joined(separator: ", "))
        view.toolTip = ([photo.url.lastPathComponent] + marks.map(\.name)).joined(separator: "\n")
    }

    private func render() {
        view.setAccessibilitySelected(isSelected)
        (view as? ThumbnailHost)?.rootView = FilmstripTile(photo: photo, marks: marks, selected: isSelected, accent: accent)
    }
}

private final class ThumbnailHost: NSHostingView<FilmstripTile> {
    var press: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}

private struct FilmstripTile: View {
    let photo: Photo?
    let marks: [PhotoCollection]
    let selected: Bool
    let accent: Color
    @ViewState private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let photo {
                FileImage(url: photo.url, modified: photo.modified)
                    .opacity(hovered ? 0.87 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            }
        }
        .background(Palette.mat)
        .overlay(alignment: .bottom) {
            if !marks.isEmpty {
                HStack(spacing: 1) {
                    ForEach(marks) { mark in Rectangle().fill(mark.color.tint) }
                }.frame(height: 5).background(.black.opacity(0.5))
                    .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.25)).frame(height: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(3)
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? accent : .clear, lineWidth: 2) }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
