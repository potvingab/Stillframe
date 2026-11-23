import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Stillframe

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillframeTests-\(UUID())", isDirectory: true)
    var source: URL { root.appendingPathComponent("Source", isDirectory: true) }
    var nested: URL { source.appendingPathComponent("Nested", isDirectory: true) }
    var main: URL { source.appendingPathComponent("picture.jpg") }
    var other: URL { nested.appendingPathComponent("portrait.jpg") }
    var save: URL { root.appendingPathComponent("State/library.json") }

    init(width: Int = 120, height: Int = 80) throws {
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (url, orientation) in [(main, 1), (other, 6)] {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Fixture camera"],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2024:03:04 13:27:12",
                    kCGImagePropertyExifLensModel: "XF18-55mmF2.8-4 R LM OIS",
                    kCGImagePropertyExifExposureTime: 1.0 / 950,
                    kCGImagePropertyExifFocalLength: 55
                ],
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["Foothills", "Evening"]]
            ] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
        }
        try Data().write(to: source.appendingPathComponent("notes.txt"))
        try Data().write(to: source.appendingPathComponent(".hidden.jpg"))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func foldersAndMarksSurviveRelaunch() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let original = try Data(contentsOf: f.main)
    let library = Library(saveURL: f.save)
    library.addFolders([f.source, f.source])
    #expect(library.state.folders.count == 1)
    let folder = try #require(library.state.folders.first)
    #expect(folder.recursive)
    #expect(FolderScanner.scan([folder]).photos.count == 2)
    library.addFolders([f.nested])
    #expect(FolderScanner.scan(library.state.folders).photos.count == 2)
    library.removeFolder(try #require(library.state.folders.last).id)
    library.setRecursion(false, for: folder.id)
    #expect(FolderScanner.scan(library.state.folders).photos.map(\.url.lastPathComponent) == ["picture.jpg"])

    let first = try #require(library.newCollection(" First ", including: f.main))
    let second = try #require(library.newCollection("Second"))
    library.toggleMark(f.main, in: second)
    library.toggleMark(f.other, in: second)
    let restored = Library(saveURL: f.save)
    #expect(restored.state.folders.first?.recursive == false)
    #expect(restored.state.collections.map(\.items.count) == [1, 2])
    #expect(restored.state.collections.first?.name == "First")
    restored.removeFolder(folder.id)
    #expect(restored.photos.isEmpty)
    #expect(restored.state.collections.map(\.items.count) == [1, 2])
    restored.toggleMark(f.main, in: second)
    #expect(restored.state.collections.last?.items.map(\.path) == [f.other.standardizedFileURL.path])
    restored.editCollection(second, name: "Trips", color: .sky, shortcut: "T")
    restored.unmark([f.other.standardizedFileURL.path], in: second)
    restored.deleteCollection(first)
    let final = Library(saveURL: f.save)
    #expect(final.state.folders.isEmpty)
    #expect(final.state.collections.map(\.name) == ["Trips"])
    #expect(final.state.collections[0].items.isEmpty)
    #expect(try Data(contentsOf: f.main) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.save.deletingLastPathComponent().path) == ["library.json"])
}

@Test func previewsHonorOrientationAndPixelBudget() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let original = try Data(contentsOf: f.other)
    let image = try #require(await ImageDecoder.previews.decode(f.other, pixels: 60, modified: nil))
    #expect(image.width == 40)
    #expect(image.height == 60)
    #expect(try Data(contentsOf: f.other) == original)
}

@Test func folderGroupingAndSortDirectionAreIndependent() throws {
    let base = URL(fileURLWithPath: "/Pictures", isDirectory: true)
    let paths = ["2023/Coast/frame10.jpg", "2024/Coast/frame2.jpg", "2023/Coast/frame2.jpg", "2021/Alps/frame20.jpg"]
    let dates: [Double?] = [30, 10, nil, 20]
    let photos = paths.enumerated().map { index, path in
        Photo(url: base.appendingPathComponent(path), modified: dates[index].map(Date.init(timeIntervalSince1970:)))
    }

    func indices(_ key: PhotoSortKey, descending: Bool, grouped: Bool) throws -> [Int] {
        let order = PhotoOrder(key: key, descending: descending, groupByFolder: grouped)
        return try order.arrange(photos, date: { $0.modified }).map { photos.firstIndex(of: $0)! }
    }

    // The two Coast folders stay distinct, even with identical filenames in both.
    #expect(try indices(.filename, descending: false, grouped: true) == [3, 2, 0, 1])
    #expect(try indices(.filename, descending: true, grouped: true) == [3, 0, 2, 1])
    #expect(try indices(.filename, descending: false, grouped: false) == [2, 1, 0, 3])
    #expect(try indices(.filename, descending: true, grouped: false) == [3, 0, 2, 1])
    #expect(try indices(.modified, descending: false, grouped: false) == [1, 3, 0, 2])
    #expect(try indices(.modified, descending: true, grouped: false) == [0, 3, 1, 2])
    #expect(try indices(.modified, descending: true, grouped: true) == [3, 0, 2, 1])
    #expect(try indices(.added, descending: true, grouped: true) == [3, 2, 0, 1])
}

