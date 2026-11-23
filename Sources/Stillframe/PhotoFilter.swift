import Foundation

enum CapturePeriod: String, CaseIterable, Codable { case any = "Any date", day = "One day", range = "Date range" }

struct PhotoFilter: Equatable {
    var folders: Set<String>? = nil
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
    var active: Bool { folders != nil || format != nil || usesMetadata || !filename.isEmpty }
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

    func filtered(_ photos: PhotoList, by filter: PhotoFilter, groups: SourceGroups) throws -> PhotoList {
        guard filter.active else { return photos }
        if filter.usesMetadata { loadDatesIfNeeded() }
        defer { saveDatesIfNeeded() }
        let interval = filter.captureInterval
        let matches = try photos.filter { photo in
            try Task.checkCancellation()
            if let folders = filter.folders, !folders.contains(groups.group(for: photo)) { return false }
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
        var folders = Set(groups.sources.map(\.location.path))
        var formats = Set<String>()
        for photo in photos {
            if Task.isCancelled { break }
            folders.insert(groups.group(for: photo))
            formats.insert(PhotoFilter.format(of: photo))
        }
        return (folders.sorted(), formats.sorted())
    }
}
