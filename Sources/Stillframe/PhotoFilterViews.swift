import SwiftUI

private struct FilterRequest: Equatable {
    let source: PhotoList
    let filter: PhotoFilter
}

struct FilteredPhotos<Content: View>: View {
    let source: PhotoList
    let filter: PhotoFilter
    @ViewBuilder let content: (PhotoList) -> Content
    @ViewState private var result: (FilterRequest, PhotoList)?
    private var request: FilterRequest { FilterRequest(source: source, filter: filter) }

    var body: some View {
        Group {
            if !filter.active { content(source) }
            else if let result, result.0 == request { content(result.1) }
            else { ProgressView("Filtering pictures…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: request) {
            let key = request
            guard key.filter.active else { result = nil; return }
            if let matches = try? await PhotoSorter.shared.filtered(key.source, by: key.filter),
               !Task.isCancelled { result = (key, matches) }
        }
    }
}

struct NoFilterMatches: View {
    @Binding var filter: PhotoFilter
    let all: PhotoList
    let groups: SourceGroups
    var body: some View {
        EmptyPanel(title: "No matching pictures", detail: "Change the filters to see more pictures.") {
            EmptyGlyph(symbol: "line.3.horizontal.decrease")
        } actions: {
            HStack {
                Button("Clear Filters") { filter = PhotoFilter() }.buttonStyle(ActionStyle(primary: true))
                StatisticsButton(label: "0 / " + String(all.count), all: all, visible: Self.empty, groups: groups)
            }
        }
    }
    private static let empty = PhotoList([])
}

struct StatisticsButton: View {
    let label: String
    let all: PhotoList
    let visible: PhotoList
    let groups: SourceGroups
    @ViewState private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4).frame(minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).fixedSize().help("Show picture counts and file sizes")
            .accessibilityLabel("Picture statistics, " + label)
            .anchorPreference(key: StatisticsAnchor.self, value: .bounds) { anchor in
                showing ? StatisticsAnchor.Presentation(anchor: anchor, all: all, visible: visible, groups: groups,
                                                 dismiss: { showing = false }) : nil
            }
    }
}

private enum StatisticsAnchor: PreferenceKey {
    struct Presentation {
        let anchor: Anchor<CGRect>
        let all: PhotoList
        let visible: PhotoList
        let groups: SourceGroups
        let dismiss: () -> Void
    }
    typealias Value = Presentation?
    static var defaultValue: Value { nil }
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value = nextValue() ?? value
    }
}

// Keep the tip on the counter even when the folder breakdown grows or the panel hits a window edge.
struct StatisticsOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(StatisticsAnchor.self) { presentation in
            if let presentation {
                GeometryReader { geometry in
                    let anchor = geometry[presentation.anchor]
                    let width: CGFloat = 240
                    let left = max(6, min(anchor.midX - width / 2, geometry.size.width - width - 6))
                    let above = anchor.minY > 250 || anchor.midY > geometry.size.height / 2
                    let edge = above ? anchor.minY : anchor.maxY
                    let height = above ? edge : geometry.size.height - edge
                    StatisticsPanel(all: presentation.all, visible: presentation.visible, groups: presentation.groups)
                        .padding(above ? .bottom : .top, 7)
                        .background(.regularMaterial, in: StatisticsBubble(tipX: anchor.midX - left, above: above))
                        .overlay(StatisticsBubble(tipX: anchor.midX - left, above: above).stroke(Palette.line, lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.24), radius: 6, y: 2)
                        .background(StatisticsDismissal(dismiss: presentation.dismiss))
                        .frame(width: width, height: max(0, height), alignment: above ? .bottom : .top)
                        .offset(x: left, y: above ? 0 : edge)
                }
            }
        }
    }
}