@Test func dateSortReadsCameraTimeAndRefreshesChangedOriginals() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let cache = f.root.appendingPathComponent("Cache/dates.json")
    let source = try #require(CGImageSourceCreateWithURL(f.main as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    func write(_ url: URL, taken: String?, modified: Double) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exif = taken.map { [kCGImagePropertyExifDateTimeOriginal: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
    }
    let noExif = f.root.appendingPathComponent("unknown.jpg")
    try write(noExif, taken: nil, modified: 300)
    try write(f.other, taken: "2021:05:04 11:00:00", modified: 200)
    try write(f.main, taken: "2024:05:04 11:00:00", modified: 100)
    let list = PhotoList([noExif, f.other, f.main].map { Photo(url: $0, modified: nil) })
    let sorter = PhotoSorter(cacheURL: cache)
    let modified = PhotoOrder(key: .modified, descending: true, groupByFolder: false)
    #expect(try await sorter.sorted(list, by: modified).map(\.url) == [noExif, f.other, f.main])
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    let newest = PhotoOrder(key: .taken, descending: true, groupByFolder: false)
    #expect(try await sorter.sorted(list, by: newest).map(\.url) == [f.main, f.other, noExif])
    #expect(FileManager.default.fileExists(atPath: cache.path))
    let oldest = PhotoOrder(key: .taken, descending: false, groupByFolder: false)
    #expect(try await PhotoSorter(cacheURL: cache).sorted(list, by: oldest).map(\.url) == [f.other, f.main, noExif])
    try write(f.other, taken: "2025:05:04 11:00:00", modified: 400)
    #expect(try await sorter.sorted(list, by: newest).map(\.url) == [f.other, f.main, noExif])
}

@Test @MainActor func savedOrdersPreserveCollectionMarkHistory() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let id = UUID()
    let legacy: [String: Any] = ["folders": [], "collections": [["name": "Trip", "id": id.uuidString,
        "items": [["path": f.other.path], ["path": f.main.path]]]]]
    try FileManager.default.createDirectory(at: f.save.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: legacy).write(to: f.save)
    let library = Library(saveURL: f.save)
    #expect(library.picturesSort == .pictures)
    #expect(library.state.collections.first?.sort == .collection)
    let second = try #require(library.newCollection("Shortlist"))
    let pictures = PhotoOrder(key: .taken, descending: true, groupByFolder: false)
    let recentlyAdded = PhotoOrder(key: .added, descending: true, groupByFolder: false)
    library.setSort(pictures, for: nil)
    library.setSort(recentlyAdded, for: id)
    let restored = Library(saveURL: f.save)
    #expect(restored.picturesSort == pictures)
    #expect(restored.state.collections.first { $0.id == second }?.sort == .collection)
    let collection = try #require(restored.state.collections.first { $0.id == id })
    #expect(collection.sort == recentlyAdded)
    #expect(collection.items.map(\.path) == [f.other.path, f.main.path])
    let sorter = PhotoSorter(cacheURL: nil)
    #expect(try await sorter.sorted(restored.photos(in: collection), by: collection.sort).map(\.id) == [f.main.path, f.other.path])
    restored.toggleMark(f.other, in: id)
    restored.toggleMark(f.other, in: id)
    let changed = restored.state.collections[0]
    #expect(try await sorter.sorted(restored.photos(in: changed), by: changed.sort).map(\.id) == [f.other.path, f.main.path])
}

@Test @MainActor func refreshingUpdatesDateOrderForMarksOutsideSourceFolders() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let library = Library(saveURL: f.save)
    library.addFolders([f.nested])
    while library.scanning { await Task.yield() }
    let scanned = library.photos
    let id = try #require(library.newCollection("Mixed", including: f.main))
    library.toggleMark(f.other, in: id)
    let collection = library.state.collections[0]
    let original = library.photos(in: collection)
    let sorter = PhotoSorter(cacheURL: nil)
    let newest = PhotoOrder(key: .modified, descending: true, groupByFolder: false)
    let baseline = try #require(scanned.first?.modified)
    try FileManager.default.setAttributes([.modificationDate: baseline.addingTimeInterval(-3600)], ofItemAtPath: f.main.path)
    #expect(try await sorter.sorted(original, by: newest).first?.id == f.other.path)
    try FileManager.default.setAttributes([.modificationDate: baseline.addingTimeInterval(3600)], ofItemAtPath: f.main.path)
    library.refresh()
    while library.scanning { await Task.yield() }
    #expect(library.photos === scanned)
    let refreshed = library.photos(in: collection)
    #expect(refreshed !== original)
    #expect(try await sorter.sorted(refreshed, by: newest).first?.id == f.main.path)
}

@Test @MainActor func enumeratedPhotoMatchesItsSavedMark() throws {
    let f = try Fixture()
    defer { f.clean() }
    let library = Library(saveURL: f.save)
    library.addFolders([f.source])
    let photo = try #require(FolderScanner.scan(library.state.folders).photos.first)
    _ = library.newCollection("Marked", including: photo.url)
    #expect(library.state.collections.first?.items.first?.path == photo.id)
}

@Test @MainActor func dragPayloadReferencesOriginalFiles() throws {
    let f = try Fixture()
    defer { f.clean() }
    let source = CollectionGrid.Coordinator(selected: .constant([]))
    source.items = .photos(PhotoList([f.main, f.other].map { Photo(url: $0, modified: nil) }))
    let grid = NSCollectionView()
    for (index, file) in [f.main, f.other].enumerated() {
        let writer = source.collectionView(grid, pasteboardWriterForItemAt: IndexPath(item: index, section: 0))
        #expect((writer as? NSURL)?.path == file.path)
    }
    try FileManager.default.removeItem(at: f.other)
    #expect(source.collectionView(grid, pasteboardWriterForItemAt: IndexPath(item: 1, section: 0)) == nil)
}

