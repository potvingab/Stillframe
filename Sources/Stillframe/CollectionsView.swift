import SwiftUI

struct CollectionsView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var openID: UUID?
    @Binding var filter: PhotoFilter
    var backRequest: Int
    var newCollection: () -> Void
    var showPictures: () -> Void
    @ViewState private var editing: PhotoCollection?
    @ViewState private var deleteIDs: Set<UUID> = []
    @ViewState private var confirmingDelete = false
    @ViewState private var choices: Set<UUID> = []
    @ViewState private var selectingCollections = false
    @ViewState private var merging = false
    @ViewState private var selected: Set<String> = []
    @ViewState private var selectingPhotos = false
    @ViewState private var previewPath: String?
    @ViewState private var sharing = false
    @ViewState private var copyNotice: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let collection = library.state.collections.first(where: { $0.id == openID }) {
                let all = library.photos(in: collection)
                let accent = collection.color.controlTint(in: colorScheme)
                FilteredPhotos(source: all, filter: filter) { visible in
                    detail(collection, all: all, visible: visible, accent: accent)
                        .tint(accent)
                        .environment(\.collectionAccent, collection.color)
                        .onChange(of: visible, initial: true) { _, list in
                            selected = selected.filter { list.position(of: $0) != nil }
                            if list.isEmpty { previewPath = nil }
                        }
                }
                .id(collection.id)
                .transition(navigationTransition(offset: 18))
            } else {
                overview.transition(navigationTransition(offset: -12))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: openID)
        .padding(.horizontal, library.state.collections.isEmpty ? 0 : 10)
        .padding(.top, library.state.collections.isEmpty ? 0 : 5)
        .onChange(of: openID) { _, _ in
            selectingCollections = false
            choices.removeAll()
            selectingPhotos = false
            selected.removeAll()
            previewPath = nil
            copyNotice = nil
        }
        .onChange(of: selectingCollections) { _, active in
            if !active { choices.removeAll() }
        }
        .onChange(of: choices) { _, ids in
            if !ids.isEmpty { selectingCollections = true }
        }
        .onChange(of: selectingPhotos) { _, active in
            if !active { selected.removeAll() }
        }
        .onChange(of: backRequest) { _, _ in
            if openID != nil && previewPath == nil { goBack() }
        }
        .onChange(of: selected) { _, paths in
            if !paths.isEmpty { selectingPhotos = true }
            copyNotice = nil
        }
        .sheet(item: $editing) { collection in
            CollectionEditor(collection: collection, initialColor: collection.color)
        }
        .sheet(isPresented: $merging) {
            CollectionEditor(initialColor: library.state.collections.first { choices.contains($0.id) }?.color ?? library.nextColor,
                             merging: choices) { id in
                choices.removeAll()
                openID = id
            }
        }
        .alert(deleteIDs.count == 1 ? "Delete collection?" : "Delete selected collections?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard library.deleteCollections(deleteIDs) else { return }
                if let openID, deleteIDs.contains(openID) { self.openID = nil }
                selectingCollections = false
                choices.removeAll()
            }
        } message: {
            let names = library.state.collections.filter { deleteIDs.contains($0.id) }.map(\.name)
            Text(names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and more" : "") + " will be removed. Original pictures stay in their folders.")
        }
    }

    private func navigationTransition(offset: CGFloat) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: offset))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !library.state.collections.isEmpty {
                Text(countText(library.state.collections.count, "collection"))
                    .font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(Palette.ink)
            }
            if library.state.collections.isEmpty {
                EmptyPanel(title: "Create your first collection", detail: "Gather pictures from any folder into a collection.") {
                    EmptyGlyph(symbol: "rectangle.stack").scaleEffect(1.2).frame(height: 104)
                } actions: {
                    Button(action: newCollection) { Label("Create Collection…", systemImage: "plus") }
                        .buttonStyle(ActionStyle(primary: true))
                }
            } else {
                CollectionGrid(collections: library.state.collectionsForDisplay, choices: $choices, selecting: selectingCollections,
                               open: { openID = $0 }, edit: { editing = $0 }, togglePin: library.togglePin,
                               delete: { confirmDeletion([$0.id]) })
                    .padding(.horizontal, -24)
                HStack {
                    if !choices.isEmpty { Text("\(choices.count) selected").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    SelectionActions(allSelected: choices.count == library.state.collections.count, selectAll: {
                        choices = Set(library.state.collections.map(\.id))
                    }, hasSelection: !choices.isEmpty, selectionMode: $selectingCollections) {
                        let pin = library.state.collections.contains { choices.contains($0.id) && !$0.isPinned }
                        Button { library.setPinned(pin, for: choices) } label: {
                            Label(pin ? "Pin" : "Unpin", systemImage: pin ? "pin" : "pin.slash").modifier(SelectionControl())
                        }
                        Button { merging = true } label: {
                            Label("Merge…", systemImage: "rectangle.stack").modifier(SelectionControl())
                        }.disabled(choices.count < 2)
                        Divider().frame(height: 14).accessibilityHidden(true)
                        Button { confirmDeletion(choices) } label: {
                            Label("Delete…", systemImage: "trash").modifier(SelectionControl())
                        }
                    }
                }.frame(minHeight: 36).padding(.horizontal, 2)
            }
        }
    }

    private func confirmDeletion(_ ids: Set<UUID>) {
        deleteIDs = ids
        confirmingDelete = true
    }

    private func detail(_ collection: PhotoCollection, all: PhotoList, visible: PhotoList, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Button(action: goBack) {
                Label(previewPath == nil ? "All collections" : "Back to grid", systemImage: "chevron.left")
            }.buttonStyle(.plain).font(.callout).foregroundStyle(Palette.secondary)
                .keyboardShortcut(sharing || (selectingPhotos && previewPath == nil) ? nil : .cancelAction)
            HStack(spacing: 9) {
                collection.color.dot
                SectionHeading(title: collection.name).help(collection.name)
                if let key = collection.shortcut { ShortcutKey(letter: key) }
                Spacer()
                OptionsMenu(title: "Collection actions") {
                    CollectionMenuItems(collection: collection, edit: { editing = $0 }, togglePin: library.togglePin,
                                        delete: { confirmDeletion([$0.id]) })
                }
            }
            if collection.items.isEmpty {
                EmptyPanel(title: "No pictures marked yet", detail: "Open Pictures and use Add to Collection to mark a photo.") {
                    EmptyGlyph(symbol: "bookmark")
                } actions: {
                    Button { showPictures() } label: { Label("Browse Pictures", systemImage: "photo") }
                        .buttonStyle(ActionStyle(primary: true))
                }
            } else if visible.isEmpty {
                NoFilterMatches(filter: $filter, all: all, groups: SourceGroups([]))
            } else {
                SortedPhotos(source: visible, sourceOrder: .collection, order: collection.sort) { photos in
                    ZStack {
                        if previewPath != nil {
                            PhotoCarousel(photos: photos, selectedPath: $previewPath, all: all, accent: accent, collectionID: collection.id)
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985)))
                        } else {
                            CollectionGrid(items: photos, selected: $selected, selecting: selectingPhotos, accent: accent,
                                           menuItems: { PictureMenuItems(url: $0, library: library, collectionID: collection.id) }) { url in
                                withAnimation(reduceMotion ? nil : .smooth(duration: 0.23)) { previewPath = url.path }
                            }
                            .padding(.horizontal, -24)
                            .help("Click to open. Drag across pictures to select them, or drag selected pictures to Finder to copy.")
                            .transition(reduceMotion ? .identity : .opacity)
                        }
                    }
                    .modifier(PictureMapAccess(photos: photos, open: { previewPath = $0.id }))
                }
            }
            if !collection.items.isEmpty && previewPath == nil {
                HStack(spacing: 7) {
                    StatisticsButton(label: countText(visible.count, "picture"), all: all, visible: visible, groups: SourceGroups([]))
                    if !selected.isEmpty {
                        Text("·").accessibilityHidden(true)
                        Text("\(selected.count) selected").foregroundStyle(accent)
                    }
                    Spacer()
                    if library.copyingPictures { ProgressView().controlSize(.small).accessibilityLabel("Copying pictures") }
                    if let copyNotice { Text(copyNotice).lineLimit(1) }
                    selectionActions(in: collection, visible: visible)
                }.font(.callout).monospacedDigit().foregroundStyle(Palette.secondary)
                    .frame(minHeight: 36).padding(.horizontal, 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selected.isEmpty)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
            }
        }
        .onChange(of: collection.items.isEmpty) { _, empty in
            if empty { previewPath = nil; selected = []; selectingPhotos = false }
        }
    }

    private func goBack() {
        guard !sharing else { return }
        if previewPath != nil {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.23)) { previewPath = nil }
        } else { openID = nil }
    }

    private func selectionActions(in collection: PhotoCollection, visible: PhotoList) -> some View {
        SelectionActions(allSelected: selected.count == visible.count, selectAll: {
            selected = Set(visible.map(\.id))
        }, hasSelection: !selected.isEmpty, selectionMode: $selectingPhotos) {
            ShareSelectionButton(files: { library.readableFiles(selectedURLs(in: collection)) }, showing: $sharing)
                .fixedSize()
            Button {
                copyNotice = nil
                library.copyPictures(selectedURLs(in: collection)) { message in
                    if openID == collection.id { copyNotice = message }
                }
            } label: {
                Label("Copy to…", systemImage: "folder").modifier(SelectionControl())
            }.disabled(library.copyingPictures)
            Divider().frame(height: 14).accessibilityHidden(true)
            Menu {
                Button("Send by Email…") { library.emailPictures(selectedURLs(in: collection)) }
                Divider()
                Button("Remove from Collection") {
                    library.unmark(selected, in: collection.id)
                    selected.removeAll()
                }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 13).modifier(SelectionControl())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Selection actions").help("More selection actions")
        }
    }

    private func selectedURLs(in collection: PhotoCollection) -> [URL] {
        collection.items.compactMap { selected.contains($0.path) ? $0.url : nil }
    }
}

private struct SelectionActions<Actions: View>: View {
    let allSelected: Bool
    let selectAll: () -> Void
    let hasSelection: Bool
    @Binding var selectionMode: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 7) {
            if !selectionMode {
                button("Select", symbol: "checkmark.circle") { selectionMode = true }
            } else {
                button("Select All", symbol: "checkmark.rectangle.stack", action: selectAll).disabled(allSelected)
            }
            if hasSelection {
                HStack(spacing: 4, content: actions)
                    .padding(.horizontal, 5).padding(.vertical, 2).modifier(HeaderCapsule())
            }
            if selectionMode {
                button("Done", symbol: "checkmark") { selectionMode = false }
                    .keyboardShortcut(.cancelAction)
            }
        }.labelStyle(.titleAndIcon).font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.ink).buttonStyle(.plain).fixedSize()
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).modifier(SelectionControl()).padding(2).modifier(HeaderCapsule())
        }
    }
}

private struct SelectionControl: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 12).frame(height: 28).contentShape(Capsule())
    }
}
