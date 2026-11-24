import SwiftUI

struct PicturesView: View {
    @EnvironmentObject private var library: Library
    @Binding var selectedPath: String?
    @Binding var filter: PhotoFilter
    var manageFolders: () -> Void

    var body: some View {
        Group {
            if library.photos.isEmpty {
                if library.state.folders.isEmpty {
                    EmptyPanel(title: "Choose your first folder",
                               detail: "Drop a folder here, or choose one from your Mac.") {
                        WelcomePrint().modifier(PictureEntrance())
                    } actions: { addButton }
                } else if library.scanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading folders…").foregroundStyle(Palette.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyPanel(title: library.issues.isEmpty ? "No pictures found" : "Check your folders",
                               detail: library.issues.isEmpty
                                   ? "Add a folder with pictures, or include its subfolders."
                                   : "Open Folders to see which locations are unavailable.") {
                        EmptyGlyph(symbol: "photo.on.rectangle.angled")
                    } actions: {
                        Button("Manage Folders…", action: manageFolders).buttonStyle(ActionStyle(primary: true))
                    }
                }
            } else {
                let groups = SourceGroups(library.state.folders)
                FilteredPhotos(source: library.photos, filter: filter) { visible in
                    if visible.isEmpty {
                        NoFilterMatches(filter: $filter, all: library.photos, groups: groups)
                    } else {
                        SortedPhotos(source: visible, sourceOrder: .pictures, order: library.picturesSort) { photos in
                            PhotoCarousel(photos: photos, selectedPath: $selectedPath, all: library.photos, groups: groups)
                                .modifier(PictureMapAccess(photos: photos, open: { selectedPath = $0.id }))
                        }
                    }
                }
            }
        }.modifier(FolderDropTarget())
    }

    private var addButton: some View {
        Button { library.chooseFolders() } label: { Label("Add Folders…", systemImage: "folder.badge.plus") }
            .buttonStyle(ActionStyle(primary: true))
    }
}

struct FolderDropTarget: ViewModifier {
    @EnvironmentObject private var library: Library
    @ViewState private var targeted = false

    func body(content: Content) -> some View {
        content.overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }.dropDestination(for: URL.self) { urls, _ in library.addFolders(urls) } isTargeted: { targeted = $0 }
    }
}

private struct PictureEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var revealed = false
    func body(content: Content) -> some View {
        content.opacity(revealed || reduceMotion ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 5)
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { revealed = true }
            }
    }
}
