import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

struct FileReference: Codable, Hashable {
    var path: String
    var bookmark: Data?
    var url: URL { URL(fileURLWithPath: path) }

    init(_ url: URL) {
        path = url.standardizedFileURL.path
        bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    mutating func restore() {
        path = url.standardizedFileURL.path
        guard let bookmark else { return }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        path = resolved.standardizedFileURL.path
        if stale { self = FileReference(resolved) }
    }
}

struct SourceFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var location: FileReference
    var recursive = true
}

struct CollectionColor: RawRepresentable, Codable, Hashable {
    let rawValue: String

    private init(preset: String) { rawValue = preset }
    static let sage = Self(preset: "sage"), sky = Self(preset: "sky"), coral = Self(preset: "coral")
    static let violet = Self(preset: "violet"), amber = Self(preset: "amber"), teal = Self(preset: "teal")
    static let rose = Self(preset: "rose"), slate = Self(preset: "slate")
    static let presets: [Self] = [.sage, .sky, .coral, .violet, .amber, .teal, .rose, .slate]

    init?(rawValue: String) {
        if let preset = Self.presets.first(where: { $0.rawValue == rawValue }) {
            self = preset
        } else {
            guard rawValue.count == 7, rawValue.first == "#", rawValue.dropFirst().allSatisfy(\.isHexDigit),
                  UInt32(rawValue.dropFirst(), radix: 16) != nil else { return nil }
            self.rawValue = rawValue.uppercased()
        }
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        rawValue = String(format: "#%02X%02X%02X", red, green, blue)
    }

    var customRGB: UInt32? {
        rawValue.first == "#" ? UInt32(rawValue.dropFirst(), radix: 16) : nil
    }
}