@Test @MainActor func offlineSourcePreservesCollection() throws {
    let f = try Fixture()
    defer { f.clean() }
    let library = Library(saveURL: f.save)
    library.addFolders([f.source])
    _ = library.newCollection("Keep", including: f.main)
    try FileManager.default.removeItem(at: f.source)
    let restored = Library(saveURL: f.save)
    let scan = FolderScanner.scan(restored.state.folders)
    #expect(scan.photos.isEmpty)
    #expect(scan.issues.count == 1)
    #expect(restored.state.collections.first?.items.first?.path == f.main.path)
}

@Test @MainActor func failedStateWriteDoesNotPublishChange() throws {
    let f = try Fixture()
    defer { f.clean() }
    let blocked = f.main.appendingPathComponent("library.json")
    let library = Library(saveURL: blocked)
    #expect(library.newCollection("Unsaved") == nil)
    #expect(library.state.collections.isEmpty)
    #expect(library.message != nil)
}

@Test @MainActor func collectionGridOffersOnlyCopyOperations() throws {
    let f = try Fixture()
    defer { f.clean() }
    _ = NSApplication.shared
    let view = NSHostingView(rootView: CollectionGrid(items: PhotoList([Photo(url: f.main, modified: nil)]), selected: .constant([])))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()

    func findGrid(in view: NSView) -> NSCollectionView? {
        if let grid = view as? NSCollectionView { return grid }
        for child in view.subviews {
            if let grid = findGrid(in: child) { return grid }
        }
        return nil
    }
    let grid = try #require(findGrid(in: view))
    let session = NSDraggingSession()
    #expect(grid.draggingSession(session, sourceOperationMaskFor: .outsideApplication) == .copy)
    #expect(grid.draggingSession(session, sourceOperationMaskFor: .withinApplication) == .copy)
}

@Test @MainActor func filledGridsOpenOnClickAndSelectFromEitherEdge() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let covers = (0..<30).map { PhotoCollection(name: "Collection \($0)") }
    let photos = PhotoList(covers.map { Photo(url: f.root.appendingPathComponent($0.name), modified: nil) })
    for testingPhotos in [false, true] {
        var selectedPhotos: Set<String> = []
        var selectedCovers: Set<UUID> = []
        var opened: [Int] = []
        func content(selecting: Bool) -> CollectionGrid {
            if testingPhotos {
                return CollectionGrid(items: photos, selected: Binding(get: { selectedPhotos }, set: { selectedPhotos = $0 }),
                                      selecting: selecting) { url in opened.append(photos.position(of: url.path)!) }
            }
            return CollectionGrid(collections: covers, choices: Binding(get: { selectedCovers }, set: { selectedCovers = $0 }),
                                  selecting: selecting, open: { id in opened.append(covers.firstIndex { $0.id == id }!) },
                                  edit: { _ in }, togglePin: { _ in }, delete: { _ in })
        }
        let host = NSHostingView(rootView: content(selecting: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 340),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        func findGrid(in view: NSView) -> NSCollectionView? {
            if let grid = view as? NSCollectionView { return grid }
            return view.subviews.lazy.compactMap { findGrid(in: $0) }.first
        }
        let grid = try #require(findGrid(in: host))
        try await Task.sleep(for: .milliseconds(50))
        let first = try #require(grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
        let center = NSPoint(x: first.midX, y: first.midY)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: grid.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApplication.shared.sendEvent(event)
        }
        func click() throws {
            try mouse(.leftMouseDown, at: center)
            try mouse(.leftMouseUp, at: center)
        }
        try click()
        #expect(opened == [0])
        #expect(grid.selectionIndexPaths.isEmpty)
        host.rootView = content(selecting: true)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        try click()
        #expect(grid.selectionIndexPaths == [IndexPath(item: 0, section: 0)])
        try click()
        #expect(grid.selectionIndexPaths.isEmpty)
        host.rootView = content(selecting: false)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let left = NSPoint(x: 18, y: first.midY), right = NSPoint(x: grid.visibleRect.maxX - 18, y: first.midY)
        #expect(grid.indexPathForItem(at: left) == nil && grid.indexPathForItem(at: right) == nil)
        #expect(grid.frame.height > grid.visibleRect.height)
        for (start, end) in [(left, right), (right, left), (center, right)] {
            try mouse(.leftMouseDown, at: start)
            try mouse(.leftMouseDragged, at: end)
            try mouse(.leftMouseUp, at: end)
            #expect(grid.selectionIndexPaths.count > 1)
            #expect(testingPhotos ? selectedPhotos.count > 1 : selectedCovers.count > 1)
            #expect(opened == [0])
            try mouse(.leftMouseDown, at: left)
            try mouse(.leftMouseUp, at: left)
            #expect(grid.selectionIndexPaths.isEmpty)
        }
    }
}

