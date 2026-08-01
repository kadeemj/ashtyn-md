import SwiftUI

/// Statistics derived from the current editor buffer, rather than the
/// eventually-consistent indexed record.
struct DocumentInfoStats: Equatable, Sendable {
    let title: String
    let titleKey: String
    let wordCount: Int
    let characterCount: Int
    let readingTimeMinutes: Int
    let todoTotal: Int
    let todoOpen: Int
    let tags: [String]
    let outgoingLinks: [NoteInfoLink]

    init(text: String, languageID: LanguageID) {
        guard languageID == .markdown else {
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            self.init(
                title: "",
                titleKey: "",
                wordCount: words,
                characterCount: text.count,
                readingTimeMinutes: words == 0 ? 0 : max(1, Int(ceil(Double(words) / 200.0))),
                todoTotal: 0,
                todoOpen: 0,
                tags: [],
                outgoingLinks: []
            )
            return
        }

        let parsed = MarkdownMetadata.parse(text)
        var seenTags = Set<String>()
        let tags = parsed.tags.compactMap { tag -> String? in
            guard seenTags.insert(tag.key).inserted else { return nil }
            return tag.path
        }
        self.init(
            title: parsed.title,
            titleKey: parsed.titleKey,
            wordCount: parsed.wordCount,
            characterCount: parsed.characterCount,
            readingTimeMinutes: parsed.readingTimeMinutes,
            todoTotal: parsed.todoTotal,
            todoOpen: parsed.todoOpen,
            tags: tags,
            outgoingLinks: parsed.links.map {
                NoteInfoLink(target: $0.target, key: $0.key)
            }
        )
    }

    private init(
        title: String,
        titleKey: String,
        wordCount: Int,
        characterCount: Int,
        readingTimeMinutes: Int,
        todoTotal: Int,
        todoOpen: Int,
        tags: [String],
        outgoingLinks: [NoteInfoLink]
    ) {
        self.title = title
        self.titleKey = titleKey
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.readingTimeMinutes = readingTimeMinutes
        self.todoTotal = todoTotal
        self.todoOpen = todoOpen
        self.tags = tags
        self.outgoingLinks = outgoingLinks
    }
}

struct NoteInfoLink: Equatable, Sendable {
    let target: String
    let key: String
}

private struct ResolvedNoteInfoLink: Identifiable, Equatable, Sendable {
    let id: String
    let target: String
    let matches: [FileRecord]
}

/// Inspector content for the active library document.
struct NoteInfoInspectorView: View {
    @Environment(AppModel.self) private var appModel

    let session: DocumentSession

    @State private var stats: DocumentInfoStats?
    @State private var backlinks: [FileRecord] = []
    @State private var resolvedLinks: [ResolvedNoteInfoLink] = []
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let stats {
                    statistics(stats)
                    if !stats.tags.isEmpty {
                        tagsSection(stats.tags)
                    }
                } else {
                    ProgressView("Updating note info…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                backlinksSection
                outgoingLinksSection
            }
            .padding(16)
        }
        .frame(minWidth: 270, idealWidth: 310, maxWidth: 420)
        .accessibilityIdentifier(AccessibilityID.noteInfoInspector)
        .onAppear { scheduleRefresh() }
        .onChange(of: session.text) { _, _ in scheduleRefresh() }
        .onChange(of: session.fileURL) { _, _ in scheduleRefresh() }
        .onChange(of: appModel.libraryChangeGeneration) { _, _ in scheduleRefresh() }
        .onDisappear {
            refreshTask?.cancel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Note Info", systemImage: "info.circle.fill")
                .font(.headline)
            Text(session.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func statistics(_ stats: DocumentInfoStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    statisticLabel("Words")
                    statisticValue(stats.wordCount)
                }
                GridRow {
                    statisticLabel("Characters")
                    statisticValue(stats.characterCount)
                }
                GridRow {
                    statisticLabel("Reading time")
                    Text(stats.readingTimeMinutes > 0 ? "\(stats.readingTimeMinutes) min" : "—")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.noteInfoReadingTime)
                }
                if stats.todoTotal > 0 {
                    GridRow {
                        statisticLabel("Tasks")
                        Text("\(stats.todoOpen) open of \(stats.todoTotal)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AccessibilityID.noteInfoTasks)
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.noteInfoStatistics)
    }

    private func statisticLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
    }

    private func statisticValue(_ value: Int) -> some View {
        Text(value, format: .number)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.primary)
    }

    private func tagsSection(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.noteInfoTags)
    }

    private var backlinksSection: some View {
        linkSection(
            title: "Backlinks",
            identifier: AccessibilityID.noteInfoBacklinks,
            emptyMessage: "No notes link to this note.",
            records: backlinks
        )
    }

    private var outgoingLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Links")
                .font(.subheadline.weight(.semibold))
            if resolvedLinks.isEmpty {
                Text("No wiki links in this note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(resolvedLinks.enumerated()), id: \.offset) { _, link in
                        if link.matches.count == 1, let record = link.matches.first {
                            noteButton(record, title: link.target)
                        } else {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(link.target)
                                    Text(link.matches.isEmpty ? "Unresolved" : "Ambiguous link")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: link.matches.isEmpty
                                      ? "questionmark.circle"
                                      : "exclamationmark.triangle")
                                .foregroundStyle(
                                    link.matches.isEmpty ? Color.secondary : Color.orange
                                )
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.noteInfoLinks)
    }

    private func linkSection(
        title: String,
        identifier: String,
        emptyMessage: String,
        records: [FileRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if records.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(records) { record in
                        noteButton(record)
                    }
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private func noteButton(_ record: FileRecord, title: String? = nil) -> some View {
        Button {
            guard let url = appModel.absoluteURL(of: record) else { return }
            appModel.openFile(at: url)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? (record.title.isEmpty ? record.name : record.title))
                    .lineLimit(1)
                Text(record.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Open note")
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let text = session.text
        let languageID = session.languageID
        let relativePath = appModel.relativePath(of: session.fileURL)
        let store = appModel.session.store

        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let parsed = await Task.detached(priority: .userInitiated) {
                DocumentInfoStats(text: text, languageID: languageID)
            }.value
            guard !Task.isCancelled else { return }

            var backlinkRecords: [FileRecord] = []
            var links: [ResolvedNoteInfoLink] = []
            if let store, let relativePath,
               let record = try? await store.record(forRelativePath: relativePath) {
                backlinkRecords = (try? await store.backlinks(
                    toTitleKey: parsed.titleKey,
                    excluding: record.id
                )) ?? []
                links = await resolve(parsed.outgoingLinks, using: store)
            }

            guard !Task.isCancelled else { return }
            stats = parsed
            backlinks = backlinkRecords
            resolvedLinks = links
        }
    }

    private func resolve(
        _ links: [NoteInfoLink],
        using store: LibraryStore
    ) async -> [ResolvedNoteInfoLink] {
        var resolved: [ResolvedNoteInfoLink] = []
        for (index, link) in links.enumerated() {
            let matches = (try? await store.resolveWikiLink(link.key)) ?? []
            resolved.append(ResolvedNoteInfoLink(
                id: "\(index)-\(link.key)",
                target: link.target,
                matches: matches
            ))
        }
        return resolved
    }
}
