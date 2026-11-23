import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct MetadataField: Identifiable {
    let label: String
    let value: String
    var id: String { label }
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

struct MetadataGroup: Identifiable {
    let name: String
    let fields: [MetadataField]
    var id: String { name }
}

struct PhotoMetadata {
    var summary: [MetadataField] = []
    var capture: [MetadataField] = []
    var groups: [MetadataGroup] = []
    var readable = false

    static func read(_ url: URL) -> Self {
        var result = Self()
        let file = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        if let size = file?.fileSize {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.includesActualByteCount = true
            result.summary.append(.init("File size", formatter.string(fromByteCount: Int64(size))))
        }
        if let date = file?.creationDate { result.summary.append(.init("Created", date.formatted(date: .abbreviated, time: .shortened))) }
        if let date = file?.contentModificationDate { result.summary.append(.init("Modified", date.formatted(date: .abbreviated, time: .shortened))) }

        guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return result }
        result.readable = true
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        if let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) {
            result.summary.insert(.init("Format", type.localizedDescription ?? type.identifier), at: 0)
        }
        if let w = properties[kCGImagePropertyPixelWidth as String] as? Int, let h = properties[kCGImagePropertyPixelHeight as String] as? Int {
            let rotated = (5...8).contains(properties[kCGImagePropertyOrientation as String] as? Int ?? 1)
            result.summary.insert(.init("Dimensions", "\(rotated ? h : w) × \(rotated ? w : h) px"), at: 0)
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let auxiliary = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        if let model = tiff["Model"] as? String { result.capture.append(.init("Camera", model)) }
        if let lens = (exif["LensModel"] as? String) ?? (auxiliary?["LensModel"] as? String) {
            result.capture.append(.init("Lens", lens))
        }
        if let taken = exif["DateTimeOriginal"] as? String {
            result.capture.append(.init("Taken", captureTime(taken)))
        }
        let measurement = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0...2))
        if let f = exif["FNumber"] as? NSNumber { result.capture.append(.init("Aperture", "ƒ/\(f.doubleValue.formatted(measurement))")) }
        if let seconds = exif["ExposureTime"] as? Double, seconds > 0, seconds.isFinite {
            let denominator = (1 / seconds).rounded()
            let exposure = seconds < 1 && abs(denominator * seconds - 1) < 0.001
                ? "1/\(denominator.formatted(.number.grouping(.never)))"
                : seconds.formatted(.number.precision(.significantDigits(1...6)))
            result.capture.append(.init("Exposure", exposure + " s"))
        }
        if let iso = exif["ISOSpeedRatings"] as? [NSNumber] { result.capture.append(.init("ISO", iso.map(\.stringValue).joined(separator: ", "))) }
        if let length = exif["FocalLength"] as? NSNumber { result.capture.append(.init("Focal length", length.doubleValue.formatted(measurement) + " mm")) }

        var imageFields: [MetadataField] = []
        for key in properties.keys.sorted() {
            guard let value = properties[key] else { continue }
            if let dictionary = value as? [String: Any] {
                let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                result.groups.append(MetadataGroup(name: name, fields: flatten(dictionary)))
            } else {
                imageFields.append(.init(key, formatted(value)))
            }
        }
        if !imageFields.isEmpty { result.groups.insert(.init(name: "Image properties", fields: imageFields), at: 0) }
        if let container = CGImageSourceCopyProperties(source, nil) as? [String: Any], !container.isEmpty {
            result.groups.append(.init(name: "Container", fields: flatten(container)))
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) {
            var tags: [MetadataField] = []
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                if CGImageMetadataTagGetType(tag) == .string, let value = CGImageMetadataTagCopyValue(tag) {
                    tags.append(.init(path as String, formatted(value)))
                }
                return !Task.isCancelled
            }
            if !tags.isEmpty { result.groups.append(.init(name: "XMP tags", fields: tags.sorted { $0.label < $1.label })) }
        }
        return result
    }

    private static let captureParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .gmt
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return parser
    }()

    static func parseCaptureTime(_ value: String) -> Date? { captureParser.date(from: value) }

    private static func captureTime(_ value: String) -> String {
        // Match the camera's recorded wall time in the inspector and sort order.
        guard let date = parseCaptureTime(value) else { return value }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: .gmt))
    }

    private static func flatten(_ dictionary: [String: Any], prefix: String = "") -> [MetadataField] {
        dictionary.keys.sorted().flatMap { key -> [MetadataField] in
            guard let value = dictionary[key] else { return [] }
            let label = prefix + key
            if let nested = value as? [String: Any] { return flatten(nested, prefix: label + " / ") }
            return [.init(label, formatted(value))]
        }
    }

    private static func formatted(_ value: Any) -> String {
        if let data = value as? Data { return "\(data.count.formatted()) bytes of binary data" }
        if let array = value as? [Any] { return array.map(formatted).joined(separator: ", ") }
        if let dict = value as? [String: Any] { return flatten(dict).map { "\($0.label) = \($0.value)" }.joined(separator: "\n") }
        return String(describing: value)
    }
}

struct PhotoInspector: View {
    let photo: Photo
    let active: Bool
    @ViewState private var loadedPhoto: Photo?
    @ViewState private var metadata: PhotoMetadata?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(photo.url.lastPathComponent).font(PhotoTypography.filename)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 8) {
                    field("Folder", photo.url.deletingLastPathComponent().lastPathComponent)
                    field("Full path", photo.url.path, reveal: photo.url)
                }
                Divider()
                if loadedPhoto == photo, let metadata {
                    rows(metadata.summary)
                    if !metadata.capture.isEmpty {
                        Divider()
                        Text("Capture").font(.headline)
                        rows(metadata.capture)
                    }
                    if !metadata.groups.isEmpty {
                        Divider()
                        Text("Embedded metadata").font(.headline)
                        ForEach(metadata.groups) { group in
                            DisclosureGroup(group.name) {
                                rows(group.fields).padding(.top, 6)
                            }.disclosureGroupStyle(FullRowDisclosure()).font(.callout)
                        }
                    }
                    if !metadata.readable { Text("Image metadata unavailable").font(.caption).foregroundStyle(Palette.secondary) }
                } else { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
        }.background(Palette.surface)
            .task(id: active ? photo : nil) {
                guard active, loadedPhoto != photo else { return }
                // Rapid key repeats should not launch a metadata read for every passing photo.
                try? await Task.sleep(for: .milliseconds(85))
                guard !Task.isCancelled else { return }
                let task = Task.detached(priority: .userInitiated) { PhotoMetadata.read(photo.url) }
                let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
                if !Task.isCancelled { loadedPhoto = photo; metadata = result }
            }
    }

    private func rows(_ fields: [MetadataField]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(fields) { item in
                field(item.label, item.value)
            }
        }
    }

    private func field(_ label: String, _ value: String, reveal: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).fixedSize(horizontal: false, vertical: true)
                if let reveal {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([reveal]) } label: {
                        Image(systemName: "magnifyingglass").font(.caption.weight(.medium))
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Show in Finder").accessibilityLabel("Show in Finder")
                }
            }.foregroundStyle(Palette.secondary).frame(width: 74, alignment: .leading)
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(PhotoTypography.detail)
    }
}
