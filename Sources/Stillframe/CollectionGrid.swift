import SwiftUI
import UniformTypeIdentifiers

struct CollectionGrid: NSViewRepresentable {
    enum Items: Equatable {
        case photos(PhotoList)
        case collections([PhotoCollection])

        var count: Int {
            switch self {
            case .photos(let list): return list.count
            case .collections(let list): return list.count
            }
        }
        func id(at index: Int) -> String {
            switch self {
            case .photos(let list): return list[index].id
            case .collections(let list): return list[index].id.uuidString
            }
        }
        func selectionPaths(for ids: Set<String>) -> Set<IndexPath> {
            guard !ids.isEmpty else { return [] }
            switch self {
            case .photos(let list):
                return Set(ids.compactMap { list.position(of: $0) }.map { IndexPath(item: $0, section: 0) })
            case .collections(let list):
                return Set(list.indices.filter { ids.contains(list[$0].id.uuidString) }.map { IndexPath(item: $0, section: 0) })
            }
        }
    }

    var items: Items
    @Binding var selected: Set<String>
    var accent = Palette.accent
    var selecting: Bool
    var open: (Int) -> Void
    var pictureMenu: ((URL) -> PictureMenuItems)?
    var edit: (PhotoCollection) -> Void = { _ in }
    var togglePin: (UUID) -> Void = { _ in }
    var delete: (PhotoCollection) -> Void = { _ in }

    init(items: PhotoList, selected: Binding<Set<String>>, selecting: Bool = false, accent: Color = Palette.accent,
         menuItems: ((URL) -> PictureMenuItems)? = nil, open: @escaping (URL) -> Void = { _ in }) {
        self.items = .photos(items)
        self.selecting = selecting
        _selected = selected
        self.accent = accent
        self.pictureMenu = menuItems
        self.open = { open(items[$0].url) }
    }

    init(collections: [PhotoCollection], choices: Binding<Set<UUID>>, selecting: Bool, open: @escaping (UUID) -> Void,
         edit: @escaping (PhotoCollection) -> Void, togglePin: @escaping (UUID) -> Void, delete: @escaping (PhotoCollection) -> Void) {
        items = .collections(collections)
        self.selecting = selecting
        _selected = Binding(get: { Set(choices.wrappedValue.map(\.uuidString)) },
                            set: { choices.wrappedValue = Set($0.compactMap(UUID.init(uuidString:))) })
        self.open = { open(collections[$0].id) }
        self.edit = edit
        self.togglePin = togglePin
        self.delete = delete
    }

    func makeCoordinator() -> Coordinator { Coordinator(selected: $selected) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let grid = OpenableGrid()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 2, left: 28, bottom: 8, right: 28)
        grid.collectionViewLayout = layout
        grid.backgroundColors = [.clear]
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.open = { [weak coordinator = context.coordinator] index in coordinator?.open(index) }
        grid.selectionChanged = { [weak coordinator = context.coordinator] grid in coordinator?.sync(grid) }
        grid.register(CollectionCoverCell.self, forItemWithIdentifier: CollectionCoverCell.identifier)
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.setDraggingSourceOperationMask(.copy, forLocal: true)
        grid.register(PictureCell.self, forItemWithIdentifier: PictureCell.identifier)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.autoresizingMask = [.width]
        scroll.documentView = grid
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let grid = scroll.documentView as? OpenableGrid else { return }
        let coordinator = context.coordinator
        coordinator.selected = $selected
        grid.selecting = selecting
        if case .photos = items { grid.exportsFiles = true } else { grid.exportsFiles = false }
        coordinator.open = open
        coordinator.pictureMenu = pictureMenu
        coordinator.edit = edit
        coordinator.togglePin = togglePin
        coordinator.delete = delete
        let reload = coordinator.items != items || coordinator.accent != accent
        coordinator.accent = accent
        guard reload || coordinator.appliedSelection != selected else { return }
        coordinator.reloading = true
        defer { coordinator.reloading = false }
        if reload {
            grid.resetTracking()
            coordinator.items = items
            grid.reloadData()
        }
        let paths = items.selectionPaths(for: selected)
        if grid.selectionIndexPaths != paths { grid.selectionIndexPaths = paths }
        coordinator.appliedSelection = selected
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var accent = Palette.accent
        var items: Items = .photos(PhotoList([]))
        var selected: Binding<Set<String>>
        var open: (Int) -> Void = { _ in }
        var pictureMenu: ((URL) -> PictureMenuItems)?
        var edit: (PhotoCollection) -> Void = { _ in }
        var togglePin: (UUID) -> Void = { _ in }
        var delete: (PhotoCollection) -> Void = { _ in }
        var reloading = false
        var appliedSelection: Set<String> = []