@Test @MainActor func legacyCollectionsKeepMarksAndAcceptColorsAndUniqueLetters() throws {
    let f = try Fixture()
    defer { f.clean() }
    let legacy = Library(saveURL: f.save)
    let id = try #require(legacy.newCollection("Existing", including: f.main))
    var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.save)) as? [String: Any])
    var collections = try #require(document["collections"] as? [[String: Any]])
    collections[0].removeValue(forKey: "color")
    collections[0].removeValue(forKey: "shortcut")
    collections[0].removeValue(forKey: "isPinned")
    document["collections"] = collections
    try JSONSerialization.data(withJSONObject: document).write(to: f.save)
    let library = Library(saveURL: f.save)
    let path = f.main.standardizedFileURL.path
    #expect(library.message == nil)
    #expect(!library.state.collections[0].isPinned)
    #expect(library.collections(containing: path).map(\.id) == [id])
    #expect(library.editCollection(id, name: "First", color: .sky, shortcut: "F"))
    #expect(library.newCollection("Conflict", shortcut: "f") == nil)
    #expect(library.newCollection("Invalid", shortcut: "ab") == nil)
    let second = try #require(library.newCollection("Second", color: .rose, shortcut: "S", including: f.main))
    #expect(!library.editCollection(second, name: "Second", color: .violet, shortcut: "F"))
    let restored = Library(saveURL: f.save)
    #expect(restored.collections(containing: path).map(\.color) == [.sky, .rose])
    #expect(restored.state.collections.compactMap(\.shortcut) == ["f", "s"])
    restored.toggleMark(f.main, in: second)
    #expect(restored.collections(containing: path).map(\.id) == [id])
    #expect(restored.editCollection(id, name: "First", color: .amber, shortcut: ""))
    #expect(restored.newCollection("Reassigned", shortcut: "F") != nil)
}

@Test func inspectorReadsOrientedSizeAndEmbeddedTags() throws {
    let f = try Fixture()
    defer { f.clean() }
    let details = PhotoMetadata.read(f.other)
    #expect(details.readable)
    #expect(details.summary.contains { $0.label == "Dimensions" && $0.value == "80 × 120 px" })
    #expect(details.summary.contains { $0.label == "File size" })
    #expect(details.capture.contains { $0.label == "Camera" && $0.value == "Fixture camera" })
    let wallTime = try Date("2024-03-04T13:27:12Z", strategy: .iso8601)
        .formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: .gmt))
    #expect(details.capture.contains { $0.label == "Taken" && $0.value == wallTime })
    #expect(details.capture.contains { $0.label == "Exposure" && $0.value == "1/950 s" })
    #expect(details.capture.contains { $0.label == "Focal length" && $0.value == "55 mm" })
    #expect(details.capture.contains { $0.label == "Lens" && $0.value == "XF18-55mmF2.8-4 R LM OIS" })
    #expect(details.groups.flatMap(\.fields).contains { $0.value.contains("Foothills") })
    #expect(!PhotoMetadata.read(f.root.appendingPathComponent("missing.jpg")).readable)
}

@Test @MainActor func filmstripLayoutAndSelectionNearEndOfLargeLibrary() {
    let count = 20_000
    let photos = PhotoList((0..<count).map { Photo(url: URL(fileURLWithPath: "/Pictures/\($0).jpg"), modified: nil) })
    #expect(photos.position(of: "/Pictures/19998.jpg") == 19_998)
    #expect(photos.position(of: "/Pictures/missing.jpg") == nil)
    let viewport = CGRect(x: 19_990 * FilmstripLayout.stride, y: 0, width: 925, height: 58)
    #expect(FilmstripLayout.indices(in: viewport, count: count) == 19_990..<20_000)
    #expect(FilmstripLayout.indices(in: viewport, count: 200_000).count == 11)
    #expect(FilmstripLayout.indices(in: viewport, count: 0).isEmpty)
    #expect(FilmstripLayout.indices(in: .infinite, count: count) == 0..<count)
}

@Test @MainActor func collectionCarouselReusesOrderingUntilMembershipChanges() throws {
    let f = try Fixture()
    defer { f.clean() }
    let library = Library(saveURL: f.save)
    let id = try #require(library.newCollection("Two photos", including: f.main))
    let first = library.photos(in: library.state.collections[0])
    #expect(library.photos(in: library.state.collections[0]) === first)
    library.toggleMark(f.other, in: id)
    let next = library.photos(in: library.state.collections[0])
    #expect(first.count == 1)
    #expect(next.position(of: f.other.standardizedFileURL.path) == 1)
    library.toggleMark(f.main, in: id)
    let remaining = library.photos(in: library.state.collections[0])
    #expect(remaining.position(of: f.other.standardizedFileURL.path) == 0)
}

@Test func previewCanImmediatelyUseVersionedFilmstripThumbnail() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let version = Date()
    let decoded = try #require(await ImageDecoder.thumbnails.decode(f.other, pixels: 128, modified: version))
    #expect(ImageDecoder.thumbnails.cached(f.other, pixels: 128, modified: version) === decoded)
    #expect(ImageDecoder.thumbnails.cached(f.other, pixels: 128, modified: version.addingTimeInterval(1)) == nil)
    #expect(ImageDecoder.thumbnails.cached(f.main, pixels: 128, modified: version) == nil)
}

