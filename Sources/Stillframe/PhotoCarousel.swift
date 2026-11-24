import SwiftUI

struct PhotoCarousel: View {
    @EnvironmentObject private var library: Library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showPhotoInspector") private var showInspector = true
    let photos: PhotoList
    @Binding var selectedPath: String?
    let all: PhotoList
    var groups = SourceGroups([])
    var accent = Palette.accent
    var collectionID: UUID?
    @ViewState private var marking = false
    @ViewState private var creatingFor: Photo?
    @ViewState private var positionDraft: String?
    @FocusState private var editingPosition: Bool

    private var index: Int { photos.position(of: selectedPath) ?? 0 }

    var body: some View {
        if !photos.isEmpty {
            let photo = photos[index]
            VStack(spacing: 7) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        preview(photo).contextMenu { pictureActions(photo) }
                        controls(photo)
                    }
                    HStack(spacing: 0) {
                        Divider()
                        PhotoInspector(photo: photo, active: showInspector)
                    }
                    .frame(width: 240)
                    .opacity(showInspector ? 1 : 0)
                    .frame(width: showInspector ? 240 : 0, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(showInspector)
                    .accessibilityHidden(!showInspector)
                }.animation(reduceMotion ? nil : .smooth(duration: 0.28), value: showInspector)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
                Filmstrip(photos: photos, selected: index, library: library, accent: accent, collectionID: collectionID,
                          onSelect: { selectedPath = $0 }, onOpen: openOriginal)
                    .frame(height: FilmstripLayout.tile.height)
            }
            .background {
                CarouselKeys { event in
                    guard !marking, creatingFor == nil, positionDraft == nil else { return false }
                    if event.keyCode == 123 || event.keyCode == 124 {
                        step(event.keyCode == 123 ? -1 : 1)
                        return true
                    }
                    guard let key = Library.normalizedShortcut(event.charactersIgnoringModifiers),
                          let collection = library.state.collections.first(where: { $0.shortcut == key }) else { return false }
                    if !event.isARepeat { library.toggleMark(photo.url, in: collection.id) }
                    return true
                }
            }
            .sheet(item: $creatingFor) { item in
                CollectionEditor(initialColor: library.nextColor, photo: item.url)
            }
            .onAppear {
                if photos.position(of: selectedPath) == nil { selectedPath = photos.first?.id }
            }
            .onChange(of: photos) { old, new in
                positionDraft = nil
                guard !new.isEmpty, new.position(of: selectedPath) == nil else { return }
                let previousIndex = old.position(of: selectedPath) ?? 0
                selectedPath = new[min(previousIndex, new.count - 1)].id
            }
        }
    }

    private func step(_ offset: Int) {
        guard !photos.isEmpty else { return }
        selectedPath = photos[(index + offset + photos.count) % photos.count].id
    }

    private func preview(_ photo: Photo) -> some View {
        ZStack {
            Color(red: 0.095, green: 0.106, blue: 0.10)
            FileImage(url: photo.url, modified: photo.modified, fit: true)
            if photos.count > 1 {
                HStack {
                    arrow("Previous picture", symbol: "chevron.left", key: .leftArrow) { step(-1) }
                    Spacer()
                    arrow("Next picture", symbol: "chevron.right", key: .rightArrow) { step(1) }
                }.padding(.horizontal, 12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func controls(_ photo: Photo) -> some View {
        let memberships = library.collections(containing: photo.id)
        return HStack(spacing: 9) {
            if !showInspector {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(photo.url.lastPathComponent).font(PhotoTypography.filename)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Image(systemName: "folder").imageScale(.small).accessibilityHidden(true)
                        Text(photo.url.deletingLastPathComponent().lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                    }.font(PhotoTypography.detail).foregroundStyle(Palette.secondary)
                }.help(photo.url.path)
            }
            if showInspector {
                position
            }
            Spacer(minLength: 0)
            if !showInspector { position }
            OptionsMenu(title: "Picture actions") { pictureActions(photo) }
            Button { marking.toggle() } label: {
                Label(memberships.isEmpty ? "Add to Collection" : "In Collections",
                      systemImage: memberships.isEmpty ? "bookmark" : "bookmark.fill")
            }.buttonStyle(ActionStyle()).fixedSize()
                .popover(isPresented: $marking, arrowEdge: .bottom) {
                    MarkPopover(photo: photo) {
                        marking = false
                        creatingFor = photo
                    }
                }
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showInspector ? accent : Palette.secondary)
                    .frame(width: 30, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(showInspector ? "Hide photo info" : "Show photo info")
                .help(showInspector ? "Hide photo info" : "Show photo info")
        }.padding(.leading, showInspector ? 12 : 18).padding(.trailing, 12)
            .frame(height: 42).background(Palette.surface)
    }

    private func pictureActions(_ photo: Photo) -> PictureMenuItems {
        PictureMenuItems(url: photo.url, library: library, collectionID: collectionID)
    }

    private var position: some View {
        HStack(spacing: 0) {
            if positionDraft != nil {
                TextField("Picture number", text: Binding(get: { positionDraft ?? "" }, set: { positionDraft = $0 }))
                    .textFieldStyle(.roundedBorder).controlSize(.small).multilineTextAlignment(.trailing)
                    .frame(width: max(34, CGFloat(String(photos.count).count * 8 + 12)))
                    .focused($editingPosition)
                    .onAppear { editingPosition = true }
                    .onSubmit {
                        guard let draft = positionDraft, let number = Int(draft.trimmingCharacters(in: .whitespaces)),
                              (1...photos.count).contains(number) else {
                            NSSound.beep()
                            editingPosition = true
                            return
                        }
                        selectedPath = photos[number - 1].id
                        positionDraft = nil
                    }
                    .onExitCommand { positionDraft = nil }
                    .help("Enter a picture number from 1 to \(photos.count) and press Return")
                    .onChange(of: editingPosition) { _, focused in if !focused { positionDraft = nil } }
            } else {
                Button { positionDraft = String(index + 1) } label: {
                    Text(String(index + 1)).padding(.horizontal, 4).frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Go to picture number")
                    .accessibilityLabel("Go to picture number").accessibilityValue(String(index + 1))
            }
            StatisticsButton(label: "/ \(photos.count)", all: all, visible: photos, groups: groups)
        }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary).fixedSize()
    }

    private func arrow(_ name: String, symbol: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 36, height: 36).foregroundStyle(.white)
                .modifier(ViewerGlass())
                .contentShape(.interaction, Circle())
        }.buttonStyle(.plain).keyboardShortcut(positionDraft == nil ? KeyboardShortcut(key, modifiers: []) : nil)
            .accessibilityLabel(name).help(name)
    }

    private func openOriginal(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            library.message = "The default app could not open “\(url.lastPathComponent)”."
            return
        }
    }
}