private struct StatisticsBubble: Shape {
    let tipX: CGFloat
    let above: Bool
    func path(in rect: CGRect) -> Path {
        // Draw clockwise with the pointer on the bottom edge. Flip for a panel below its counter.
        let bottom = rect.height - 7
        let radius: CGFloat = 10
        let tip = min(rect.width - radius - 7, max(radius + 7, tipX))
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: rect.width - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: radius), control: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: rect.width - radius, y: bottom), control: CGPoint(x: rect.width, y: bottom))
        path.addLine(to: CGPoint(x: tip + 7, y: bottom))
        path.addLine(to: CGPoint(x: tip, y: rect.height))
        path.addLine(to: CGPoint(x: tip - 7, y: bottom))
        path.addLine(to: CGPoint(x: radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: 0, y: bottom - radius), control: CGPoint(x: 0, y: bottom))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        return above ? path : path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height))
    }
}

private struct StatisticsDismissal: NSViewRepresentable {
    let dismiss: () -> Void
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.dismiss = dismiss }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(close), name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.close(); return nil }
                } else if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.close()
                    return nil
                }
                return event
            }
        }
        @objc private func close() { dismiss?() }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private struct StatisticsRequest: Equatable {
    let all: PhotoList
    let visible: PhotoList
    let groups: SourceGroups
}

private struct StatisticsPanel: View {
    let all: PhotoList
    let visible: PhotoList
    let groups: SourceGroups
    @ViewState private var stats: PictureStatistics?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Picture statistics").font(.system(size: 12, weight: .semibold))
            if let stats {
                row("Total", all.count, stats.bytes)
                row("Matching filters", visible.count, stats.visibleBytes)
                Divider()
                Text("Folders").fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(stats.folders.keys.sorted(), id: \.self) { path in
                            if let count = stats.folders[path] {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                        Text(path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }.help(path)
                                    Spacer()
                                    Text("\(count.visible) / \(count.total)").monospacedDigit()
                                }
                            }
                        }
                    }
                }.frame(height: min(132, CGFloat(stats.folders.count) * 30))
                if stats.unknownSizes > 0 { Text("Size unavailable for " + countText(stats.unknownSizes, "picture")).font(.caption) }
            } else { ProgressView().controlSize(.small) }
        }.font(.system(size: 11)).padding(12).frame(width: 240)
            .task(id: StatisticsRequest(all: all, visible: visible, groups: groups)) {
                stats = nil
                let next = try? await PictureStatistics.read(all: all, visible: visible, groups: groups)
                if !Task.isCancelled { stats = next }
            }
    }

    private func row(_ title: String, _ count: Int, _ bytes: Int64) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(count) · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).monospacedDigit()
        }
    }
}

struct FilterButton: View {
    let source: PhotoList
    let groups: SourceGroups
    @Binding var filter: PhotoFilter
    @ViewState private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HeaderActionLabel(title: "Filter", symbol: filter.active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .foregroundStyle(filter.active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }.buttonStyle(.plain).fixedSize().help("Filter pictures")
            .accessibilityValue(filter.active ? "Active" : "All pictures")
            .popover(isPresented: $showing) {
                FilterPanel(source: source, groups: groups, current: filter) { filter = $0; showing = false }
            }
    }
}

private struct FilterOptionsRequest: Equatable {
    let source: PhotoList
    let groups: SourceGroups
}

