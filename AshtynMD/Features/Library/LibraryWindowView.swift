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
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } content: {
            middleColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
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
            NoteListView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    /// Folders are collapsed by default: tags are the primary structure now.
    @State private var foldersExpanded = false

    var body: some View {
        @Bindable var noteList = appModel.noteList
        List(selection: $noteList.selection) {
            Section {
                row(.inbox, "Inbox", "tray")
                row(.notes, "Notes", "note.text")
                row(.untagged, "Untagged", "number")
                row(.todo, "To-Dos", "checklist")
                row(.pinned, "Pinned", "pin")
            }

            if !appModel.tags.tree.isEmpty {
                Section("Tags") {
                    // Pinned tags are hoisted to the top of their level.
                    OutlineGroup(
                        sortedForDisplay(appModel.tags.tree),
                        id: \.id,
                        children: \.nonEmptyChildren
                    ) { node in
                        tagRow(node)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.tagTree)
            }

            if let tree = appModel.session.folderTree {
                Section("Folders", isExpanded: $foldersExpanded) {
                    folderRow(tree, isRoot: true)
                    OutlineGroup(tree.children, id: \.id, children: \.nonEmptyChildren) { node in
                        folderRow(node, isRoot: false)
                    }
                }
            }

            Section {
                row(.favorites, "Favorites", "star")
                row(.recents, "Recents", "clock")
                row(.search, "Search", "magnifyingglass")
                row(.archive, "Archive", "archivebox")
                row(.trash, "Trash", "trash")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityID.sidebar)
    }

    /// A fixed row with its count badge.
    private func row(_ item: SidebarItem, _ title: String, _ symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count = appModel.tags.count(for: item), count > 0 {
                Text(count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .tag(item)
        .accessibilityLabel(title)
        .accessibilityValue(
            (appModel.tags.count(for: item)?.description).map { "\($0) notes" } ?? ""
        )
    }

    private func tagRow(_ node: TagNode) -> some View {
        HStack {
            Label {
                Text(node.displayName)
            } icon: {
                Image(systemName: node.isPinned ? "number.circle.fill" : "number")
            }
            Spacer()
            if node.count > 0 {
                Text(node.count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .tag(SidebarItem.tag(node.key))
        // Dropping a note on a tag adds the tag to the note's *text*: tags are
        // content, so there is nowhere else for it to live.
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                appModel.addTag(node.key, toFileAt: url)
            }
            return !urls.isEmpty
        }
        .contextMenu {
            Button(node.isPinned ? "Unpin Tag" : "Pin Tag") {
                appModel.tags.setPinned(!node.isPinned, key: node.key, using: appModel.session)
            }
            Button("New Note in #\(node.displayName)") {
                appModel.actions.newNoteInInbox(seedTag: node.key)
            }
            Button("Copy Tag") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("#\(node.displayPath)", forType: .string)
            }
        }
    }

    /// Pinned first, then alphabetical, recursively.
    private func sortedForDisplay(_ nodes: [TagNode]) -> [TagNode] {
        nodes
            .map { node in
                var copy = node
                copy.children = sortedForDisplay(node.children)
                return copy
            }
            .sorted { left, right in
                if left.isPinned != right.isPinned { return left.isPinned }
                return left.key.localizedStandardCompare(right.key) == .orderedAscending
            }
    }

    private func folderRow(_ node: FolderNode, isRoot: Bool) -> some View {
        Label(node.name, systemImage: isRoot ? "books.vertical" : "folder")
            .tag(SidebarItem.folder(node.url))
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls {
                    appModel.actions.moveFile(at: url, into: node.url)
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

// MARK: - Note list

struct NoteListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var recordToRename: FileRecord?
    @State private var renameText = ""
    @State private var isMovePresented = false

    private var noteList: NoteListModel { appModel.noteList }

    var body: some View {
        @Bindable var bindableList = appModel.noteList
        VStack(spacing: 0) {
            if let progress = appModel.session.indexingProgress {
                indexingHeader(progress)
            }
            List(selection: $bindableList.selectedPaths) {
                ForEach(noteList.notes) { record in
                    NoteRow(record: record, isTrash: noteList.selection == .trash)
                        .tag(record.relativePath)
                        .draggable(
                            appModel.absoluteURL(of: record) ?? URL(fileURLWithPath: "/")
                        ) {
                            Label(record.name, systemImage: "doc.text")
                        }
                        .contextMenu { contextMenu(for: record) }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier(AccessibilityID.noteList)
        }
        .navigationTitle(noteList.title())
        .toolbar { ToolbarItem { sortMenu } }
        .overlay {
            if noteList.notes.isEmpty && appModel.session.indexingProgress == nil {
                let empty = noteList.emptyState
                ContentUnavailableView(
                    empty.title,
                    systemImage: empty.symbol,
                    description: Text(empty.message)
                )
            }
        }
        .alert("Rename File", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let record = recordToRename {
                    appModel.actions.rename(record, to: renameText)
                }
                recordToRename = nil
            }
            Button("Cancel", role: .cancel) { recordToRename = nil }
        }
        .sheet(isPresented: $isMovePresented) {
            MoveToFolderSheet(records: targetRecords) { folder in
                appModel.actions.move(targetRecords, into: folder)
            }
        }
        .onReceive(LibraryCommandRequests.shared.requests) { request in
            switch request {
            case .moveToFolder: isMovePresented = true
            }
        }
    }

    /// A note-list action applies to the selection, or to the active note when
    /// nothing is selected.
    private var targetRecords: [FileRecord] {
        let selected = noteList.selectedRecords
        if !selected.isEmpty { return selected }
        guard let session = appModel.activeSession,
              let path = appModel.relativePath(of: session.fileURL),
              let record = noteList.notes.first(where: { $0.relativePath == path })
        else { return [] }
        return [record]
    }

    private func indexingHeader(_ progress: IndexingProgress) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Updating index — \(progress.scanned) notes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private func contextMenu(for record: FileRecord) -> some View {
        if noteList.selection == .trash {
            Button("Restore") { /* Gate 4 */ }
                .disabled(true)
            Button("Delete Permanently", role: .destructive) {
                appModel.actions.moveToTrash([record])
            }
        } else {
            Button(record.isPinned ? "Unpin" : "Pin") {
                appModel.actions.togglePinned(record)
            }
            Button(record.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                appModel.actions.toggleFavorite(record)
            }
            Divider()
            Button("Move to…") { isMovePresented = true }
            Button("Rename…") {
                renameText = record.name
                recordToRename = record
            }
            Button("Duplicate") { appModel.actions.duplicate(record) }
            Divider()
            Button("Reveal in Finder") {
                if let url = appModel.absoluteURL(of: record) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                appModel.actions.moveToTrash(targetRecords.isEmpty ? [record] : targetRecords)
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { recordToRename != nil },
            set: { if !$0 { recordToRename = nil } }
        )
    }

    private var sortMenu: some View {
        @Bindable var bindableList = appModel.noteList
        return Menu {
            Picker("Sort By", selection: $bindableList.sortOrder) {
                Text("Date Modified").tag(LibraryStore.SortOrder.modifiedDescending)
                Text("Date Created").tag(LibraryStore.SortOrder.createdDescending)
                Text("Title").tag(LibraryStore.SortOrder.titleAscending)
                Text("Filename").tag(LibraryStore.SortOrder.nameAscending)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Change how notes are sorted")
    }
}

/// Bear-style row: title, two-line excerpt, date, and state indicators.
struct NoteRow: View {
    let record: FileRecord
    var isTrash = false

    private var displayTitle: String {
        record.title.isEmpty ? "Untitled" : record.title
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(record.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                if !record.excerpt.isEmpty {
                    Text(record.excerpt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(dateForDisplay, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    if record.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                    }
                    if record.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if record.todoOpen > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "checklist")
                            Text(record.todoOpen, format: .number)
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        // Label is the title, so tests and VoiceOver read what the user sees.
        .accessibilityLabel(displayTitle)
        // Value keeps the filename available, since the two now differ.
        .accessibilityValue(record.name)
    }

    private var dateForDisplay: Date {
        isTrash ? (record.trashedAt ?? record.modifiedAt) : record.modifiedAt
    }
}

// MARK: - Move to folder

/// Folder picker for filing notes out of the Inbox.
struct MoveToFolderSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let records: [FileRecord]
    let move: (URL) -> Void

    @State private var selection: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(records.count == 1
                 ? "Move “\(records[0].title.isEmpty ? records[0].name : records[0].title)” to:"
                 : "Move \(records.count) notes to:")
                .font(.headline)

            if let tree = appModel.session.folderTree {
                List(selection: $selection) {
                    folderRow(tree, isRoot: true)
                    OutlineGroup(tree.children, id: \.id, children: \.nonEmptyChildren) { node in
                        folderRow(node, isRoot: false)
                    }
                }
                .frame(minHeight: 240)
                .accessibilityIdentifier(AccessibilityID.moveToFolderSheet)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Move") {
                    if let selection { move(selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || records.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func folderRow(_ node: FolderNode, isRoot: Bool) -> some View {
        Label(isRoot ? node.name : node.name, systemImage: isRoot ? "books.vertical" : "folder")
            .tag(node.url)
    }
}

// MARK: - Search

struct SearchColumnView: View {
    @Environment(AppModel.self) private var appModel
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        @Bindable var search = appModel.search
        VStack(spacing: 0) {
            TextField("Search titles, paths, and content", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)
                .padding(10)
                .accessibilityLabel("Library search")
                .accessibilityIdentifier(AccessibilityID.searchField)
                .onSubmit {
                    guard let first = appModel.search.results.first,
                          let url = appModel.absoluteURL(of: first.record)
                    else { return }
                    appModel.openFile(at: url)
                }
            Divider()
            List(appModel.search.results, selection: selectionBinding) { result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.record.title.isEmpty ? result.record.name : result.record.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(plainSnippet(result.snippet))
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
                .accessibilityLabel(
                    result.record.title.isEmpty ? result.record.name : result.record.title
                )
                .accessibilityValue(plainSnippet(result.snippet))
            }
            .accessibilityIdentifier(AccessibilityID.searchResults)
            .overlay {
                if appModel.search.results.isEmpty && !appModel.search.query.isEmpty {
                    ContentUnavailableView.search(text: appModel.search.query)
                }
            }
        }
        .navigationTitle("Search")
        .onAppear { searchFieldFocused = true }
    }

    /// Gate 5 renders these delimiters as real highlight; for now they are
    /// stripped so the snippet reads cleanly.
    private func plainSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "⟦", with: "")
            .replacingOccurrences(of: "⟧", with: "")
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                guard let session = appModel.activeSession else { return nil }
                return appModel.relativePath(of: session.fileURL)
            },
            set: { path in
                guard let path, let root = appModel.libraryRoot?.url else { return }
                appModel.openFile(at: root.appendingPathComponent(path))
            }
        )
    }
}

// MARK: - Document area

struct DocumentAreaView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            if !appModel.tabs.tabs.isEmpty {
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
                    "No Note Selected",
                    systemImage: "doc.text",
                    description: Text("Select a note from the list, or press ⌘N to capture a new one.")
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
                ForEach(appModel.tabs.tabs) { session in
                    TabItemView(
                        session: session,
                        isActive: session.id == appModel.tabs.activeTabID,
                        activate: { appModel.tabs.activate(session.id) },
                        close: { appModel.tabs.close(session.id) }
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