        init(selected: Binding<Set<String>>) { self.selected = selected }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let activate: () -> Void = { [weak collectionView] in
                (collectionView as? OpenableGrid)?.activate(indexPath)
            }
            switch items {
            case .photos(let photos):
                let cell = collectionView.makeItem(withIdentifier: PictureCell.identifier, for: indexPath)
                if let card = cell as? PictureCell {
                    card.accent = accent
                    card.activate = activate
                    card.menuItems = pictureMenu?(photos[indexPath.item].url)
                    card.photo = photos[indexPath.item]
                }
                return cell
            case .collections(let collections):
                let cell = collectionView.makeItem(withIdentifier: CollectionCoverCell.identifier, for: indexPath)
                if let card = cell as? CollectionCoverCell {
                    card.edit = edit
                    card.togglePin = togglePin
                    card.delete = delete
                    card.activate = activate
                    card.collection = collections[indexPath.item]
                }
                return cell
            }
        }

        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            let insets = (collectionViewLayout as? NSCollectionViewFlowLayout)?.sectionInset ?? NSEdgeInsets()
            let available = max(160, (collectionView.enclosingScrollView?.contentSize.width ?? 800) - insets.left - insets.right)
            let covers: Bool
            if case .collections = items { covers = true } else { covers = false }
            let columns = max(1, Int((available + 10) / (covers ? 230 : 180)))
            let width = floor((available - CGFloat(columns - 1) * 10) / CGFloat(columns))
            return NSSize(width: width, height: covers ? floor(width / 1.65) + 50 : floor(width * 0.72) + 30)
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { sync(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { sync(collectionView) }

        fileprivate func sync(_ grid: NSCollectionView) {
            guard !reloading else { return }
            appliedSelection = Set(grid.selectionIndexPaths.compactMap { (0..<items.count).contains($0.item) ? items.id(at: $0.item) : nil })
            selected.wrappedValue = appliedSelection
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard case .photos(let photos) = items, photos.indices.contains(indexPath.item) else { return nil }
            let url = photos[indexPath.item].url
            guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return url as NSURL
        }
    }
}

final class PictureCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CollectionPicture")
    var accent = Palette.accent
    var activate: () -> Void = {}
    var menuItems: PictureMenuItems?
    var photo: Photo? { didSet { updateCard() } }
    override var isSelected: Bool { didSet { if isSelected != oldValue { updateCard() } } }

    override func loadView() {
        view = NSHostingView(rootView: card)
    }

    private func updateCard() {
        (view as? NSHostingView<PictureCard>)?.rootView = card
    }
    private var card: PictureCard {
        PictureCard(photo: photo, selected: isSelected, accent: accent, activate: activate, menuItems: menuItems)
    }
}

private struct PictureCard: View {
    let photo: Photo?
    let selected: Bool
    let accent: Color
    let activate: () -> Void
    let menuItems: PictureMenuItems?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo {
                FileImage(url: photo.url, modified: photo.modified).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 4) {
                    Text(photo.url.lastPathComponent).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let menuItems {
                        CardMenu(title: "Picture actions") { menuItems }.frame(width: 28, height: 26)
                    }
                }.padding(.leading, 9).padding(.trailing, 4).frame(height: 30)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(Palette.ink)
            .background(selected ? accent.opacity(0.16) : Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? accent : Palette.line, lineWidth: selected ? 3 : 1))
            .help(photo?.id ?? "")
            .contentShape(Rectangle())
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(photo?.url.lastPathComponent ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction { activate() }
    }
}