private struct FilterPanel: View {
    let source: PhotoList
    let groups: SourceGroups
    let apply: (PhotoFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: PhotoFilter
    @ViewState private var folders: [String] = []
    @ViewState private var formats: [String] = []
    @ViewState private var equipment: (source: PhotoList, cameras: [String], lenses: [String])?
    @ViewState private var showEquipment: Bool
    @ViewState private var choosingLocation = false

    init(source: PhotoList, groups: SourceGroups, current: PhotoFilter, apply: @escaping (PhotoFilter) -> Void) {
        self.source = source
        self.groups = groups
        self.apply = apply
        _draft = ViewState(initialValue: current)
        _showEquipment = ViewState(initialValue: current.camera != nil || current.lens != nil)
    }

    var body: some View {
        if choosingLocation {
            LocationFilterEditor(initial: draft.location, cancel: { choosingLocation = false }) { location in
                draft.location = location
                choosingLocation = false
            }
        } else { filterForm }
    }

    private var filterForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Filter pictures").font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Filename contains", text: $draft.filename).textFieldStyle(.roundedBorder)
                    options("Format", choices: formats, value: $draft.format)
                    Picker("Date taken", selection: $draft.period) {
                        ForEach(CapturePeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if draft.period != .any {
                        DatePicker(draft.period == .day ? "On" : "From", selection: $draft.start, displayedComponents: .date)
                        if draft.period == .range {
                            DatePicker("Through", selection: $draft.end, in: draft.start..., displayedComponents: .date)
                        }
                    }
                    Divider()
                    HStack(spacing: 6) {
                        Text("Location")
                        Spacer()
                        Button(draft.location?.label ?? "Choose area…") { choosingLocation = true }
                            .lineLimit(1).truncationMode(.middle)
                            .help(draft.location?.label ?? "Choose a center and radius")
                        if draft.location != nil {
                            Button { draft.location = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Clear location filter")
                        }
                    }
                    DisclosureGroup("Folders") {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("Select All") { draft.folders = FolderFilter() }
                                Button("Deselect All") { draft.folders = FolderFilter(includeByDefault: false) }
                            }.buttonStyle(.borderless)
                            ForEach(folders, id: \.self) { path in
                                let included = draft.folders.includes(path)
                                let mixed = draft.folders.hasExceptions(under: path)
                                Button { draft.folders.setIncluded(mixed || !included, at: path) } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: mixed ? "minus.square.fill" : (included ? "checkmark.square.fill" : "square"))
                                            .foregroundStyle(mixed || included ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                        Text(path).lineLimit(1).truncationMode(.middle)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help(path)
                                    .accessibilityValue(mixed ? "Partially selected" : (included ? "Selected" : "Unselected"))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }.disclosureGroupStyle(FullRowDisclosure())
                    DisclosureGroup("Camera and lens", isExpanded: $showEquipment) {
                        if let equipment, equipment.source === source {
                            VStack(spacing: 8) {
                                options("Camera", choices: equipment.cameras, value: $draft.camera)
                                options("Lens", choices: equipment.lenses, value: $draft.lens)
                            }.padding(.top, 5)
                        } else { HStack { ProgressView().controlSize(.small); Text("Reading image metadata…").font(.caption) } }
                    }.disclosureGroupStyle(FullRowDisclosure())
                }.padding(2).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 218)
            Divider()
            HStack {
                Button("Clear") { apply(PhotoFilter()) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { apply(draft) }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 12)).controlSize(.small)
            .padding(16).frame(width: 340)
            .environment(\.timeZone, .gmt)
            .onChange(of: draft.start) { _, value in if draft.end < value { draft.end = value } }
            .task(id: FilterOptionsRequest(source: source, groups: groups)) {
                let values = await PhotoSorter.shared.filterOptions(in: source, groups: groups)
                if !Task.isCancelled { folders = values.folders; formats = values.formats }
            }
            .task(id: showEquipment ? ObjectIdentifier(source) : nil) {
                guard showEquipment, equipment?.source !== source else { return }
                if let result = try? await PhotoSorter.shared.equipment(in: source), !Task.isCancelled {
                    equipment = (source, result.cameras, result.lenses)
                }
            }
    }

    private func options(_ label: String, choices: [String], value: Binding<String?>) -> some View {
        Picker(label, selection: value) {
            Text("Any").tag(String?.none)
            ForEach(Array(Set(choices + [value.wrappedValue].compactMap { $0 })).sorted(), id: \.self) {
                Text($0).tag(Optional($0))
            }
        }
    }
}

struct FullRowDisclosure: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer()
                }.padding(.vertical, 2).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
