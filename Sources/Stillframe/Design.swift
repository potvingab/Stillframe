import SwiftUI
import ImageIO

// Select the property wrapper explicitly so command-line builds need no SwiftUI macro plug-in.
typealias ViewState<Value> = SwiftUI.State<Value>

enum PhotoTypography {
    static let filename = Font.system(size: 17, weight: .medium, design: .serif)
    static let detail = Font.callout
}

enum Palette {
    static let paper = adaptive(0xF8F7F3, 0x20231F)
    static let surface = adaptive(0xFDFCF9, 0x2A2D28)
    static let mat = adaptive(0xEBECE4, 0x30362E)
    static let ink = adaptive(0x24332C, 0xF1F2E8)
    static let secondary = adaptive(0x626A60, 0xB2BAAC)
    static let line = adaptive(0xD9DBD2, 0x444B40)
    static let accent = adaptive(0x315B49, 0xABCAB2)
    static let onAccent = adaptive(0xFFFFFF, 0x182B20)
    static let tint = adaptive(0xE2EADB, 0x3C4F3F)

    private static func adaptive(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

private struct CollectionAccentKey: EnvironmentKey {
    static let defaultValue: CollectionColor? = nil
}
extension EnvironmentValues {
    var collectionAccent: CollectionColor? {
        get { self[CollectionAccentKey.self] }
        set { self[CollectionAccentKey.self] = newValue }
    }
}

struct ActionStyle: ButtonStyle {
    @Environment(\.collectionAccent) private var collectionAccent
    @Environment(\.isEnabled) private var enabled
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).frame(height: 33)
            .foregroundStyle(primary ? (collectionAccent?.checkmark ?? Palette.onAccent) : Palette.ink)
            .background(primary ? (collectionAccent?.tint ?? Palette.accent) : Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? .clear : Palette.line))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

func countText(_ count: Int, _ singular: String) -> String {
    "\(count.formatted()) \(singular)\(count == 1 ? "" : "s")"
}

struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 32, weight: .medium, design: .serif))
            .foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WelcomePhoto: View {
    private static let artwork: NSImage? = {
        let url = Bundle.main.url(forResource: "Welcome", withExtension: "jpg")
            ?? Bundle.module.url(forResource: "Welcome", withExtension: "jpg")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()

    var body: some View {
        if let image = Self.artwork {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Palette.mat.overlay(Image(systemName: "photo"))
        }
    }
}

struct WelcomePrint: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color(red: 0.71, green: 0.75, blue: 0.65))
                .padding(7).background(.white)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .rotationEffect(.degrees(-11)).offset(x: -13, y: -3)
            WelcomePhoto().frame(width: 258, height: 157).clipped()
                .padding(7).padding(.bottom, 5).background(.white)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
                .rotationEffect(.degrees(5)).offset(x: 9, y: 3)
        }.frame(width: 272, height: 176)
            .padding(.vertical, 19).accessibilityHidden(true)
    }
}

struct EmptyPanel<Art: View, Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let art: () -> Art
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            art().padding(.bottom, 19)
            Text(title).font(.system(size: 28, weight: .medium, design: .serif))
                .foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center).padding(.top, 8)
            actions().padding(.top, 18)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.mat, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line.opacity(0.8)))
    }
}

struct EmptyGlyph: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
            .frame(width: 86, height: 80).accessibilityHidden(true)
    }
}

// Separate queues let the main preview decode while the filmstrip is filling in.
actor ImageDecoder {
    static let previews = ImageDecoder(budget: 160 * 1024 * 1024)
    static let thumbnails = ImageDecoder(budget: 48 * 1024 * 1024)
    // NSCache supports concurrent lookups. A cache hit during rendering never touches the filesystem.
    private final class MemoryCache: @unchecked Sendable {
        let images = NSCache<NSString, CGImage>()
        init(budget: Int) { images.totalCostLimit = budget }
    }
    private let cache: MemoryCache

    init(budget: Int) { cache = MemoryCache(budget: budget) }

    private nonisolated func key(_ url: URL, _ pixels: Int, _ modified: Date?) -> NSString {
        "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(pixels)" as NSString
    }

    nonisolated func cached(_ url: URL, pixels: Int, modified: Date?) -> CGImage? {
        guard let modified else { return nil }
        return cache.images.object(forKey: key(url, pixels, modified))
    }

    func decode(_ url: URL, pixels: Int, modified: Date?) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let version = modified ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = key(url, pixels, version)
        if let cached = cache.images.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            (pixels <= 256 && self === Self.thumbnails ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways): true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary) else { return nil }
        cache.images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

struct FileImage: View {
    private struct Request: Equatable {
        let url: URL
        let modified: Date?
        let pixels: Int
    }
    let url: URL
    var modified: Date? = nil
    var fit = false
    @Environment(\.displayScale) private var scale
    @ViewState private var result: CGImage?
    @ViewState private var loadedURL: URL?
    @ViewState private var loadedVersion: Date?
    @ViewState private var failed = false
    @ViewState private var detail: (url: URL, factor: CGFloat)?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let detailScale = detail.flatMap { $0.url == url ? $0.factor : nil } ?? 1
            let basePixels = max(size.width, size.height) * scale
            let requestedPixels = min(basePixels * detailScale, max(8192, basePixels))
            let pixels = max(128, Int(ceil(requestedPixels / 128)) * 128)
            let current = loadedURL == url && loadedVersion == modified
            let decoder = fit ? ImageDecoder.previews : ImageDecoder.thumbnails
            let thumbPixels = max(128, Int(ceil(78 * scale / 128)) * 128)
            let cached = decoder.cached(url, pixels: pixels, modified: modified)
            let image = cached ?? (current ? result : nil)
                ?? (fit ? ImageDecoder.thumbnails.cached(url, pixels: thumbPixels, modified: modified) : nil)
            ZStack {
                if fit {
                    PhotoMagnifier(image: image, url: url) { factor in
                        detail = factor > 1 ? (url, factor) : nil
                    }
                } else if let image {
                    Image(decorative: image, scale: scale).resizable().interpolation(.high)
                        .scaledToFill()
                }
                if image == nil {
                    if current, failed {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.exclamationmark")
                            if fit { Text("Preview unavailable").font(.callout) }
                        }.foregroundStyle(fit ? .white.opacity(0.75) : Palette.secondary)
                    } else if fit {
                        ProgressView().controlSize(.small).environment(\.colorScheme, .dark)
                    }
                }
            }.frame(width: max(0, size.width), height: max(0, size.height)).clipped()
                .task(id: Request(url: url, modified: modified, pixels: pixels)) {
                    // Keep the current preview sharp enough to navigate while resize or pinch events arrive.
                    if cached == nil && fit && current && result != nil {
                        try? await Task.sleep(for: .milliseconds(detailScale > 1 ? 140 : 60))
                        guard !Task.isCancelled else { return }
                    }
                    let decoded: CGImage?
                    if let cached { decoded = cached }
                    else { decoded = await decoder.decode(url, pixels: pixels, modified: modified) }
                    guard !Task.isCancelled else { return }
                    if decoded == nil && current && result != nil { return }
                    loadedURL = url
                    loadedVersion = modified
                    result = decoded
                    failed = decoded == nil
                }
        }.accessibilityHidden(!fit)
            .onChange(of: url) { _, _ in if detail != nil { detail = nil } }
    }
}
