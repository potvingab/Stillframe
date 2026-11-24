import SwiftUI

@main
struct StillframeApp: App {
    @NSApplicationDelegateAdaptor(StillframeDelegate.self) private var appDelegate
    @StateObject private var library = Library()
    @Environment(\.openWindow) private var openWindow
    @ViewState private var sheet: LibrarySheet?

    var body: some Scene {
        Window("Stillframe", id: "library") {
            Workspace(sheet: $sheet).environmentObject(library)
        }
        .defaultSize(width: 1060, height: 740)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Stillframe") {
                    NSApp.orderFrontStandardAboutPanel(options: StillframeDelegate.icon.map { [.applicationIcon: $0] } ?? [:])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Folders…") { library.chooseFolders() }
                    .keyboardShortcut("o")
                Button("Refresh Pictures") { library.refresh() }
                    .keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Button("Stillframe Walkthrough…") {
                    openWindow(id: "library")
                    sheet = .walkthrough
                }.disabled(sheet != nil)
            }
        }
    }
}

final class StillframeDelegate: NSObject, NSApplicationDelegate {
    static let icon: NSImage? = {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
        return NSImage(contentsOf: url)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Self.icon { NSApp.applicationIconImage = icon }
    }
}

enum LibrarySheet: Int, Identifiable {
    case folders, newCollection, walkthrough
    var id: Self { self }
}

enum WorkspaceTab: String, CaseIterable {
    case pictures = "Pictures"
    case collections = "Collections"
    var symbol: String { self == .pictures ? "photo" : "rectangle.stack" }
}

struct Workspace: View {
    @EnvironmentObject private var library: Library
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasSeenWalkthrough") private var hasSeenWalkthrough = false
    @Binding var sheet: LibrarySheet?
    @ViewState private var tab: WorkspaceTab = .pictures
    @ViewState private var selectedPath: String?
    @ViewState private var collectionID: UUID?
    @ViewState private var backRequest = 0
    @ViewState private var filters: [UUID: PhotoFilter] = [:]

    private var currentFilter: Binding<PhotoFilter> {
        let id = openCollection?.id ?? library.state.activeWorkspaceID
        return Binding(get: { filters[id] ?? PhotoFilter() }, set: { filters[id] = $0.active ? $0 : nil })
    }

    private var openCollection: PhotoCollection? {
        guard tab == .collections else { return nil }
        return library.state.collections.first { $0.id == collectionID }
    }

    private func selectTab(_ next: WorkspaceTab) {
        guard tab != next else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { tab = next }
    }

    var body: some View {
        ZStack {
            switch tab {
            case .pictures:
                PicturesView(selectedPath: $selectedPath, filter: currentFilter) { sheet = .folders }
                    .transition(pageTransition(from: .leading))
            case .collections:
                CollectionsView(openID: $collectionID, filter: currentFilter, backRequest: backRequest,
                                newCollection: { sheet = .newCollection }, showPictures: { selectTab(.pictures) })
                    .transition(pageTransition(from: .trailing))
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .frame(minWidth: 745, maxWidth: .infinity, minHeight: 490, maxHeight: .infinity)
        .foregroundStyle(Palette.ink).background(Palette.paper).tint(openCollection?.color.controlTint(in: colorScheme) ?? Palette.accent)
        .modifier(StatisticsOverlay())
        .background(WindowLightHighlights())
        .background(WorkspaceSwipe(select: selectTab, back: openCollection == nil ? nil : { backRequest += 1 }))
        .navigationTitle(openCollection?.name ?? tab.rawValue)
        .toolbarBackground(Palette.paper, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                WorkspaceSwitcher(tab: tab, select: selectTab)
            }.withoutSharedGlass()
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) { Spacer() }
            }
            if tab == .pictures && library.scanning {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView().controlSize(.mini).accessibilityLabel("Reading folders")
                }.withoutSharedGlass()
            }
            ToolbarItem(id: "library-actions", placement: .primaryAction) {
                HStack(spacing: 10) {
                    if tab == .pictures || openCollection != nil {
                        let collection = openCollection
                        let source = collection.map { library.photos(in: $0) } ?? library.photos
                        FilterButton(source: source,
                                     groups: SourceGroups(collection == nil ? library.state.folders : []),
                                     filter: currentFilter).disabled(source.isEmpty && !currentFilter.wrappedValue.active)
                        PhotoSortMenu(order: collection?.sort ?? library.picturesSort, inCollection: collection != nil) {
                            library.setSort($0, for: collection?.id)
                        }.disabled(source.isEmpty)
                    }
                    if tab == .pictures {
                        FoldersToolbarButton { sheet = .folders }
                    } else {
                        HeaderAction(title: "New Collection", symbol: "plus") { sheet = .newCollection }
                            .help("Create a collection")
                    }
                }.fixedSize()
            }.withoutSharedGlass()
        }
        .modifier(KeepToolbarInFullScreen())
        .sheet(item: $sheet) { item in
            switch item {
            case .folders: FoldersView()
            case .newCollection: CollectionEditor(initialColor: library.nextColor) { collectionID = $0 }
            case .walkthrough:
                WalkthroughView().onAppear { hasSeenWalkthrough = true }
            }
        }
        .alert("Stillframe", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK") { library.message = nil }
        } message: { Text(library.message ?? "") }
        .onAppear {
            if library.isNewLibrary && !hasSeenWalkthrough && sheet == nil { sheet = .walkthrough }
        }
        .onChange(of: phase, initial: true) { _, new in
            if new == .active && !library.scanning { library.refresh() }
        }
    }

    private func pageTransition(from edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .opacity.combined(with: .offset(x: edge == .leading ? -12 : 12))
    }
}
