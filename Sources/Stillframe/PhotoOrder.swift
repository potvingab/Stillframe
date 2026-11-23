import Foundation
import ImageIO

enum PhotoSortKey: String, Codable, CaseIterable {
    case filename, taken, modified, added

    var title: String {
        switch self {
        case .filename: return "Filename"
        case .taken: return "Date taken"
        case .modified: return "Date modified"
        case .added: return "Date added to collection"
        }
    }
}

struct PhotoOrder: Codable, Hashable {
    var key: PhotoSortKey
    var descending: Bool
    var groupByFolder: Bool

    static let pictures = Self(key: .filename, descending: false, groupByFolder: true)
    static let collection = Self(key: .added, descending: false, groupByFolder: false)

    private struct Entry {
        let photo: Photo
        let name: String
        let folder: String
        let folderName: String
        let date: Date?
        let additionIndex: Int
    }

    // The source of a collection is always in mark order. Only the displayed list is sorted.
    func arrange(_ photos: [Photo], date: (Photo) -> Date? = { _ in nil }) throws -> [Photo] {
        if key == .added && !groupByFolder { return descending ? photos.reversed() : photos }
        var entries = [Entry]()
        entries.reserveCapacity(photos.count)
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            let folder = photo.url.deletingLastPathComponent()
            entries.append(Entry(photo: photo, name: photo.url.lastPathComponent,
                                 folder: groupByFolder ? folder.path : "",
                                 folderName: groupByFolder ? folder.lastPathComponent : "",
                                 date: date(photo), additionIndex: index))
        }
        try entries.sort { lhs, rhs in
            try Task.checkCancellation()
            if lhs.folder != rhs.folder {
                let byName = lhs.folderName.localizedStandardCompare(rhs.folderName)
                if byName != .orderedSame { return byName == .orderedAscending }
                return Self.pathPrecedes(lhs.folder, rhs.folder)
            }
            switch key {
            case .added:
                return descending ? lhs.additionIndex > rhs.additionIndex : lhs.additionIndex < rhs.additionIndex
            case .taken, .modified:
                if lhs.date != rhs.date {
                    guard let left = lhs.date else { return false }
                    guard let right = rhs.date else { return true }
                    return descending ? left > right : left < right
                }
            case .filename:
                break
            }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame {
                return byName == (key == .filename && descending ? .orderedDescending : .orderedAscending)
            }
            return Self.pathPrecedes(lhs.photo.id, rhs.photo.id)
        }
        return entries.map(\.photo)
    }

    private static func pathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.localizedStandardCompare(rhs)
        return result == .orderedSame ? lhs < rhs : result == .orderedAscending
    }
}

// Date and equipment queries share a header-only index, validated by original modification time.
actor PhotoSorter {
    static let shared = PhotoSorter(cacheURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Stillframe/image-facts-v2.json"))

    struct ImageFacts: Codable {
        let modified: Date?
        let taken: Date?
        let camera: String?
        let lens: String?
    }

    private let cacheURL: URL?
    private var dates: [String: ImageFacts] = [:]
    private var loaded = false
    private var dirty = false

    init(cacheURL: URL?) { self.cacheURL = cacheURL }

    func sorted(_ source: PhotoList, by order: PhotoOrder) throws -> PhotoList {
        try Task.checkCancellation()
        if order.key == .taken { loadDatesIfNeeded() }
        defer { saveDatesIfNeeded() }
        let sorted = try order.arrange(source.items) { photo in
            switch order.key {
            case .taken: return facts(of: photo)?.taken
            case .modified: return modificationDate(of: photo)
            default: return nil
            }
        }
        return PhotoList(sorted)
    }

    private func modificationDate(of photo: Photo) -> Date? {
        if let modified = photo.modified { return modified }
        // Collection-only originals do not receive fresh URLs from the folder scan.
        var url = photo.url
        url.removeCachedResourceValue(forKey: .contentModificationDateKey)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func loadDatesIfNeeded() {
        guard !loaded else { return }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: ImageFacts].self, from: data) { dates = saved }
        loaded = true
    }

    func facts(of photo: Photo) -> ImageFacts? {
        let modified = modificationDate(of: photo)
        if let cached = dates[photo.id], cached.modified == modified { return cached }
        return autoreleasepool {
            guard let image = CGImageSourceCreateWithURL(photo.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(image) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, CGImageSourceGetPrimaryImageIndex(image), nil)
                    as? [String: Any] else { return nil }
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            var taken = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap(PhotoMetadata.parseCaptureTime)
            if let base = taken, let fraction = exif?[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
               fraction.allSatisfy(\.isNumber), let seconds = Double("0." + fraction) {
                taken = base.addingTimeInterval(seconds)
            }
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
            let info = ImageFacts(modified: modified, taken: taken, camera: tiff?["Model"] as? String,
                                  lens: (exif?["LensModel"] as? String) ?? (aux?["LensModel"] as? String))
            if modified != nil {
                dates[photo.id] = info
                dirty = true
            }
            return info
        }
    }

    func saveDatesIfNeeded() {
        guard dirty, let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(dates).write(to: cacheURL, options: .atomic)
            dirty = false
        } catch {
            // A read-only cache still permits sorting and reuse for this session.
        }
    }
}
