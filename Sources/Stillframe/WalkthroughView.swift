import SwiftUI

struct WalkthroughView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var step = Step.folders
    @AccessibilityFocusState private var headingFocused: Bool

    private enum Step: Int, CaseIterable {
        case folders, pictures, collections

        var title: String {
            switch self {
            case .folders: return "Choose your folders"
            case .pictures: return "Browse your pictures"
            case .collections: return "Keep your favorites together"
            }
        }

        var detail: String {
            switch self {
            case .folders: return "Add one or more folders from your Mac. Pictures includes their subfolders by default. For separate folder lists, you can use workspaces."
            case .pictures: return "Use the arrow keys or click a thumbnail to move through Pictures. Pinch to zoom in, or open the info sidebar to see the camera settings."
            case .collections: return "Choose Add to Collection under a picture to mark it. Open Collections to see your picks together, even when they come from different folders."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Stillframe walkthrough").font(.headline)
                Spacer()
                Text("\(step.rawValue + 1) of \(Step.allCases.count)").monospacedDigit()
            }.font(.callout).foregroundStyle(Palette.secondary)
            ZStack {
                Palette.mat
                illustration
            }.frame(height: 134)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line).allowsHitTesting(false))
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.system(size: 27, weight: .medium, design: .serif))
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                Text(step.detail).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            Divider()
            HStack(spacing: 8) {
                if step == .collections {
                    Text("Reopen this walkthrough from Help.").font(.caption).foregroundStyle(Palette.secondary)
                } else {
                    Button("Skip Walkthrough") { dismiss() }.buttonStyle(.link).keyboardShortcut(.cancelAction)
                }
                Spacer()
                if step != .folders {
                    Button("Back") { move(-1) }.buttonStyle(ActionStyle())
                }
                Button(step == .collections ? "Done" : "Next") {
                    if step == .collections { dismiss() } else { move(1) }
                }.buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 478).foregroundStyle(Palette.ink).background(Palette.paper).tint(Palette.accent)
            .onExitCommand { dismiss() }
    }

    @ViewBuilder private var illustration: some View {
        switch step {
        case .folders:
            HStack(spacing: 20) {
                WelcomePrint().scaleEffect(0.56).frame(width: 169, height: 118)
                VStack(spacing: 6) {
                    Button {
                        if library.chooseFolders() { move(1) }
                    } label: { Label("Add Folders…", systemImage: "folder.badge.plus") }
                    .buttonStyle(ActionStyle())
                    if !library.state.folders.isEmpty {
                        Text(countText(library.state.folders.count, "folder") + " selected")
                            .font(.caption).foregroundStyle(Palette.secondary)
                    }
                }
            }
        case .pictures:
            HStack(spacing: 18) {
                key("arrow.left")
                printPhoto
                key("arrow.right")
            }.accessibilityHidden(true)
        case .collections:
            printPhoto
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "bookmark.fill").font(.system(size: 29, weight: .medium))
                        .foregroundStyle(Palette.accent).shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .padding(.trailing, 8)
                }
                .rotationEffect(.degrees(-4)).accessibilityHidden(true)
        }
    }

    private var printPhoto: some View {
        WelcomePhoto().frame(width: 147, height: 91).clipped().padding(5).padding(.bottom, 3)
            .background(.white).shadow(color: .black.opacity(0.17), radius: 3, y: 2)
    }

    private func key(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 25).background(Palette.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line))
    }

    private func move(_ direction: Int) {
        guard let next = Step(rawValue: step.rawValue + direction) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { step = next }
        headingFocused = true
    }
}
