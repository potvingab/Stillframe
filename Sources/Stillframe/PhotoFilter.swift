import Foundation

enum CapturePeriod: String, CaseIterable, Codable { case any = "Any date", day = "One day", range = "Date range" }

struct FolderFilter: Equatable {
    var includeByDefault = true
    private(set) var overrides: [String: Bool] = [:]

    var active: Bool { !includeByDefault || !overrides.isEmpty }

    func includes(_ path: String) -> Bool {
        var current = path
        while !current.isEmpty {
            if let rule = overrides[current] { return rule }
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return includeByDefault
    }

    func hasExceptions(under path: String) -> Bool {
        let prefix = path == "/" ? "/" : path + "/"
        return overrides.keys.contains { $0 != path && $0.hasPrefix(prefix) }
    }

    mutating func setIncluded(_ included: Bool, at path: String) {
        let prefix = path == "/" ? "/" : path + "/"
        overrides = overrides.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
        if includes(path) != included { overrides[path] = included }
    }
}

struct PhotoFilter: Equatable {
    var folders = FolderFilter()
    var format: String?
    var camera: String?
    var lens: String?
    var filename = ""
    var period: CapturePeriod = .any
    var start = Self.cameraToday
    var end = Self.cameraToday

    // EXIF dates represent the day on the camera's clock. Use UTC as a wall-time representation.
    private static var cameraToday: Date {
        var calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        calendar.timeZone = .gmt
        return calendar.date(from: components)!
    }

    var usesMetadata: Bool { period != .any || camera != nil || lens != nil }
    var active: Bool { folders.active || format != nil || usesMetadata || !filename.isEmpty }
    var captureInterval: DateInterval? {
        guard period != .any else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let lower = calendar.startOfDay(for: start)
        let upper = calendar.startOfDay(for: period == .day ? start : max(start, end))
        return DateInterval(start: lower, end: calendar.date(byAdding: .day, value: 1, to: upper)!)
    }

    static func format(of photo: Photo) -> String {
        switch photo.url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "JPEG"
        case "tif", "tiff": return "TIFF"
        default: return photo.url.pathExtension.uppercased()
        }
    }
}

struct SourceGroups: Equatable {
    let sources: [SourceFolder]

    init(_ folders: [SourceFolder]) {
        sources = folders.sorted { $0.location.path.count > $1.location.path.count }
    }

    // Overlapping source folders count an original once, under its most specific root.
    func group(for photo: Photo) -> String {
        let parent = photo.url.deletingLastPathComponent().path
        return sources.first {
            let path = $0.location.path
            return parent == path || ($0.recursive && parent.hasPrefix(path.hasSuffix("/") ? path : path + "/"))
        }?.location.path ?? parent
    }
}

extension PhotoSorter {
    func equipment(in photos: PhotoList) throws -> (cameras: [String], lenses: [String]) {
        loadDatesIfNeeded()
        defer { saveDatesIfNeeded() }
        var cameras = Set<String>(), lenses = Set<String>()
        for photo in photos {
            try Task.checkCancellation()
            guard let info = facts(of: photo) else { continue }
            if let camera = info.camera, !camera.isEmpty { cameras.insert(camera) }
            if let lens = info.lens, !lens.isEmpty { lenses.insert(lens) }
        }
        return (cameras.sorted(), lenses.sorted())
    }

    func filtered(_ photos: PhotoList, by filter: PhotoFilter) throws -> PhotoList {
        guard filter.active else { return photos }
        if filter.usesMetadata { loadDatesIfNeeded() }
        defer { saveDatesIfNeeded() }
        let interval = filter.captureInterval
        var folderMatches: [String: Bool] = [:]
        let matches = try photos.filter { photo in
            try Task.checkCancellation()
            if filter.folders.active {
                let path = photo.url.deletingLastPathComponent().path
                let included = folderMatches[path] ?? filter.folders.includes(path)
                folderMatches[path] = included
                if !included { return false }
            }
            if let format = filter.format, PhotoFilter.format(of: photo) != format { return false }
            if !filter.filename.isEmpty, !photo.url.lastPathComponent.localizedCaseInsensitiveContains(filter.filename) { return false }
            if filter.usesMetadata {
                let metadata = facts(of: photo)
                if let camera = filter.camera, metadata?.camera != camera { return false }
                if let lens = filter.lens, metadata?.lens != lens { return false }
                if let interval {
                    guard let date = metadata?.taken, date >= interval.start, date < interval.end else { return false }
                }
            }
            return true
        }
        return PhotoList(matches)
    }
}

struct PictureStatistics {
    struct Count {
        var total = 0
        var visible = 0
    }
    var folders: [String: Count] = [:]
    var bytes: Int64 = 0
    var visibleBytes: Int64 = 0
    var unknownSizes = 0

    static func read(all: PhotoList, visible: PhotoList, groups: SourceGroups) async throws -> Self {
        var stats = Self()
        for root in groups.sources { stats.folders[root.location.path] = Count() }
        for photo in all {
            try Task.checkCancellation()
            let included = visible.position(of: photo.id) != nil
            let folder = groups.group(for: photo)
            stats.folders[folder, default: Count()].total += 1
            if included { stats.folders[folder]?.visible += 1 }
            if let size = photo.fileSize ?? (try? photo.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) {
                stats.bytes += size
                if included { stats.visibleBytes += size }
            } else { stats.unknownSizes += 1 }
        }
        return stats
    }
}

extension PhotoSorter {
    func filterOptions(in photos: PhotoList, groups: SourceGroups) -> (folders: [String], formats: [String]) {
        var directories = Set(groups.sources.map(\.location.path))
        var formats = Set<String>()
        for photo in photos {
            if Task.isCancelled { break }
            directories.insert(photo.url.deletingLastPathComponent().path)
            formats.insert(PhotoFilter.format(of: photo))
        }
        // Include intermediate directories only when they connect two entries in this library.
        var folders = directories
        for directory in directories where directory != "/" {
            if Task.isCancelled { break }
            var path = (directory as NSString).deletingLastPathComponent
            var ancestors: [String] = []
            while !path.isEmpty && path != "/" && !folders.contains(path) {
                ancestors.append(path)
                path = (path as NSString).deletingLastPathComponent
            }
            if folders.contains(path) { folders.formUnion(ancestors) }
        }
        return (folders.sorted(), formats.sorted())
    }
}