@Test @MainActor func distantSelectionScrollsIntoFilmstripViewport() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let library = Library(saveURL: f.save)
    let photos = PhotoList((0..<15_000).map { Photo(url: f.root.appendingPathComponent("\($0).jpg"), modified: nil) })
    func strip(_ index: Int) -> Filmstrip {
        Filmstrip(photos: photos, selected: index, library: library, onSelect: { _ in }, onOpen: { _ in })
    }
    let host = NSHostingView(rootView: strip(0))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: FilmstripLayout.tile.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.layoutIfNeeded()
    func grid(in view: NSView) -> NSCollectionView? {
        if let collection = view as? NSCollectionView { return collection }
        return view.subviews.lazy.compactMap { grid(in: $0) }.first
    }
    let collection = try #require(grid(in: host))
    try await Task.sleep(for: .milliseconds(50))
    host.rootView = strip(14_999)
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(collection.selectionIndexPaths == [IndexPath(item: 14_999, section: 0)])
    #expect(collection.visibleRect.contains(FilmstripLayout.frame(at: 14_999)),
            "document: \(collection.frame), clip: \(String(describing: collection.enclosingScrollView?.contentView.bounds)), content: \(String(describing: collection.collectionViewLayout?.collectionViewContentSize))")
    #expect(collection.visibleItems().count <= 12)
    let viewport = try #require(collection.enclosingScrollView?.superview as? FilmstripViewport)
    #expect(!viewport.bar.isHidden && viewport.bar.isEnabled)
    #expect(viewport.bar.alphaValue == 1)
    #expect(viewport.scroll.frame.contains(viewport.bar.frame))
    #expect(viewport.bar.frame.minY == viewport.scroll.frame.minY)
    #expect(viewport.scroll.frame.height == FilmstripLayout.tile.height)
    viewport.bar.doubleValue = 0.5
    viewport.scrub(viewport.bar)
    let midpoint = (collection.frame.width - viewport.scroll.contentSize.width) / 2
    #expect(abs(collection.visibleRect.minX - midpoint) < 2)
    let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -300, wheel3: 0))
    viewport.scroll.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
    #expect(collection.visibleRect.minX > midpoint)
    #expect(viewport.bar.doubleValue > 0.5)
    #expect(viewport.bar.rect(for: .knob).width > 0)
    #expect(viewport.bar.alphaValue == 1)
    #expect(collection.visibleItems().count <= 12)
    try await Task.sleep(for: .seconds(1.85))
    #expect(viewport.bar.alphaValue == 0)
    #expect(viewport.hitTest(NSPoint(x: 60, y: 5)) !== viewport.bar)

}

@Test @MainActor func photoMagnificationRefinesDetailAndResetsToFit() async throws {
    let f = try Fixture(width: 1500, height: 1000)
    defer { f.clean() }
    let version = Date()
    let host = NSHostingView(rootView: FileImage(url: f.other, modified: version, fit: true).environment(\.displayScale, 1))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    func canvas(in view: NSView) -> PhotoCanvas? {
        if let photo = view as? PhotoCanvas { return photo }
        return view.subviews.lazy.compactMap { canvas(in: $0) }.first
    }
    window.layoutIfNeeded()
    for _ in 0..<100 where (canvas(in: host)?.scroll.documentView as? NSImageView)?.image == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let viewer = try #require(canvas(in: host))
    let scroll = viewer.scroll
    let document = try #require(scroll.documentView as? NSImageView)
    let fittedPixels = try #require(document.image?.size.height)
    #expect(scroll.allowsMagnification)
    #expect(scroll.magnification == 1)
    #expect(abs(document.frame.midX - scroll.contentView.bounds.midX) < 1)
    #expect(viewer.resetButton.isHidden)

    let zoom = try #require(viewer.zoom)
    #expect(!zoom.canZoomOut && zoom.canZoomIn)
    viewer.stepZoom(inward: true)
    #expect(scroll.magnification == 1.5)
    #expect(zoom.canZoomOut && !viewer.resetButton.isHidden)
    for _ in 0..<8 { viewer.stepZoom(inward: true) }
    #expect(scroll.magnification == scroll.maxMagnification)
    #expect(!zoom.canZoomIn)
    viewer.stepZoom(inward: false)
    #expect(scroll.magnification == 6 && zoom.canZoomIn)
    viewer.resetButton.performClick(nil)
    #expect(scroll.magnification == 1)
    #expect(!zoom.canZoomOut)

    let focus = NSPoint(x: document.frame.midX, y: document.frame.midY)
    scroll.setMagnification(3, centeredAt: focus)
    let pixels = Int(ceil(max(scroll.frame.width, scroll.frame.height) * 3 / 128)) * 128
    for _ in 0..<100 where ImageDecoder.previews.cached(f.other, pixels: pixels, modified: version) == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let detail = try #require(ImageDecoder.previews.cached(f.other, pixels: pixels, modified: version))
    #expect(CGFloat(detail.height) > fittedPixels)
    for _ in 0..<100 where document.image?.size.height != CGFloat(detail.height) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(document.image?.size.height == CGFloat(detail.height))
    #expect(abs(scroll.magnification - 3) < 0.001)
    let oldOrigin = scroll.contentView.bounds.origin
    scroll.contentView.scroll(to: NSPoint(x: oldOrigin.x + 15, y: oldOrigin.y + 15))
    #expect(scroll.contentView.bounds.origin != oldOrigin)
    #expect(!viewer.resetButton.isHidden)
    viewer.resetButton.performClick(nil)
    for _ in 0..<100 where scroll.magnification > 1 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(scroll.magnification == 1)
    #expect(abs(document.frame.midX - scroll.contentView.bounds.midX) < 1)
    #expect(viewer.resetButton.isHidden)
}

