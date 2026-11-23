import SwiftUI

struct PhotoMagnifier: View {
    let image: CGImage?
    let url: URL
    let onDetailScale: (CGFloat) -> Void
    @StateObject private var zoom = PhotoZoom()

    var body: some View {
        MagnifiedPhoto(image: image, url: url, zoom: zoom, onDetailScale: onDetailScale)
            .toolbar {
                ToolbarItem(id: "viewer-zoom", placement: .navigation) {
                    HStack(spacing: 0) {
                        button("Zoom out", symbol: "minus.magnifyingglass", enabled: zoom.canZoomOut, inward: false)
                        Divider().frame(height: 13).accessibilityHidden(true)
                        button("Zoom in", symbol: "plus.magnifyingglass", enabled: zoom.canZoomIn, inward: true)
                    }.fixedSize().modifier(HeaderCapsule())
                        .accessibilityElement(children: .contain)
                }.withoutSharedGlass()
            }
    }

    private func button(_ title: String, symbol: String, enabled: Bool, inward: Bool) -> some View {
        Button { zoom.canvas?.stepZoom(inward: inward) } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(image == nil || !enabled).help(title)
    }
}

@MainActor
final class PhotoZoom: ObservableObject {
    weak var canvas: PhotoCanvas?
    @Published private(set) var canZoomOut = false
    @Published private(set) var canZoomIn = true

    func update(from scroll: NSScrollView) {
        let out = scroll.magnification > scroll.minMagnification + 0.001
        let inward = scroll.magnification < scroll.maxMagnification - 0.001
        if canZoomOut != out { canZoomOut = out }
        if canZoomIn != inward { canZoomIn = inward }
    }
}

private struct MagnifiedPhoto: NSViewRepresentable {
    let image: CGImage?
    let url: URL
    let zoom: PhotoZoom
    let onDetailScale: (CGFloat) -> Void

    func makeNSView(context: Context) -> PhotoCanvas {
        let canvas = PhotoCanvas()
        canvas.zoom = zoom
        zoom.canvas = canvas
        return canvas
    }

    func updateNSView(_ view: PhotoCanvas, context: Context) {
        view.onDetailScale = onDetailScale
        view.show(image, at: url)
    }
}

// Center each axis independently. A portrait can stay centered horizontally while panning vertically.
private final class CenteredPhotoClip: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposed)
        guard let documentView else { return result }
        let frame = documentView.frame
        if frame.width < result.width { result.origin.x = frame.midX - result.width / 2 }
        if frame.height < result.height { result.origin.y = frame.midY - result.height / 2 }
        return result
    }
}

final class PhotoCanvas: NSView {
    weak var zoom: PhotoZoom?
    var onDetailScale: ((CGFloat) -> Void)?
    let scroll = NSScrollView()
    let resetButton = NSButton(title: "Reset zoom", target: nil, action: nil)
    private let resetPlate: NSView
    private let picture = NSImageView()
    private var bitmap: CGImage?
    private var location: URL?
    private var changingPhoto = false
    private var lastDetailScale: CGFloat = 1

    init() {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = .black.withAlphaComponent(0.62)
            glass.cornerRadius = 16
            resetPlate = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 16
            material.layer?.masksToBounds = true
            resetPlate = material
        }
        super.init(frame: .zero)
        scroll.contentView = CenteredPhotoClip()
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 8
        scroll.usesPredominantAxisScrolling = false
        picture.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = picture
        addSubview(scroll)

        resetButton.target = self
        resetButton.action = #selector(resetZoom)
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        resetButton.imagePosition = .imageLeading
        resetButton.isBordered = false
        resetButton.imageHugsTitle = true
        resetButton.contentTintColor = .white
        resetButton.font = .systemFont(ofSize: 12, weight: .semibold)
        resetButton.appearance = NSAppearance(named: .darkAqua)
        resetPlate.appearance = NSAppearance(named: .darkAqua)
        resetButton.isHidden = true
        resetPlate.isHidden = true
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetPlate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resetPlate)
        addSubview(resetButton)
        NSLayoutConstraint.activate([
            resetButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            resetButton.widthAnchor.constraint(equalToConstant: 112),
            resetButton.heightAnchor.constraint(equalToConstant: 32),
            resetPlate.leadingAnchor.constraint(equalTo: resetButton.leadingAnchor),
            resetPlate.trailingAnchor.constraint(equalTo: resetButton.trailingAnchor),
            resetPlate.topAnchor.constraint(equalTo: resetButton.topAnchor),
            resetPlate.bottomAnchor.constraint(equalTo: resetButton.bottomAnchor)
        ])

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(reportScale),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage?, at url: URL) {
        let newPhoto = location != url
        guard newPhoto || bitmap !== image else { return }
        changingPhoto = newPhoto
        defer { changingPhoto = false }
        if newPhoto {
            location = url
            lastDetailScale = 1
            resetButton.isHidden = true
            resetPlate.isHidden = true
            if scroll.magnification != 1 {
                resetZoom()
                // SwiftUI is updating this view. Publish the toolbar state on the next run loop.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.zoom?.update(from: self.scroll)
                }
            }
            picture.setAccessibilityLabel(url.lastPathComponent)
        }
        bitmap = image
        picture.image = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        scroll.isHidden = image == nil
        fitDocument()
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        scroll.layoutSubtreeIfNeeded()
        fitDocument()
    }

    private func fitDocument() {
        guard let bitmap else { return }
        let viewport = scroll.contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let width = CGFloat(bitmap.width), height = CGFloat(bitmap.height)
        let fit = min(viewport.width / width, viewport.height / height)
        let size = NSSize(width: width * fit, height: height * fit)
        guard picture.frame.size != size else { return }
        picture.setFrameSize(size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(scroll.contentView.bounds).origin)
    }

    func stepZoom(inward: Bool) {
        let scale = scroll.magnification
        let stops: [CGFloat] = [1, 1.5, 2, 3, 4, 6, 8]
        let next = inward ? stops.first { $0 > scale + 0.001 } : stops.last { $0 < scale - 0.001 }
        guard let next else { return }
        let visible = scroll.contentView.documentVisibleRect
        scroll.setMagnification(next, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        reportScale()
    }

    @objc private func resetZoom() {
        scroll.magnification = 1
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(scroll.contentView.bounds).origin)
    }

    @objc private func reportScale() {
        // AppKit handles continuous pinching and panning. Only request new pixels in half-scale steps.
        guard !changingPhoto else { return }
        let scale = min(scroll.maxMagnification, scroll.magnification)
        zoom?.update(from: scroll)
        let detailScale = scale > 1.001 ? ceil(scale * 2) / 2 : 1
        guard detailScale != lastDetailScale else { return }
        lastDetailScale = detailScale
        resetButton.isHidden = detailScale == 1
        resetPlate.isHidden = resetButton.isHidden
        onDetailScale?(detailScale)
    }
}