private struct ViewerGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.28)).interactive(), in: Circle())
                .environment(\.colorScheme, .dark)
        } else {
            content.background(.regularMaterial, in: Circle()).environment(\.colorScheme, .dark)
        }
    }
}

private struct MarkPopover: View {
    @EnvironmentObject private var library: Library
    let photo: Photo
    let create: () -> Void

    var body: some View {
        let marks = Set(library.collections(containing: photo.id).map(\.id))
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to collections").font(.headline)
            if !library.state.collections.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(library.state.collectionsForDisplay) { collection in
                            let marked = marks.contains(collection.id)
                            Button { library.toggleMark(photo.url, in: collection.id) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: marked ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(marked ? Palette.ink : Palette.secondary)
                                    collection.color.dot
                                    Text(collection.name).lineLimit(1)
                                    Spacer()
                                    if let key = collection.shortcut { ShortcutKey(letter: key) }
                                }.frame(height: 26).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityValue(marked ? "Added" : "Not added")
                        }
                    }
                }.frame(height: min(CGFloat(library.state.collections.count) * 28, 190))
                Divider()
            }
            Button(action: create) { Label("New Collection…", systemImage: "plus") }.buttonStyle(.borderless)
        }.padding(16).frame(width: 266)
    }
}

// A carousel owns plain-letter shortcuts only while its window is receiving ordinary browsing input.
private struct CarouselKeys: NSViewRepresentable {
    let handle: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !(window.firstResponder is NSTextInputClient),
                      event.modifierFlags.intersection([.control, .option, .command]).isEmpty else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