@Test @MainActor func changingPicturesReusesCanvasAndClearsStaleZoomAndPreview() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let host = NSHostingView(rootView: FileImage(url: f.main, fit: true))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.layoutIfNeeded()
    func canvas(in view: NSView) -> PhotoCanvas? {
        if let canvas = view as? PhotoCanvas { return canvas }
        return view.subviews.lazy.compactMap { canvas(in: $0) }.first
    }
    let viewer = try #require(canvas(in: host))
    let imageView = try #require(viewer.scroll.documentView as? NSImageView)
    for _ in 0..<100 where imageView.image == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(imageView.image != nil)
    viewer.stepZoom(inward: true)
    #expect(viewer.scroll.magnification > 1)

    let missing = f.nested.appendingPathComponent(f.main.lastPathComponent)
    host.rootView = FileImage(url: missing, fit: true)
    window.layoutIfNeeded()
    for _ in 0..<100 where !viewer.scroll.isHidden { try await Task.sleep(for: .milliseconds(10)) }
    #expect(canvas(in: host) === viewer)
    #expect(imageView.image == nil)
    #expect(viewer.scroll.magnification == 1)
    #expect(viewer.resetButton.isHidden)

    host.rootView = FileImage(url: f.other, fit: true)
    window.layoutIfNeeded()
    for _ in 0..<100 where imageView.image == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(canvas(in: host) === viewer)
    #expect(!viewer.scroll.isHidden)
    let size = try #require(imageView.image?.size)
    #expect(size.height > size.width)
}

@Test @MainActor func customColorsSurviveRelaunchAlongsideVintagePresets() throws {
    let f = try Fixture()
    defer { f.clean() }
    let library = Library(saveURL: f.save)
    let blue = try #require(CollectionColor(pickerColor: Color(.sRGB, red: 0, green: 0.5, blue: 1)))
    #expect(blue.rawValue == "#0080FF")
    let id = try #require(library.newCollection("Custom", color: blue, including: f.main))
    let restored = Library(saveURL: f.save)
    #expect(restored.collections(containing: f.main.standardizedFileURL.path).first?.color == blue)
    #expect(restored.editCollection(id, name: "Custom", color: .rose, shortcut: nil))
    #expect(Library(saveURL: f.save).state.collections.first?.color == .rose)
    #expect(try JSONDecoder().decode(CollectionColor.self, from: Data("\"sage\"".utf8)) == .sage)
}

@Test @MainActor func collectionControlsAndSwatchCheckmarksStayLegible() {
    let custom = ["#FFFFFF", "#F5F0D7", "#808080", "#252621", "#000000"].compactMap(CollectionColor.init(rawValue:))
    for scheme in [ColorScheme.light, .dark] {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        func luminance(_ color: Color) -> Float {
            let rgb = color.resolve(in: environment)
            return 0.2126 * rgb.linearRed + 0.7152 * rgb.linearGreen + 0.0722 * rgb.linearBlue
        }
        func contrast(_ first: Color, _ second: Color) -> Float {
            let a = luminance(first), b = luminance(second)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        for color in CollectionColor.presets + custom {
            let accent = color.controlTint(in: scheme)
            #expect(contrast(accent, Palette.mat) >= 4.5)
            #expect(contrast(accent, Palette.paper) >= 4.5)
            #expect(contrast(color.checkmark, color.tint) >= 4.5)
        }
    }
}

@Test func collectionCopiesKeepNamesDistinctAndReportMissingOriginals() throws {
    let f = try Fixture()
    defer { f.clean() }
    let target = f.root.appendingPathComponent("Export", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let duplicate = f.other.deletingLastPathComponent().appendingPathComponent(f.main.lastPathComponent)
    try Data("second".utf8).write(to: duplicate)
    let existing = target.appendingPathComponent(f.main.lastPathComponent)
    try Data("existing".utf8).write(to: existing)
    let result = try CollectionFileActions.copy([f.main, duplicate, target.appendingPathComponent("missing.jpg")], to: target)
    #expect(result.copied == 2)
    #expect(result.failures.count == 1)
    #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    let stem = f.main.deletingPathExtension().lastPathComponent
    #expect(try Data(contentsOf: target.appendingPathComponent(stem + " 2.jpg")) == Data(contentsOf: f.main))
    #expect(try Data(contentsOf: target.appendingPathComponent(stem + " 3.jpg")) == Data(contentsOf: duplicate))
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).count == 3)
}

@Test func tabSwipeLocksDirectionAndSwitchesOncePerGesture() {
    var gesture = TabSwipeGesture()
    gesture.begin(allowed: true)
    #expect(gesture.update(x: -28, y: -1) == nil)
    #expect(gesture.update(x: -42, y: 2) == .collections)
    #expect(gesture.update(x: 150, y: 0) == nil)
    gesture.begin(allowed: true)
    #expect(gesture.update(x: 100, y: 8) == .pictures)
    gesture.begin(allowed: true)
    #expect(gesture.update(x: -8, y: 26) == nil)
    #expect(gesture.update(x: -160, y: 2) == nil)
    gesture.begin(allowed: false)
    #expect(gesture.update(x: 150, y: 0) == nil)
}

@Test @MainActor func swipesStartingInTheWorkspaceStayThere() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.toolbar = NSToolbar(identifier: "ContentSwipeTest")
    let content = window.contentLayoutRect
    for x in [content.minX + 1, content.midX, content.maxX - 1] {
        for y in [content.minY + 1, content.midY, content.maxY - 1] {
            var swipe = TabSwipeGesture()
            swipe.begin(allowed: WorkspaceSwipe.SwipeView.allowsTabSwipe(at: NSPoint(x: x, y: y), in: window))
            #expect(swipe.update(x: -80, y: 0) == nil)
            #expect(swipe.update(x: 180, y: 0) == nil)
        }
    }
}

