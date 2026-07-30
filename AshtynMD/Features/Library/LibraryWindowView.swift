import SwiftUI

/// Root view of a library window: onboarding until a root folder is chosen,
/// then the three-column library layout.
struct LibraryWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appModel.libraryRoot == nil {
                OnboardingView()
            } else {
                LibrarySplitView()
            }
        }
        .onReceive(StandaloneOpenRequests.shared.requests) { url in
            if appModel.contains(url) {
                appModel.sidebarSelection = .folder(url.deletingLastPathComponent())
                appModel.openFile(at: url)
            } else {
                openWindow(id: WindowID.standaloneDocument, value: url)
            }
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to Ashtyn MD")
                .font(.largeTitle.weight(.semibold))
            Text("Choose a folder for your notes. Ashtyn MD stores ordinary Markdown, text, and source files there — nothing is locked in a private database.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose Notes Folder…") {
                appModel.chooseLibraryFolder()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.onboardingChooseFolder)
            if let error = appModel.openError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(48)
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct LibrarySplitView: View {
    @Environment(AppModel.self) private var appModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            middleColumn
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DocumentAreaView()
        }
        .frame(minWidth: 960, minHeight: 520)
    }

    @ViewBuilder
    private var middleColumn: some View {
        if appModel.sidebarSelection == .search {
            SearchColumnView()
        } else {
            FileListView()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        List(selection: $appModel.sidebarSelection) {
            Section("Library") {
                Label("All Files", systemImage: "tray.full")
                    .tag(SidebarItem.allFiles)
                Label("Favorites", systemImage: "star")
                    .tag(SidebarItem.favorites)
                Label("Recents", systemImage: "clock")
                    .tag(SidebarItem.recents)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
            }
            if let tree = appModel.folderTree {
                Section("Folders") {
                    folderRow(tree, isRoot: true)
                    OutlineGroup(tree.children, id: \.id, children: \.nonEmptyChildren) { node in
                        folderRow(node, isRoot: false)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityID.sidebar)
    }

    private func folderRow(_ node: FolderNode, isRoot: Bool) -> some View {
        Label(node.name, systemImage: isRoot ? "books.vertical" : "folder")
            .tag(SidebarItem.folder(node.url))
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls {
                    appModel.moveFile(at: url, into: node.url)
                }
                return !urls.isEmpty
            }
    }
}

extension FolderNode {
    /// OutlineGroup shows a disclosure chevron for any non-nil children array,
    /// so leaf folders return nil instead of [].
    var nonEmptyChildren: [FolderNode]? {
        children.isEmpty ? nil : children
    }
}

struct FileListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var recordToRename: FileRecord?
    @State private var renameText = ""

    var body: some View {
        List(appModel.files, selection: activeFileBinding) { record in
            FileRecordRow(record: record)
                .tag(record.relativePath)
                .draggable(appModel.absoluteURL(of: record) ?? URL(fileURLWithPath: "/")) {
                    Label(record.name, systemImage: "doc.text")
                }
                .contextMenu {
                    Button(record.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                        appModel.toggleFavorite(record)
                    }
                    Button("Rename…") {
                        renameText = record.name
                        recordToRename = record
                    }
                    Button("Duplicate") {
                        appModel.duplicate(record)
                    }
                    Divider()
                    Button("Reveal in Finder") {
                        if let url = appModel.absoluteURL(of: record) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        appModel.moveToTrash(record)
                    }
                }
        }
        .navigationTitle(listTitle)
        .accessibilityIdentifier(AccessibilityID.fileList)
        .toolbar {
            ToolbarItem {
                sortMenu
            }
        }
        .overlay {
            if appModel.files.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "doc",
                    description: Text("Press ⌘N to create a Markdown note here.")
                )
            }
        }
        .alert("Rename File", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let record = recordToRename {
                    appModel.rename(record, to: renameText)
                }
                recordToRename = nil
            }
            Button("Cancel", role: .cancel) { recordToRename = nil }
        }
    }

    private var activeFileBinding: Binding<String?> {
        Binding(
            get: {
                guard let session = appModel.activeSession else { return nil }
                return appModel.relativePath(of: session.fileURL)
            },
            set: { path in
                guard let path,
                      let record = appModel.files.first(where: { $0.relativePath == path }),
                      let url = appModel.absoluteURL(of: record) else { return }
                appModel.openFile(at: url)
            }
        )
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { recordToRename != nil },
            set: { if !$0 { recordToRename = nil } }
        )
    }

    private var listTitle: String {
        switch appModel.sidebarSelection {
        case .favorites: return "Favorites"
        case .recents: return "Recents"
        case .folder(let url): return url.lastPathComponent
        default: return "All Files"
        }
    }

    private var sortMenu: some View {
        @Bindable var appModel = appModel
        return Menu {
            Picker("Sort By", selection: $appModel.sortOrder) {
                Text("Date Modified").tag(LibraryStore.SortOrder.modifiedDescending)
                Text("Name").tag(LibraryStore.SortOrder.nameAscending)
                Text("Date Created").tag(LibraryStore.SortOrder.createdDescending)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Change how files are sorted")
    }
}

struct FileRecordRow: View {
    let record: FileRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(LanguageDefinition.definition(for: record.languageID).displayName)
                    Text(record.modifiedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if record.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.name)
        .accessibilityValue(
            "\(LanguageDefinition.definition(for: record.languageID).displayName), "
                + "\(record.modifiedAt.formatted(date: .abbreviated, time: .shortened)), "
                + (record.isFavorite ? "Favorite" : "Not favorite")
        )
    }
}

