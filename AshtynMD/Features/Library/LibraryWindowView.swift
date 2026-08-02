import SwiftUI

/// Wraps a `QuickOpenModel` so `.sheet(item:)` can own its lifetime. Plain
/// `.sheet(isPresented:)` plus a *separate* `@State` model was tried first,
/// but SwiftUI can present that sheet's content closure using a snapshot
/// from just before both `@State` writes landed, evaluating the closure with
/// the model still `nil` even though it was set moments earlier in the same
/// handler — the two pieces of state were not atomic from the sheet's point
/// of view. Folding presence and content into one `Identifiable` value that
/// `.sheet(item:)` binds to removes that race: there is no longer a "started
/// presenting" flag that can disagree with "which model to show."
private struct QuickOpenSheetItem: Identifiable {
    let id = UUID()
    let model: QuickOpenModel
}

/// Root view of a library window: onboarding until a root folder is chosen,
/// then the three-column library layout.
struct LibraryWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var quickOpenSheetItem: QuickOpenSheetItem?

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
        .onReceive(LibraryCommandRequests.shared.requests) { request in
            switch request {
            case .quickOpen:
                quickOpenSheetItem = QuickOpenSheetItem(
                    model: QuickOpenModel(store: appModel.session.store)
                )
            case .moveToFolder: break // handled by NoteListView's own receiver
            }
        }
        .sheet(item: $quickOpenSheetItem) { item in
            QuickOpenView(
                model: item.model,
                onSelect: { record in
                    if let url = appModel.absoluteURL(of: record) {
                        appModel.openFile(at: url)
                    }
                }
            )
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
    /// Folders start expanded so the library tree is immediately navigable.
    @State private var foldersExpanded = true
    @State private var tagToRename: TagNode?
    @State private var tagToDelete: TagNode?
    @State private var tagRenameText = ""

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
                    tagRows(sortedForDisplay(appModel.tags.tree), level: 0)
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
        .alert("Rename Tag", isPresented: tagRenameAlertBinding) {
            TextField("Tag", text: $tagRenameText)
            Button("Rename") {
                if let tagToRename {
                    appModel.renameTag(tagToRename.key, to: tagRenameText)
                }
                self.tagToRename = nil
            }
            Button("Cancel", role: .cancel) { tagToRename = nil }
        }
        .confirmationDialog(
            "Delete #\(tagToDelete?.displayPath ?? "")?",
            isPresented: tagDeleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete Tag", role: .destructive) {
                if let tagToDelete {
                    appModel.deleteTag(tagToDelete.key)
                }
                self.tagToDelete = nil
            }
            Button("Cancel", role: .cancel) { tagToDelete = nil }
        } message: {
            Text("This removes the tag from every matching note. Nested tags are included.")
        }
    }

    private var tagRenameAlertBinding: Binding<Bool> {
        Binding(
            get: { tagToRename != nil },
            set: { if !$0 { tagToRename = nil } }
        )
    }

    private var tagDeleteDialogBinding: Binding<Bool> {
        Binding(
            get: { tagToDelete != nil },
            set: { if !$0 { tagToDelete = nil } }
        )
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
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.displayName)
        .accessibilityValue(node.count > 0 ? "\(node.count) notes" : "")
        .contentShape(Rectangle())
        .onTapGesture {
            // The recursive presentation is intentionally not an OutlineGroup:
            // explicit selection keeps nested tag rows reliable in both the
            // native sidebar and macOS accessibility automation.
            appModel.sidebarSelection = .tag(node.key)
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
            Divider()
            Button("Rename Tag…") {
                tagRenameText = node.displayPath
                tagToRename = node
            }
            Button("Delete Tag", role: .destructive) {
                tagToDelete = node
            }
            if appModel.tagRewriteUndoAvailable {
                Divider()
                Button("Undo Last Tag Rewrite") {
                    appModel.undoLastTagRewrite()
                }
            }
        }
    }

    /// Keep the tag hierarchy visible so parent and child tags can be selected
    /// directly; indentation preserves the hierarchy without a collapsed
    /// disclosure state hiding useful filters.
    private func tagRows(_ nodes: [TagNode], level: Int) -> AnyView {
        AnyView(
            ForEach(nodes) { node in
                VStack(alignment: .leading, spacing: 0) {
                    tagRow(node)
                        .padding(.leading, CGFloat(level) * 16)
                    if !node.children.isEmpty {
                        tagRows(sortedForDisplay(node.children), level: level + 1)
                    }
                }
            }
        )
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
        HStack(spacing: 6) {
            Image(systemName: isRoot ? "books.vertical" : "folder")
                .accessibilityHidden(true)
            Text(node.name)
                .accessibilityLabel(node.name)
        }
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
            .onChange(of: noteList.selectedPaths) { oldSelection, newSelection in
                // List selection is also the document-open gesture. Keep the
                // set so multi-selection still works for note actions, while
                // opening the newly selected row in the editor immediately.
                let path = newSelection.subtracting(oldSelection).first
                    ?? (newSelection.count == 1 ? newSelection.first : nil)
                guard let path, let root = appModel.libraryRoot?.url else { return }
                appModel.openFile(at: root.appendingPathComponent(path))
            }
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
            case .quickOpen: break // handled by LibraryWindowView's own receiver
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
            Button("Restore") {
                appModel.actions.restoreFromTrash([record])
            }
            Button("Delete Permanently", role: .destructive) {
                appModel.actions.deletePermanently([record])
            }
        } else if noteList.selection == .archive {
            Button("Unarchive") {
                appModel.actions.unarchive([record])
            }
            Button("Move to Trash", role: .destructive) {
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
            Button("Archive") { appModel.actions.archive([record]) }
            Button("Rename…") {
                renameText = record.name
                recordToRename = record
            }
            if !record.titleIsManaged {
                Button("Match Filename to First Line") {
                    appModel.actions.useTitleAsFilename(record)
                }
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
        // The identifier makes the filename queryable even when List bridges
        // the row through an AX element that drops its value field.
        .accessibilityIdentifier(record.name)
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
                    highlightedSnippet(result.snippet)
                        .font(.caption)
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
                .accessibilityValue(plainSnippetText(result.snippet))
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

    private func highlightedSnippet(_ snippet: String) -> Text {
        SearchSnippet.segments(from: snippet).reduce(Text("")) { partial, segment in
            let piece = segment.isHighlighted
                ? Text(segment.text).fontWeight(.semibold).foregroundStyle(.primary)
                : Text(segment.text).foregroundStyle(.secondary)
            return partial + piece
        }
    }

    private func plainSnippetText(_ snippet: String) -> String {
        SearchSnippet.segments(from: snippet).map(\.text).joined()
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
    @State private var isNoteInfoPresented = false

    var body: some View {
        VStack(spacing: 0) {
            if !appModel.tabs.tabs.isEmpty {
                TabBarView()
                Divider()
            }
            if let session = appModel.activeSession {
                EditorContainerView(
                    session: session,
                    previewContext: previewContext(for: session),
                    libraryStore: appModel.session.store,
                    reindex: { appModel.session.reindex() },
                    reportError: { appModel.reportError($0) }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Note Info", systemImage: "info.circle") {
                    isNoteInfoPresented.toggle()
                }
                .disabled(appModel.activeSession == nil)
                .help("Show note information and backlinks")
                .accessibilityIdentifier(AccessibilityID.noteInfoInspector)
            }
        }
        .inspector(isPresented: $isNoteInfoPresented) {
            if let session = appModel.activeSession {
                NoteInfoInspectorView(session: session)
            }
        }
        .onChange(of: appModel.activeSession?.id) { _, id in
            if id == nil { isNoteInfoPresented = false }
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
        let actualRelativePath = model.relativePath(of: session.fileURL) ?? ""
        let noteDirectoryRelativePath: String = {
            guard let original = NoteLifecycle.originalRelativePath(
                ofArchivePath: actualRelativePath
            ) else {
                return model.relativePath(of: noteDirectory) ?? ""
            }
            return (original as NSString).deletingLastPathComponent
        }()
        return PreviewContext(
            assetRoot: root,
            noteDirectoryRelativePath: noteDirectoryRelativePath,
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