// Expose the menu's bounds to AppKit so collection view selection can own the rest of the card.
private protocol CardMenuHitTarget {}
private final class CardMenuHost<Content: View>: NSHostingView<Content>, CardMenuHitTarget {}

private struct CardMenu<Items: View>: NSViewRepresentable {
    let title: String
    @ViewBuilder let items: () -> Items

    func makeNSView(context: Context) -> CardMenuHost<OptionsMenu<Items>> {
        let host = CardMenuHost(rootView: OptionsMenu(title: title, items: items))
        host.identifier = NSUserInterfaceItemIdentifier("CardActions")
        return host
    }
    func updateNSView(_ view: CardMenuHost<OptionsMenu<Items>>, context: Context) {
        view.rootView = OptionsMenu(title: title, items: items)
    }
}

private final class OpenableGrid: NSCollectionView {
    var open: ((Int) -> Void)?
    var selecting = false
    var exportsFiles = false
    var selectionChanged: ((NSCollectionView) -> Void)?
    private var anchor: IndexPath?
    private var press: (point: NSPoint, item: IndexPath?, selection: Set<IndexPath>, flags: NSEvent.ModifierFlags)?
    private let marquee = NSBox()
    private var dragging = false

    // Hosted card views provide context menus and accessibility. The grid tracks primary clicks and drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let event = window?.currentEvent ?? NSApp.currentEvent,
           event.type != .leftMouseDown || event.modifierFlags.contains(.control) { return hit }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            if view is CardMenuHitTarget { return hit }
            ancestor = view.superview
        }
        return self
    }

    private func itemPath(at point: NSPoint) -> IndexPath? {
        let pixel = NSRect(origin: point, size: NSSize(width: 1, height: 1))
        return collectionViewLayout?.layoutAttributesForElements(in: pixel)
            .first { $0.representedElementCategory == .item && $0.frame.contains(point) }?.indexPath
    }

    func resetTracking() {
        press = nil
        anchor = nil
        dragging = false
        marquee.removeFromSuperview()
    }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        press = (point, itemPath(at: point), selectionIndexPaths, event.modifierFlags)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        var point = convert(event.locationInWindow, from: nil)
        if !dragging {
            guard hypot(point.x - press.point.x, point.y - press.point.y) >= 4 else { return }
            dragging = true
            if exportsFiles, let item = press.item, press.selection.contains(item),
               press.flags.intersection([.shift, .command]).isEmpty {
                self.press = nil
                dragFiles(press.selection, at: point, event: event)
                return
            }
            marquee.boxType = .custom
            marquee.titlePosition = .noTitle
            marquee.borderWidth = 1
            marquee.borderColor = .selectedContentBackgroundColor
            marquee.fillColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16)
            addSubview(marquee, positioned: .above, relativeTo: nil)
        }
        autoscroll(with: event)
        point = convert(event.locationInWindow, from: nil)
        let rect = NSRect(x: min(press.point.x, point.x), y: min(press.point.y, point.y),
                          width: max(1, abs(point.x - press.point.x)), height: max(1, abs(point.y - press.point.y)))
        marquee.frame = rect
        let cells = collectionViewLayout?.layoutAttributesForElements(in: rect) ?? []
        let paths = Set(cells.filter { $0.representedElementCategory == .item && $0.frame.intersects(rect) }.compactMap(\.indexPath))
        let additive = !press.flags.intersection([.shift, .command]).isEmpty
        setSelection(additive ? press.selection.union(paths) : paths)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        marquee.removeFromSuperview()
        guard !dragging, event.clickCount <= 1 else { return }
        let end = itemPath(at: convert(event.locationInWindow, from: nil))
        guard end == press.item else { return }
        if let end { activate(end, flags: press.flags) }
        else { setSelection([]); anchor = nil }
    }

    func activate(_ item: IndexPath, flags: NSEvent.ModifierFlags = []) {
        guard item.item < numberOfItems(inSection: 0) else { return }
        if !selecting && flags.intersection([.command, .shift]).isEmpty {
            open?(item.item)
        } else if flags.contains(.shift), let anchor {
            let range = min(anchor.item, item.item)...max(anchor.item, item.item)
            setSelection(selectionIndexPaths.union(range.map { IndexPath(item: $0, section: 0) }))
        } else {
            setSelection(selectionIndexPaths.symmetricDifference([item]))
            anchor = item
        }
    }

    private func setSelection(_ paths: Set<IndexPath>) {
        guard paths != selectionIndexPaths else { return }
        selectionIndexPaths = paths
        selectionChanged?(self)
    }

    private func dragFiles(_ paths: Set<IndexPath>, at point: NSPoint, event: NSEvent) {
        let icon = NSWorkspace.shared.icon(for: .image)
        let frame = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        let items = paths.sorted().compactMap { path -> NSDraggingItem? in
            guard let writer = delegate?.collectionView?(self, pasteboardWriterForItemAt: path) else { return nil }
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(frame, contents: icon)
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self).draggingFormation = .pile
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), selectionIndexPaths.count == 1, let index = selectionIndexPaths.first?.item {
            open?(index)
        } else { super.keyDown(with: event) }
    }
}