@Test @MainActor func swipesCanStartAcrossTheNativeToolbar() throws {
    let window = NSWindow(contentRect: NSRect(x: 90, y: 110, width: 700, height: 450),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "SwipeTestToolbar")
    let content = try #require(window.contentView)
    // A magnified photo behind a transparent toolbar still owns pans below the bar.
    let photo = NSScrollView(frame: content.bounds)
    photo.documentView = NSView(frame: photo.bounds)
    photo.allowsMagnification = true
    content.addSubview(photo)
    photo.magnification = 2
    let topOfContent = window.contentLayoutRect.maxY
    try #require(topOfContent < window.frame.height)
    let toolbarY = (topOfContent + window.frame.height) / 2
    for x in [30.0, window.frame.width / 2, window.frame.width - 30] {
        let point = NSPoint(x: x, y: toolbarY)
        let allowed = WorkspaceSwipe.SwipeView.allowsTabSwipe(at: point, in: window)
        var swipe = TabSwipeGesture()
        swipe.begin(allowed: allowed)
        #expect(swipe.update(x: -80, y: 2) == .collections)
        swipe.begin(allowed: allowed)
        #expect(swipe.update(x: 80, y: 2) == .pictures)
    }
    #expect(!WorkspaceSwipe.SwipeView.allowsTabSwipe(at: NSPoint(x: 70, y: topOfContent - 10), in: window))
    #expect(!WorkspaceSwipe.SwipeView.allowsTabSwipe(at: NSPoint(x: -10, y: toolbarY), in: window))
}

@Test @MainActor func workspaceMigrationSwitchingAndCopyingPreserveSources() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let folder = SourceFolder(location: FileReference(f.source), recursive: false)
    let legacy: [String: Any] = [
        "folders": try JSONSerialization.jsonObject(with: JSONEncoder().encode([folder])),
        "collections": []
    ]
    try FileManager.default.createDirectory(at: f.save.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: legacy).write(to: f.save)
    let library = Library(saveURL: f.save)
    #expect(library.state.workspace.name == "My Pictures")
    #expect(library.state.folders.first?.id == folder.id)
    let first = library.state.activeWorkspaceID
    #expect(library.saveWorkspace(name: " Travel ", copyFolders: true))
    let second = library.state.activeWorkspaceID
    library.setRecursion(true, for: folder.id)
    #expect(!library.saveWorkspace(name: "travel", copyFolders: false))
    #expect(library.saveWorkspace(name: "Archive", copyFolders: false))
    #expect(library.state.folders.isEmpty)
    library.switchWorkspace(first)
    library.switchWorkspace(second)
    while library.scanning { await Task.yield() }
    #expect(library.photos.count == 2)
    #expect(library.saveWorkspace(name: "Mountains", copyFolders: false, rename: true))
    let restored = Library(saveURL: f.save)
    #expect(restored.state.activeWorkspaceID == second)
    #expect(restored.state.workspace.name == "Mountains")
    restored.deleteCurrentWorkspace()
    #expect(restored.state.activeWorkspaceID == first)
    #expect(restored.state.folders.first?.recursive == false)
    while restored.scanning { await Task.yield() }
    #expect(restored.photos.count == 1)
}