struct SearchColumnView: View {
    @Environment(AppModel.self) private var appModel
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        @Bindable var appModel = appModel
        VStack(spacing: 0) {
            TextField("Search titles, paths, and content", text: $appModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)
                .padding(10)
                .accessibilityLabel("Library search")
                .accessibilityIdentifier(AccessibilityID.searchField)
                .onSubmit {
                    guard let first = appModel.searchResults.first,
                          let url = appModel.absoluteURL(of: first.record)
                    else { return }
                    appModel.openFile(at: url)
                }
            Divider()
            List(appModel.searchResults, selection: selectionBinding) { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.record.name)
                        .font(.body)
                        .lineLimit(1)
                    Text(result.snippet.replacingOccurrences(of: "⟦", with: "")
                        .replacingOccurrences(of: "⟧", with: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(result.record.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .tag(result.record.relativePath)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(result.record.name)
                .accessibilityValue(
                    result.snippet.replacingOccurrences(of: "⟦", with: "")
                        .replacingOccurrences(of: "⟧", with: "")
                )
            }
            .accessibilityIdentifier(AccessibilityID.fileList)
            .overlay {
                if appModel.searchResults.isEmpty && !appModel.searchQuery.isEmpty {
                    ContentUnavailableView.search(text: appModel.searchQuery)
                }
            }
        }
        .navigationTitle("Search")
        .onAppear { searchFieldFocused = true }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                guard let session = appModel.activeSession else { return nil }
                return appModel.relativePath(of: session.fileURL)
            },
            set: { path in
                guard let path,
                      let root = appModel.libraryRoot?.url else { return }
                appModel.openFile(at: root.appendingPathComponent(path))
            }
        )
    }
}

struct DocumentAreaView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            if !appModel.tabs.isEmpty {
                TabBarView()
                Divider()
            }
            if let session = appModel.activeSession {
                EditorContainerView(
                    session: session,
                    previewContext: previewContext(for: session)
                )
                .id(session.id)
            } else {
                ContentUnavailableView(
                    "No File Selected",
                    systemImage: "doc.text",
                    description: Text("Select a file from the list, or press ⌘N for a new Markdown note.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension DocumentAreaView {
    /// Library documents preview against the library root: assets live in
    /// <library>/Assets and relative links resolve within the library.
    func previewContext(for session: DocumentSession) -> PreviewContext? {
        guard let root = appModel.libraryRoot?.url else { return nil }
        let noteDirectory = session.fileURL.deletingLastPathComponent()
        let model = appModel
        return PreviewContext(
            assetRoot: root,
            noteDirectoryRelativePath: model.relativePath(of: noteDirectory) ?? "",
            assetsDirectory: { root.appendingPathComponent("Assets", isDirectory: true) },
            allowRawHTML: model.allowRawHTML,
            openDocumentLink: { url in
                let relative = (url.path.removingPercentEncoding ?? url.path).drop(while: { $0 == "/" })
                let target = root.appendingPathComponent(String(relative))
                guard LibraryBrowser.isSupportedTextFile(target),
                      FileManager.default.fileExists(atPath: target.path) else { return }
                model.openFile(at: target)
            }
        )
    }
}

struct TabBarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(appModel.tabs) { session in
                    TabItemView(
                        session: session,
                        isActive: session.id == appModel.activeTabID,
                        activate: { appModel.activateTab(session.id) },
                        close: { appModel.closeTab(session.id) }
                    )
                }
            }
        }
        .frame(height: 30)
        .background { barBackground }
        .accessibilityIdentifier(AccessibilityID.tabBar)
    }

    @ViewBuilder
    private var barBackground: some View {
        if reduceTransparency {
            Color(nsColor: .controlBackgroundColor)
        } else {
            Rectangle().fill(.bar)
        }
    }
}

struct TabItemView: View {
    let session: DocumentSession
    let isActive: Bool
    let activate: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive ? 1 : 0)
            .accessibilityLabel("Close \(session.displayName)")

            Text(session.displayName)
                .font(.callout)
                .lineLimit(1)

            if session.isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .onHover { isHovering = $0 }
    }
}
