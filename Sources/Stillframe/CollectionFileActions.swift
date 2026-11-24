import Combine
import SwiftUI

enum CollectionFileActions {
    struct CopyResult {
        var copied = 0
        var failures: [String] = []

        var message: String {
            let summary = "Copied " + countText(copied, "picture") + "."
            guard !failures.isEmpty else { return summary }
            return summary + " " + countText(failures.count, "file") + " could not be copied.\n\n" + failures.prefix(3).joined(separator: "\n")
        }
    }

    static func copy(_ originals: [URL], to folder: URL) throws -> CopyResult {
        let fm = FileManager.default
        let staging = folder.appendingPathComponent(".stillframe-copy-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var result = CopyResult()
        for original in originals {
            let staged = staging.appendingPathComponent(UUID().uuidString)
            do {
                guard try original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                try fm.copyItem(at: original, to: staged)
                var name = original.lastPathComponent
                var suffix = 2
                while true {
                    do {
                        try fm.moveItem(at: staged, to: folder.appendingPathComponent(name))
                        break
                    } catch let error as CocoaError where error.code == .fileWriteFileExists {
                        name = original.deletingPathExtension().lastPathComponent + " " + String(suffix)
                        if !original.pathExtension.isEmpty { name += "." + original.pathExtension }
                        suffix += 1
                    }
                }
                result.copied += 1
            } catch {
                result.failures.append(original.lastPathComponent + " — " + error.localizedDescription)
            }
        }
        return result
    }
}

extension Library {
    func readableFiles(_ urls: [URL]) -> [URL] {
        if let missing = urls.first(where: { !FileManager.default.isReadableFile(atPath: $0.path) }) {
            message = "“\(missing.lastPathComponent)” is unavailable. Check its original folder."
            return []
        }
        return urls
    }

    func emailPictures(_ urls: [URL]) {
        let files = readableFiles(urls)
        guard !files.isEmpty else { return }
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: files) else {
            message = "Mail composition is unavailable. Check your default email app."
            return
        }
        service.perform(withItems: files)
    }

    func copyPictures(_ urls: [URL], didCopy: ((String) -> Void)? = nil) {
        guard !urls.isEmpty, !copyingPictures else { return }
        let panel = NSOpenPanel()
        panel.title = urls.count == 1 ? "Copy picture to a folder" : "Copy pictures to a folder"
        panel.prompt = "Copy Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        copyingPictures = true
        Task {
            defer { copyingPictures = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CollectionFileActions.copy(urls, to: destination)
                }.value
                if result.failures.isEmpty, let didCopy { didCopy(result.message) }
                else { message = result.message }
            } catch { message = error.localizedDescription }
        }
    }
}

struct PictureMenuItems: View {
    let url: URL
    @ObservedObject var library: Library
    var collectionID: UUID?

    var body: some View {
        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        Button("Copy") {
            guard !library.readableFiles([url]).isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
        Button("Copy to…") { library.copyPictures([url]) }.disabled(library.copyingPictures)
        Button("Send by Email…") { library.emailPictures([url]) }
        if let collectionID {
            Divider()
            Button("Remove from Collection") { library.unmark([url.path], in: collectionID) }
        }
    }
}

struct OptionsMenu<Items: View>: View {
    let title: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis.circle").font(.system(size: 15))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(title).help(title)
    }
}

struct ShareSelectionButton: NSViewRepresentable {
    let files: () -> [URL]
    @Binding var showing: Bool

    func makeNSView(context: Context) -> ShareButton { ShareButton() }
    func updateNSView(_ view: ShareButton, context: Context) {
        view.files = files
        view.showing = $showing
    }
    static func dismantleNSView(_ view: ShareButton, coordinator: ()) { view.dismissPicker() }

    final class ShareButton: NSButton, NSSharingServicePickerDelegate {
        var showing: Binding<Bool>?
        var files: (() -> [URL])?
        private var picker: NSSharingServicePicker?
        private var dismissalMonitor: Any?
        private var presentationLifetime: AnyCancellable?

        init() {
            super.init(frame: .zero)
            title = "Share…"
            image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            imagePosition = .imageLeading
            imageHugsTitle = true
            alignment = .center
            isBordered = false
            controlSize = .regular
            font = .systemFont(ofSize: 12, weight: .medium)
            toolTip = "Share selected pictures"
            setButtonType(.momentaryPushIn)
            sendAction(on: .leftMouseDown)
            target = self
            action = #selector(share)
        }
        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize {
            NSSize(width: super.intrinsicContentSize.width + 24, height: 28)
        }

        @objc private func share() {
            guard picker == nil, NSApp.isActive, let window, window.isVisible,
                  let urls = files?(), !urls.isEmpty else { return }
            let picker = NSSharingServicePicker(items: urls)
            self.picker = picker
            picker.delegate = self
            showing?.wrappedValue = true
            observePresentation(in: window)
            picker.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        }

        private func observePresentation(in window: NSWindow) {
            let center = NotificationCenter.default
            let otherAppActivated = NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didActivateApplicationNotification)
                .filter { notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return false }
                    return app.processIdentifier != ProcessInfo.processInfo.processIdentifier
                }
            let windowCovered = center.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
                .filter { [weak window] _ in window?.occlusionState.contains(.visible) == false }
            presentationLifetime = Publishers.MergeMany([
                center.publisher(for: NSApplication.willResignActiveNotification, object: NSApp),
                center.publisher(for: NSApplication.willHideNotification, object: NSApp),
                center.publisher(for: NSWindow.willMiniaturizeNotification, object: window),
                center.publisher(for: NSWindow.willCloseNotification, object: window)
            ]).merge(with: otherAppActivated, windowCovered)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.dismissPicker() }
            // A click back in the source window dismisses Share before the grid can select or deselect.
            dismissalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
                guard let window, event.window === window else { return event }
                self?.picker?.close()
                return nil
            }
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            // Keep the monitor for the remainder of the dismissal event's dispatch.
            DispatchQueue.main.async { [self] in
                guard picker === sharingServicePicker else { return }
                stopObserving()
                picker = nil
                showing?.wrappedValue = false
            }
        }

        func dismissPicker() {
            stopObserving()
            picker?.close()
        }

        private func stopObserving() {
            presentationLifetime = nil
            if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
            dismissalMonitor = nil
        }
    }
}