@Test @MainActor func firstRunDistinguishesNewExistingAndUnreadableLibraries() throws {
    let f = try Fixture()
    defer { f.clean() }
    #expect(Library(saveURL: f.save).isNewLibrary)
    try FileManager.default.createDirectory(at: f.save.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(LibraryState()).write(to: f.save)
    #expect(!Library(saveURL: f.save).isNewLibrary)
    try Data("unreadable".utf8).write(to: f.save)
    let damaged = Library(saveURL: f.save)
    #expect(!damaged.isNewLibrary)
    #expect(damaged.message != nil)
}

@Test @MainActor func identicalWorkspacesReuseScansAndFolderEditsPreserveMarkIndex() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let library = Library(saveURL: f.save)
    let original = library.state.activeWorkspaceID
    let collection = try #require(library.newCollection("Picks", including: f.main))
    let marks = library.markRevision
    #expect(library.addFolders([f.source]))
    #expect(!library.addFolders([f.main, f.source]))
    #expect(library.saveWorkspace(name: "Copy", copyFolders: true))
    while library.scanning { await Task.yield() }
    let scanned = library.photos
    #expect(scanned.count == 2)
    library.switchWorkspace(original)
    #expect(!library.scanning)
    #expect(library.photos === scanned)
    library.setRecursion(false, for: try #require(library.state.folders.first?.id))
    while library.scanning { await Task.yield() }
    #expect(library.photos.count == 1)
    #expect(library.markRevision == marks)
    #expect(library.collections(containing: f.main.standardizedFileURL.path).map(\.id) == [collection])
}

@Test func filtersMatchCameraDaysAndReportDistinctRootTotals() async throws {
    let f = try Fixture()
    defer { f.clean() }
    let folders = [SourceFolder(location: FileReference(f.source)), SourceFolder(location: FileReference(f.nested))]
    let groups = SourceGroups(folders)
    let source = PhotoList(FolderScanner.scan(folders).photos)
    let sorter = PhotoSorter(cacheURL: nil)
    let options = try await sorter.equipment(in: source)
    #expect(options.cameras == ["Fixture camera"])
    #expect(options.lenses == ["XF18-55mmF2.8-4 R LM OIS"])
    let inventory = await sorter.filterOptions(in: source, groups: groups)
    #expect(inventory.formats == ["JPEG"])
    #expect(inventory.folders.count == 2)
    var filter = PhotoFilter()
    #expect(try await sorter.filtered(source, by: filter, groups: groups) === source)
    filter.folders = [folders[1].location.path]
    filter.period = .range
    filter.start = try Date("2024-03-03T00:00:00Z", strategy: .iso8601)
    filter.end = try Date("2024-03-04T00:00:00Z", strategy: .iso8601)
    filter.format = "JPEG"
    filter.camera = options.cameras[0]
    filter.lens = options.lenses[0]
    filter.filename = "PORTR"
    let visible = try await sorter.filtered(source, by: filter, groups: groups)
    #expect(visible.map(\.id) == [f.other.standardizedFileURL.path])
    let stats = try await PictureStatistics.read(all: source, visible: visible, groups: groups)
    #expect(stats.folders[folders[0].location.path]?.total == 1)
    #expect(stats.folders[folders[0].location.path]?.visible == 0)
    #expect(stats.folders[folders[1].location.path]?.visible == 1)
    #expect(stats.unknownSizes == 0)
    #expect(stats.visibleBytes == Int64(try Data(contentsOf: f.other).count))
    #expect(stats.bytes == stats.visibleBytes + Int64(try Data(contentsOf: f.main).count))
    filter.period = .day
    #expect(try await sorter.filtered(source, by: filter, groups: groups).isEmpty)
    filter.start = filter.end
    #expect(try await sorter.filtered(source, by: filter, groups: groups).count == 1)
    filter.folders = []
    #expect(try await sorter.filtered(source, by: filter, groups: groups).isEmpty)
}

@Test @MainActor func mergingAndDeletingCollectionsPreserveOriginalsAndOtherMarks() throws {
    let f = try Fixture()
    defer { f.clean() }
    let original = try Data(contentsOf: f.main)
    let library = Library(saveURL: f.save)
    let a = try #require(library.newCollection("A", shortcut: "a", including: f.main))
    let b = try #require(library.newCollection("B", shortcut: "b", including: f.other))
    library.toggleMark(f.main, in: b)
    let c = try #require(library.newCollection("C", shortcut: "c", including: f.main))
    library.togglePin(b)
    #expect(Library(saveURL: f.save).state.collectionsForDisplay.map(\.id) == [b, a, c])
    library.togglePin(b)
    #expect(library.state.collectionsForDisplay.map(\.id) == [a, b, c])
    library.togglePin(b)
    #expect(library.mergeCollections([a, b], name: "Conflict", color: .rose, shortcut: "C") == nil)
    #expect(library.mergeCollections([a, b], name: "Too long", color: .rose, shortcut: "ab") == nil)
    #expect(library.mergeCollections([a], name: "Invalid", color: .rose) == nil)
    let id = try #require(library.mergeCollections([a, b], name: " Together ", color: .rose, shortcut: " B "))
    let restored = Library(saveURL: f.save)
    #expect(restored.state.collections.map(\.id) == [id, c])
    let merged = restored.state.collections[0]
    #expect(merged.name == "Together")
    #expect(merged.color == .rose)
    #expect(merged.shortcut == "b")
    #expect(merged.isPinned)
    #expect(merged.items.map(\.path) == [f.main, f.other].map(\.standardizedFileURL.path))
    #expect(restored.collections(containing: f.main.standardizedFileURL.path).map(\.id) == [id, c])
    restored.deleteCollections([id, c])
    #expect(Library(saveURL: f.save).state.collections.isEmpty)
    #expect(try Data(contentsOf: f.main) == original)
}

@Test @MainActor func collectionBackSwipeStopsAtTheWholeToolbar() {
    let window = NSWindow(contentRect: NSRect(x: 90, y: 110, width: 700, height: 450),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.toolbar = NSToolbar(identifier: "CollectionSwipeTest")
    let toolbarY = window.contentLayoutRect.maxY
    for x in [7.0, 325, 580, 692] {
        #expect(WorkspaceSwipe.SwipeView.allowsBack(at: NSPoint(x: x, y: toolbarY - 1), in: window))
        let point = NSPoint(x: x, y: (toolbarY + window.frame.height) / 2)
        #expect(!WorkspaceSwipe.SwipeView.allowsBack(at: point, in: window))
        #expect(WorkspaceSwipe.SwipeView.allowsTabSwipe(at: point, in: window))
    }
    #expect(!WorkspaceSwipe.SwipeView.allowsBack(at: NSPoint(x: -2, y: 80), in: window))
}

@Test @MainActor func legacyPathsAndEnumeratedURLsShareOneStatisticsRow() async throws {
    let f = try Fixture()
    defer { f.clean() }
    // A saved location may predate bookmarks or use the other spelling of macOS's /tmp alias.
    let folderPath = "/private" + f.source.standardizedFileURL.path
    guard f.source.standardizedFileURL.path.hasPrefix("/var/") || f.source.standardizedFileURL.path.hasPrefix("/tmp/") else { return }
    let legacy: [String: Any] = [
        "folders": [["id": UUID().uuidString, "location": ["path": folderPath], "recursive": true]],
        "collections": []
    ]
    try FileManager.default.createDirectory(at: f.save.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: legacy).write(to: f.save)
    let library = Library(saveURL: f.save)
    library.refresh()
    while library.scanning { await Task.yield() }
    let counts = try await PictureStatistics.read(all: library.photos, visible: library.photos, groups: SourceGroups(library.state.folders))
    #expect(library.photos.count == 2)
    #expect(counts.folders.count == 1)
    #expect(counts.folders.values.first?.total == 2)
}
