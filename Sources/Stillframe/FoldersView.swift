import SwiftUI

struct FoldersToolbarButton: View {
    @EnvironmentObject private var library: Library
    let open: () -> Void

    var body: some View {
        let count = library.state.folders.count
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: library.issues.isEmpty ? "folder" : "exclamationmark.triangle")
                    Text("Folders")
                    if count > 0 { Text(count.formatted()).monospacedDigit().foregroundStyle(Palette.secondary) }
                }.padding(.horizontal, 11).frame(height: 30).contentShape(Rectangle())
            }
            .accessibilityLabel("Folders").accessibilityValue(countText(count, "folder"))
            .help(library.issues.isEmpty ? "Manage folders and subfolders" : "Check unavailable folders")
            if library.state.workspaces.count > 1 {
                Divider().frame(height: 13).accessibilityHidden(true)
                Menu {
                    WorkspacePicker().pickerStyle(.inline)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 30).contentShape(Rectangle())
                }.menuStyle(.button).menuIndicator(.hidden)
                    .accessibilityLabel("Switch workspace").accessibilityValue(library.state.workspace.name)
                    .help("Switch workspace · " + library.state.workspace.name)
            }
        }.font(.system(size: 12, weight: .semibold)).buttonStyle(.plain).fixedSize().modifier(HeaderCapsule())
    }
}

private struct WorkspacePicker: View {
    @EnvironmentObject private var library: Library

    var body: some View {
        Picker("Workspace", selection: Binding(get: { library.state.activeWorkspaceID }, set: library.switchWorkspace)) {
            ForEach(library.state.workspaces) { Text($0.name).tag($0.id) }
        }
    }
}

struct FoldersView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @ViewState private var expanded = false
    @ViewState private var editing: WorkspaceEdit?
    @ViewState private var deleting = false

    var body: some View {
        let multiple = library.state.workspaces.count > 1
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading(title: "Folders")
                    Text(multiple ? "Browsing “\(library.state.workspace.name)” in Pictures." : "Choose which folders appear in Pictures.")
                        .font(.callout).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                Button { library.chooseFolders() } label: { Label("Add Folders…", systemImage: "folder.badge.plus") }
                    .buttonStyle(ActionStyle(primary: library.state.folders.isEmpty)).fixedSize()
            }
            folderList
            DisclosureGroup(isExpanded: $expanded) {
                HStack(spacing: 8) {
                    WorkspacePicker().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    Button { editing = .new } label: { Label("New…", systemImage: "plus") }
                        .accessibilityLabel("New workspace")
                    Menu {
                        Button("Duplicate Workspace…") { editing = .duplicate }
                        Button("Rename Workspace…") { editing = .rename }
                        Divider()
                        Button("Delete Workspace…", role: .destructive) { deleting = true }.disabled(!multiple)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Workspace options").help("Workspace options")
                }.padding(.leading, 16).padding(.top, 6)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("Workspaces").font(.headline)
                        if !multiple { Text("Optional").font(.caption).foregroundStyle(Palette.secondary) }
                    }
                    Text("Save separate folder lists for different projects.")
                        .font(.callout).foregroundStyle(Palette.secondary)
                }
            }.disclosureGroupStyle(FullRowDisclosure())
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 520).foregroundStyle(Palette.ink).background(Palette.paper).tint(Palette.accent)
            .onAppear { expanded = multiple }
            .sheet(item: $editing) { WorkspaceEditor(edit: $0, workspace: library.state.workspace) }
            .alert("Delete “\(library.state.workspace.name)”?", isPresented: $deleting) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Workspace", role: .destructive) { library.deleteCurrentWorkspace() }
            } message: {
                Text("This deletes the saved folder list and its subfolder settings.")
            }
    }

    private var folderList: some View {
        Group {
            if library.state.folders.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 31, weight: .light)).foregroundStyle(Palette.accent)
                    Text("Drop folders here").font(.headline)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(library.state.folders) { folder in
                            if folder.id != library.state.folders.first?.id { Divider().padding(.leading, 45) }
                            FolderRow(folder: folder)
                        }
                    }
                }
            }
        }.frame(height: library.state.folders.isEmpty ? 126 : min(208, CGFloat(library.state.folders.count) * 88 + 16))
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line).allowsHitTesting(false))
            .modifier(FolderDropTarget())
    }
}

private struct FolderRow: View {
    @EnvironmentObject private var library: Library
    let folder: SourceFolder

    var body: some View {
        let path = folder.location.path
        let name = (path as NSString).lastPathComponent
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "folder").font(.title3).foregroundStyle(Palette.accent).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(Palette.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path)
                Toggle("Include subfolders", isOn: Binding(get: { folder.recursive }, set: { library.setRecursion($0, for: folder.id) }))
                    .toggleStyle(.checkbox).font(.callout).padding(.top, 3)
                if let issue = library.issues[folder.id] {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            Spacer(minLength: 4)
            Button { library.removeFolder(folder.id) } label: {
                Image(systemName: "minus.circle").frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                .accessibilityLabel("Remove \(name)").help("Remove this folder from Pictures")
        }.padding(12)
    }
}

private enum WorkspaceEdit: String, Identifiable {
    case new = "New workspace", duplicate = "Duplicate workspace", rename = "Rename workspace"
    var id: Self { self }
}

private struct WorkspaceEditor: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    let edit: WorkspaceEdit
    let workspace: FolderWorkspace
    @ViewState private var name: String

    init(edit: WorkspaceEdit, workspace: FolderWorkspace) {
        self.edit = edit
        self.workspace = workspace
        _name = ViewState(initialValue: edit == .new ? "" : workspace.name + (edit == .duplicate ? " copy" : ""))
    }

    var body: some View {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = library.state.workspaceNameInUse(title, excluding: edit == .rename ? workspace.id : nil)
        VStack(alignment: .leading, spacing: 15) {
            SectionHeading(title: edit.rawValue)
            if edit != .rename {
                Text(edit == .new ? "Start with an empty folder list. You can switch back to “\(workspace.name)” anytime."
                     : "Start with the folders and subfolder settings from “\(workspace.name)”.")
                    .font(.callout).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Name").font(.headline)
                TextField("Workspace name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                if duplicate { Text("A workspace already has this name.").font(.caption).foregroundStyle(Palette.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(ActionStyle()).keyboardShortcut(.cancelAction)
                Button(edit == .rename ? "Rename" : (edit == .new ? "Create" : "Duplicate")) {
                    if library.saveWorkspace(name: name, copyFolders: edit == .duplicate, rename: edit == .rename) { dismiss() }
                }.buttonStyle(ActionStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(title.isEmpty || duplicate)
            }
        }.padding(22).frame(width: 386).foregroundStyle(Palette.ink).background(Palette.paper).tint(Palette.accent)
            .onAppear { focused = true }
    }
}