struct PhotoCollection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: CollectionColor = .sage
    var shortcut: String?
    var isPinned = false
    var items: [FileReference] = []
    var sort: PhotoOrder = .collection

    init(name: String, color: CollectionColor = .sage, shortcut: String? = nil, items: [FileReference] = []) {
        self.name = name
        self.color = color
        self.shortcut = shortcut
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        items = try fields.decode([FileReference].self, forKey: .items)
        sort = try fields.decodeIfPresent(PhotoOrder.self, forKey: .sort) ?? .collection
        let palette = CollectionColor.presets
        color = try fields.decodeIfPresent(CollectionColor.self, forKey: .color)
            ?? palette[Int(id.uuid.0) % palette.count]
        shortcut = try fields.decodeIfPresent(String.self, forKey: .shortcut)
        isPinned = try fields.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

struct FolderWorkspace: Identifiable, Codable {
    var id = UUID()
    var name: String
    var folders: [SourceFolder] = []
}

struct LibraryState: Codable {
    var workspaces: [FolderWorkspace]
    var activeWorkspaceID: UUID
    var collections: [PhotoCollection] = []
    var picturesSort: PhotoOrder?

    init() {
        let first = FolderWorkspace(name: "My Pictures")
        workspaces = [first]
        activeWorkspaceID = first.id
    }

    private enum CodingKeys: String, CodingKey { case workspaces, activeWorkspaceID, collections, picturesSort }
    private enum LegacyKeys: String, CodingKey { case folders }

    init(from decoder: Decoder) throws {
        self.init()
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        collections = try fields.decode([PhotoCollection].self, forKey: .collections)
        picturesSort = try fields.decodeIfPresent(PhotoOrder.self, forKey: .picturesSort)
        if let saved = try fields.decodeIfPresent([FolderWorkspace].self, forKey: .workspaces), !saved.isEmpty {
            workspaces = saved
            let active = try fields.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
            activeWorkspaceID = saved.first(where: { $0.id == active })?.id ?? saved[0].id
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            folders = try legacy.decode([SourceFolder].self, forKey: .folders)
        }
    }

    var workspaceIndex: Int { workspaces.firstIndex { $0.id == activeWorkspaceID } ?? 0 }
    var workspace: FolderWorkspace { workspaces[workspaceIndex] }
    func workspaceNameInUse(_ title: String, excluding id: UUID? = nil) -> Bool {
        workspaces.contains { $0.id != id && $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }
    var collectionsForDisplay: [PhotoCollection] {
        collections.filter(\.isPinned) + collections.filter { !$0.isPinned }
    }
    var folders: [SourceFolder] {
        get { workspace.folders }
        set { workspaces[workspaceIndex].folders = newValue }
    }

    mutating func restoreLocations() {
        var resolved: [FileReference: FileReference] = [:]
        func restore(_ reference: inout FileReference) {
            if let cached = resolved[reference] {
                reference = cached
            } else {
                let saved = reference
                reference.restore()
                resolved[saved] = reference
            }
        }
        for i in workspaces.indices {
            for j in workspaces[i].folders.indices { restore(&workspaces[i].folders[j].location) }
        }
        for i in collections.indices {
            for j in collections[i].items.indices { restore(&collections[i].items[j]) }
        }
    }
}

struct Photo: Identifiable, Hashable {
    let url: URL
    let modified: Date?
    let fileSize: Int64?
    let id: String

    init(url: URL, modified: Date?, fileSize: Int64? = nil) {
        self.url = url
        self.fileSize = fileSize
        self.modified = modified
        self.id = url.path
    }
}

// Each scan or collection edit produces one immutable ordering shared by the viewer and filmstrip.
final class PhotoList: RandomAccessCollection, Equatable, Sendable {
    let items: [Photo]
    private let positions: [String: Int]

    init(_ items: [Photo]) {
        self.items = items
        var positions: [String: Int] = [:]
        positions.reserveCapacity(items.count)
        for (index, photo) in items.enumerated() { positions[photo.id] = index }
        self.positions = positions
    }

    var startIndex: Int { items.startIndex }
    var endIndex: Int { items.endIndex }
    subscript(index: Int) -> Photo { items[index] }
    func position(of path: String?) -> Int? { path.flatMap { positions[$0] } }
    static func == (lhs: PhotoList, rhs: PhotoList) -> Bool { lhs === rhs }
}

struct ScanResult {
    var photos: [Photo] = []
    var issues: [UUID: String] = [:]
}

enum FolderScanner {
    static let formats = Set((CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) })

    static func scan(_ folders: [SourceFolder]) -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let attributes = Set(keys)
        var result = ScanResult()
        var seen = Set<String>()
        var supported: [String: Bool] = [:]
        for folder in folders {
            if Task.isCancelled { break }
            let root = folder.location.url
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                result.issues[folder.id] = "Folder unavailable"
                continue
            }
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if !folder.recursive { options.insert(.skipsSubdirectoryDescendants) }
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { _, _ in
                result.issues[folder.id] = "Some files could not be read"
                return !Task.isCancelled
            }) else {
                result.issues[folder.id] = "Folder could not be read"
                continue
            }
            for case let url as URL in files {
                if Task.isCancelled { return result }
                let ext = url.pathExtension.lowercased()
                if supported[ext] == nil {
                    supported[ext] = UTType(filenameExtension: ext).map { type in
                        type.conforms(to: .image) && formats.contains { type.conforms(to: $0) }
                    } ?? false
                }
                guard supported[ext] == true,
                      let values = try? url.resourceValues(forKeys: attributes), values.isRegularFile == true else { continue }
                // Enumeration can return /private/tmp while a saved bookmark resolves to /tmp.
                let location = url.standardizedFileURL
                guard seen.insert(location.path).inserted else { continue }
                result.photos.append(Photo(url: location, modified: values.contentModificationDate, fileSize: values.fileSize.map(Int64.init)))
            }
        }
        if let sorted = try? PhotoOrder.pictures.arrange(result.photos) { result.photos = sorted }
        return result
    }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var state: LibraryState
    @Published private(set) var photos = PhotoList([])
    @Published private(set) var issues: [UUID: String] = [:]
    @Published private(set) var scanning = false
    @Published var message: String?

    private(set) var markRevision = 0
    private var collectionList: (id: UUID, items: [FileReference], photos: PhotoList, hasUnscannedFiles: Bool)?

    func photos(in collection: PhotoCollection) -> PhotoList {
        if let cached = collectionList, cached.id == collection.id, cached.items == collection.items { return cached.photos }
        var hasUnscannedFiles = false
        let list = PhotoList(collection.items.map { file in
            if let index = photos.position(of: file.path) { return photos[index] }
            hasUnscannedFiles = true
            return Photo(url: URL(fileURLWithPath: file.path, isDirectory: false), modified: nil)
        })
        collectionList = (collection.id, collection.items, list, hasUnscannedFiles)
        return list
    }

    private var memberships: [String: [Int]] = [:]

    private func indexMarks(_ collections: [PhotoCollection]) {
        markRevision += 1
        memberships.removeAll(keepingCapacity: true)
        for (index, collection) in collections.enumerated() {
            for file in collection.items { memberships[file.path, default: []].append(index) }
        }
    }

    func collections(containing path: String) -> [PhotoCollection] {
        (memberships[path] ?? []).map { state.collections[$0] }
    }

    var nextColor: CollectionColor {
        let counts = Dictionary(grouping: state.collections, by: \.color).mapValues(\.count)
        return CollectionColor.presets.min { counts[$0, default: 0] < counts[$1, default: 0] } ?? .sage
    }

    private let saveURL: URL
    let isNewLibrary: Bool
    private var loadFailed = false
    private var scanTask: Task<Void, Never>?

    init(saveURL: URL? = nil) {
        self.saveURL = saveURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stillframe/library.json")
        var initial = LibraryState()
        do {
            let data = try Data(contentsOf: self.saveURL)
            initial = try JSONDecoder().decode(LibraryState.self, from: data)
            initial.restoreLocations()
            isNewLibrary = false
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            isNewLibrary = true
        } catch {
            isNewLibrary = false
            loadFailed = true
            message = "Your saved library could not be opened. A copy must be preserved before new changes can be saved.\n\n" + error.localizedDescription
        }
        state = initial
        indexMarks(initial.collections)
    }

    @discardableResult
    private func change(reindexMarks: Bool = true, _ edit: (inout LibraryState) -> Void) -> Bool {
        var next = state
        edit(&next)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if loadFailed {
                let backup = saveURL.deletingLastPathComponent().appendingPathComponent("library-backup-\(UUID().uuidString).json")
                try fm.copyItem(at: saveURL, to: backup)
                loadFailed = false
            }
            try JSONEncoder().encode(next).write(to: saveURL, options: .atomic)
            if reindexMarks { indexMarks(next.collections) }
            state = next
            return true
        } catch {
            message = "Your change could not be saved.\n\n" + error.localizedDescription
            return false
        }
    }

    var picturesSort: PhotoOrder { state.picturesSort ?? .pictures }

    func setSort(_ order: PhotoOrder, for collectionID: UUID?) {
        if let collectionID {
            guard let index = state.collections.firstIndex(where: { $0.id == collectionID }),
                  state.collections[index].sort != order else { return }
            change(reindexMarks: false) { $0.collections[index].sort = order }
        } else if order.key != .added && order != picturesSort {
            change(reindexMarks: false) { $0.picturesSort = order }
        }
    }

    func refresh() {
        scanTask?.cancel()
        let sources = state.folders
        guard !sources.isEmpty else {
            scanTask = nil
            if !photos.isEmpty || collectionList?.hasUnscannedFiles == true { photos = PhotoList([]) }
            collectionList = nil
            if !issues.isEmpty { issues = [:] }
            if scanning { scanning = false }
            return
        }
        if !scanning { scanning = true }
        scanTask = Task {
            let previous = photos
            let worker = Task.detached(priority: .userInitiated) {
                let scan = FolderScanner.scan(sources)
                let list = scan.photos == previous.items ? previous : PhotoList(scan.photos)
                return (list, scan.issues)
            }
            let (list, problems) = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            if list !== previous || collectionList?.hasUnscannedFiles == true {
                collectionList = nil
            }
            if list !== previous { photos = list }
            if issues != problems { issues = problems }
            scanning = false
        }
    }

    func switchWorkspace(_ id: UUID) {
        guard id != state.activeWorkspaceID, state.workspaces.contains(where: { $0.id == id }) else { return }
        let previous = state.folders
        if change(reindexMarks: false, { $0.activeWorkspaceID = id }) { reloadWorkspace(from: previous) }
    }

    @discardableResult
    func saveWorkspace(name: String, copyFolders: Bool, rename: Bool = false) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        guard !state.workspaceNameInUse(title, excluding: rename ? state.activeWorkspaceID : nil) else {
            message = "A workspace with this name already exists."
            return false
        }
        if rename { return change(reindexMarks: false) { $0.workspaces[$0.workspaceIndex].name = title } }
        let previous = state.folders
        let workspace = FolderWorkspace(name: title, folders: copyFolders ? previous : [])
        guard change(reindexMarks: false, { $0.workspaces.append(workspace); $0.activeWorkspaceID = workspace.id }) else { return false }
        reloadWorkspace(from: previous)
        return true
    }

    func deleteCurrentWorkspace() {
        guard state.workspaces.count > 1 else { return }
        let previous = state.folders
        if change(reindexMarks: false, { state in
            state.workspaces.remove(at: state.workspaceIndex)
            state.activeWorkspaceID = state.workspaces[0].id
        }) { reloadWorkspace(from: previous) }
    }

    private func reloadWorkspace(from previous: [SourceFolder]) {
        if previous == state.folders {
            if scanTask == nil && !previous.isEmpty { refresh() }
            return
        }
        if !photos.isEmpty { photos = PhotoList([]) }
        collectionList = nil
        if !issues.isEmpty { issues = [:] }
        refresh()
    }

    @discardableResult
    func chooseFolders() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Photo Folders"
        panel.prompt = "Add Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return false }
        return addFolders(panel.urls)
    }

    @discardableResult
    func addFolders(_ urls: [URL]) -> Bool {
        var paths = Set(state.folders.map(\.location.path))
        let additions = urls.compactMap { url -> SourceFolder? in
            guard url.isFileURL else { return nil }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard (try? canonical.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  paths.insert(canonical.path).inserted else { return nil }
            return SourceFolder(location: FileReference(canonical))
        }
        guard !additions.isEmpty, change(reindexMarks: false, { $0.folders.append(contentsOf: additions) }) else { return false }
        refresh()
        return true
    }

    func setRecursion(_ enabled: Bool, for id: UUID) {
        guard let index = state.folders.firstIndex(where: { $0.id == id }), state.folders[index].recursive != enabled else { return }
        if change(reindexMarks: false, { $0.folders[index].recursive = enabled }) { refresh() }
    }

    func removeFolder(_ id: UUID) {
        guard let index = state.folders.firstIndex(where: { $0.id == id }) else { return }
        if change(reindexMarks: false, { $0.folders.remove(at: index) }) { refresh() }
    }

    static func normalizedShortcut(_ input: String?) -> String? {
        let key = input?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
        return key?.isEmpty == false ? key : nil
    }

    func shortcutIssue(_ input: String?, excluding ids: Set<UUID> = []) -> String? {
        guard let key = Self.normalizedShortcut(input) else { return nil }
        guard key.count == 1, key.first?.isLetter == true else { return "Choose a single letter." }
        if let owner = state.collections.first(where: { !ids.contains($0.id) && $0.shortcut == key }) {
            return "This letter is used by “\(owner.name)”."
        }
        return nil
    }

    @discardableResult
    func newCollection(_ name: String, color: CollectionColor? = nil, shortcut: String? = nil, including url: URL? = nil) -> UUID? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, shortcutIssue(shortcut) == nil else { return nil }
        let collection = PhotoCollection(name: title, color: color ?? nextColor, shortcut: Self.normalizedShortcut(shortcut),
                                         items: url.map { [FileReference($0)] } ?? [])
        return change { $0.collections.append(collection) } ? collection.id : nil
    }

    @discardableResult
    func editCollection(_ id: UUID, name: String, color: CollectionColor, shortcut: String?) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, shortcutIssue(shortcut, excluding: [id]) == nil,
              let index = state.collections.firstIndex(where: { $0.id == id }) else { return false }
        return change {
            $0.collections[index].name = title
            $0.collections[index].color = color
            $0.collections[index].shortcut = Self.normalizedShortcut(shortcut)
        }
    }

    func deleteCollection(_ id: UUID) {
        deleteCollections([id])
    }

    func togglePin(_ id: UUID) {
        guard let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        change(reindexMarks: false) { $0.collections[index].isPinned.toggle() }
    }

    @discardableResult
    func deleteCollections(_ ids: Set<UUID>) -> Bool {
        change { $0.collections.removeAll { ids.contains($0.id) } }
    }

    func mergeCollections(_ ids: Set<UUID>, name: String, color: CollectionColor, shortcut: String? = nil) -> UUID? {
        let sources = state.collections.filter { ids.contains($0.id) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sources.count >= 2, sources.count == ids.count, !title.isEmpty,
              shortcutIssue(shortcut, excluding: ids) == nil else { return nil }
        var seen = Set<String>()
        let references = sources.flatMap(\.items).filter { seen.insert($0.path).inserted }
        var merged = PhotoCollection(name: title, color: color, shortcut: Self.normalizedShortcut(shortcut), items: references)
        merged.isPinned = sources.contains(where: \.isPinned)
        return change { state in
            let position = state.collections.firstIndex { ids.contains($0.id) } ?? 0
            state.collections.removeAll { ids.contains($0.id) }
            state.collections.insert(merged, at: position)
        } ? merged.id : nil
    }

    func toggleMark(_ url: URL, in id: UUID) {
        guard let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        let path = url.standardizedFileURL.path
        change {
            if $0.collections[index].items.contains(where: { $0.path == path }) {
                $0.collections[index].items.removeAll { $0.path == path }
            } else {
                $0.collections[index].items.append(FileReference(url))
            }
        }
    }

    func unmark(_ paths: Set<String>, in id: UUID) {
        guard let index = state.collections.firstIndex(where: { $0.id == id }) else { return }
        change { $0.collections[index].items.removeAll { paths.contains($0.path) } }
    }
}