private final class CollectionCoverCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CollectionCover")
    var edit: (PhotoCollection) -> Void = { _ in }
    var togglePin: (UUID) -> Void = { _ in }
    var delete: (PhotoCollection) -> Void = { _ in }
    var activate: () -> Void = {}
    var collection: PhotoCollection? { didSet { render() } }
    override var isSelected: Bool { didSet { if isSelected != oldValue { render() } } }
    override func loadView() { view = NSHostingView(rootView: cover) }
    private var cover: CollectionCover {
        CollectionCover(collection: collection, selected: isSelected, edit: edit, togglePin: togglePin, delete: delete, activate: activate)
    }
    private func render() { (view as? NSHostingView<CollectionCover>)?.rootView = cover }
}

private struct CollectionCover: View {
    @Environment(\.colorScheme) private var colorScheme
    let collection: PhotoCollection?
    let selected: Bool
    let edit: (PhotoCollection) -> Void
    let togglePin: (UUID) -> Void
    let delete: (PhotoCollection) -> Void
    let activate: () -> Void
    var body: some View {
        if let collection {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Palette.mat
                    if let photo = collection.items.first { FileImage(url: photo.url) }
                    else { Image(systemName: "rectangle.stack").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.secondary) }
                }
                HStack(spacing: 6) {
                    collection.color.dot
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.name).font(.headline).lineLimit(1)
                        Text(countText(collection.items.count, "picture")).font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    if collection.isPinned { Image(systemName: "pin.fill").font(.caption).accessibilityLabel("Pinned") }
                    if let shortcut = collection.shortcut { ShortcutKey(letter: shortcut) }
                    CardMenu(title: "Collection actions") { actions(collection) }.frame(width: 28, height: 26)
                }.padding(.horizontal, 12).frame(height: 50)
            }
            .foregroundStyle(Palette.ink)
            .background(selected ? collection.color.tint.opacity(0.16) : Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? collection.color.controlTint(in: colorScheme) : Palette.line, lineWidth: selected ? 3 : 1))
            .contentShape(Rectangle())
            .contextMenu { actions(collection) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(collection.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func actions(_ collection: PhotoCollection) -> CollectionMenuItems {
        CollectionMenuItems(collection: collection, edit: edit, togglePin: togglePin, delete: delete)
    }
}

struct CollectionMenuItems: View {
    let collection: PhotoCollection
    let edit: (PhotoCollection) -> Void
    let togglePin: (UUID) -> Void
    let delete: (PhotoCollection) -> Void

    var body: some View {
        Button { togglePin(collection.id) } label: {
            Label(collection.isPinned ? "Unpin Collection" : "Pin Collection",
                  systemImage: collection.isPinned ? "pin.slash" : "pin")
        }
        Button("Edit Collection…") { edit(collection) }
        Button("Delete Collection…", role: .destructive) { delete(collection) }
    }
}
