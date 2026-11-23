import SwiftUI

private extension Color.Resolved {
    var luminance: Float { 0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue }
}

extension CollectionColor {
    private var swatch: (name: String, color: Color) {
        switch self {
        case .sage:  return ("Avocado", Color(red: 0.53, green: 0.57, blue: 0.31))
        case .sky:   return ("Faded denim", Color(red: 0.40, green: 0.53, blue: 0.62))
        case .coral: return ("Burnt orange", Color(red: 0.78, green: 0.40, blue: 0.22))
        case .violet: return ("Aubergine", Color(red: 0.45, green: 0.31, blue: 0.42))
        case .amber: return ("Harvest gold", Color(red: 0.84, green: 0.65, blue: 0.23))
        case .teal:  return ("Petrol", Color(red: 0.22, green: 0.44, blue: 0.43))
        case .rose:  return ("Dusty rose", Color(red: 0.77, green: 0.51, blue: 0.52))
        case .slate: return ("Walnut", Color(red: 0.49, green: 0.36, blue: 0.25))
        default:
            let rgb = customRGB ?? 0
            let red = Double((rgb >> 16) & 255) / 255
            let green = Double((rgb >> 8) & 255) / 255
            let blue = Double(rgb & 255) / 255
            return ("Custom color", Color(.sRGB, red: red, green: green, blue: blue))
        }
    }

    init?(pickerColor: Color) {
        guard let rgb = NSColor(pickerColor).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        self.init(red: channel(rgb.redComponent), green: channel(rgb.greenComponent), blue: channel(rgb.blueComponent))
    }

    var name: String { swatch.name }
    var tint: Color { swatch.color }
    var checkmark: Color { tint.resolve(in: EnvironmentValues()).luminance > 0.179 ? .black : .white }

    // Swatches keep their exact color. Controls need enough contrast against both the paper and the photo mat.
    func controlTint(in scheme: ColorScheme) -> Color {
        let color = tint
        let rgb = color.resolve(in: EnvironmentValues())
        let luminance = rgb.luminance
        let target: Float = scheme == .dark ? max(luminance, 0.36) : min(luminance, 0.14)
        guard target != luminance else { return color }
        let endpoint: Float = scheme == .dark ? 1 : 0
        let fraction = (target - luminance) / (endpoint - luminance)
        func channel(_ value: Float) -> Double { Double(value + (endpoint - value) * fraction) }
        return Color(.sRGBLinear, red: channel(rgb.linearRed), green: channel(rgb.linearGreen), blue: channel(rgb.linearBlue))
    }

    var dot: some View {
        Circle().fill(tint).frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct ShortcutKey: View {
    let letter: String
    var body: some View {
        Text(letter.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.secondary).padding(.horizontal, 5).frame(minWidth: 19, minHeight: 17)
            .background(Palette.mat, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Shortcut " + letter.uppercased())
    }
}

@MainActor
final class CollectionColorPanel: NSObject, ObservableObject {
    private var apply: ((CollectionColor) -> Void)?

    func open(_ current: CollectionColor, apply: @escaping (CollectionColor) -> Void) {
        let panel = NSColorPanel.shared
        self.apply = nil
        panel.showsAlpha = false
        panel.color = NSColor(current.tint)
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.apply = apply
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        if let color = CollectionColor(pickerColor: Color(nsColor: panel.color)) { apply?(color) }
    }

    func close() {
        guard apply != nil else { return }
        apply = nil
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
    }
}

struct CollectionEditor: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    let collection: PhotoCollection?
    let merging: Set<UUID>
    let photo: URL?
    let onSave: (UUID) -> Void
    @StateObject private var customPicker = CollectionColorPanel()
    @ViewState private var name: String
    @ViewState private var color: CollectionColor
    @ViewState private var shortcut: String

    init(collection: PhotoCollection? = nil, initialColor: CollectionColor, photo: URL? = nil, merging: Set<UUID> = [], onSave: @escaping (UUID) -> Void = { _ in }) {
        self.collection = collection
        self.merging = merging
        self.photo = photo
        self.onSave = onSave
        _name = ViewState(initialValue: collection?.name ?? "")
        _color = ViewState(initialValue: collection?.color ?? initialColor)
        _shortcut = ViewState(initialValue: collection?.shortcut?.uppercased() ?? "")
    }

    var body: some View {
        let issue = library.shortcutIssue(shortcut, excluding: collection.map { [$0.id] } ?? merging)
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: !merging.isEmpty ? "Merge collections" : (collection == nil ? "New collection" : "Edit collection"))
            if !merging.isEmpty {
                Text("Replace these \(merging.count) collections with one collection. Shared pictures appear once.")
                    .font(.callout).foregroundStyle(Palette.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.headline)
                TextField("Collection name", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Color").font(.headline)
                HStack(spacing: 9) {
                    ForEach(CollectionColor.presets, id: \.self) { choice in
                        Button { customPicker.close(); color = choice } label: {
                            Circle().fill(choice.tint).frame(width: 24, height: 24)
                                .overlay {
                                    if choice == color {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(choice.checkmark)
                                    }
                                }.padding(2)
                                .overlay(Circle().strokeBorder(choice == color ? Palette.ink : .clear, lineWidth: 1.5))
                        }.buttonStyle(.plain)
                            .accessibilityLabel(choice.name)
                            .accessibilityAddTraits(color == choice ? .isSelected : [])
                    }
                    Button {
                        customPicker.open(color) { color = $0 }
                    } label: {
                        Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                            .frame(width: 24, height: 24)
                            .overlay {
                                if color.customRGB != nil {
                                    Circle().fill(color.tint).frame(width: 16, height: 16)
                                        .overlay(Circle().stroke(.white, lineWidth: 1))
                                }
                            }.padding(2)
                            .overlay(Circle().strokeBorder(color.customRGB == nil ? .clear : Palette.ink, lineWidth: 1.5))
                            .contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Custom color")
                        .accessibilityAddTraits(color.customRGB == nil ? [] : .isSelected)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Shortcut letter").font(.headline)
                    Spacer()
                    TextField("None", text: $shortcut).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center).frame(width: 58).accessibilityLabel("Shortcut letter")
                }
                Text(issue ?? "Press the letter in a carousel to add or remove the current photo.")
                    .foregroundStyle(issue == nil ? Palette.secondary : Color.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button(!merging.isEmpty ? "Merge" : (collection != nil ? "Save" : (photo == nil ? "Create" : "Create and Add"))) { save() }
                    .buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || issue != nil)
            }
        }.padding(24).frame(width: 380).foregroundStyle(Palette.ink).background(Palette.paper).tint(Palette.accent)
            .environment(\.collectionAccent, nil)
            .onDisappear { customPicker.close() }
    }

    private func save() {
        let id: UUID
        if !merging.isEmpty {
            guard let merged = library.mergeCollections(merging, name: name, color: color, shortcut: shortcut) else { return }
            id = merged
        } else if let collection {
            guard library.editCollection(collection.id, name: name, color: color, shortcut: shortcut) else { return }
            id = collection.id
        } else {
            guard let created = library.newCollection(name, color: color, shortcut: shortcut, including: photo) else { return }
            id = created
        }
        onSave(id)
        dismiss()
    }
}
