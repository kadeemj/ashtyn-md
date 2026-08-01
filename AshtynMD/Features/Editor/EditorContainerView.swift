import SwiftUI
import AppKit

enum MarkdownPreviewMode: String, CaseIterable, Identifiable {
    case editor
    case split
    case preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editor: return "Editor"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    var icon: String {
        switch self {
        case .editor: return "square.and.pencil"
        case .split: return "rectangle.split.2x1"
        case .preview: return "doc.richtext"
        }
    }
}

/// Everything the Markdown preview needs to know about its surroundings.
struct PreviewContext {
    /// Root directory the asset scheme may serve images from.
    let assetRoot: URL
    /// Note's directory relative to `assetRoot` ("" at the root).
    let noteDirectoryRelativePath: String
    /// Resolves (possibly prompting once, for standalone files) the Assets
    /// folder new images are written into; nil declines insertion.
    let assetsDirectory: () -> URL?
    let allowRawHTML: Bool
    /// Opens a relative document link inside Ashtyn MD.
    let openDocumentLink: (URL) -> Void
}

/// Editor plus its nonmodal banners, the Markdown preview modes, and a
/// status bar with document facts.
struct EditorContainerView: View {
    let session: DocumentSession
    var previewContext: PreviewContext?
    var libraryStore: LibraryStore? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let profilesStore = EditorProfilesStore.shared

    @State private var previewMode: MarkdownPreviewMode?
    @State private var renderedHTML = ""
    @State private var renderTask: Task<Void, Never>?
    @State private var renderGeneration = 0
    @State private var previewIsStale = true
    @State private var isRenderingPreview = false
    @State private var comparison: ConflictComparison?

    /// Split is the initial Markdown mode on windows at least this wide.
    static let splitDefaultMinimumWidth: CGFloat = 1_000

    private var isMarkdown: Bool {
        session.languageID == .markdown && previewContext != nil
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if session.pendingRecovery != nil {
                    recoveryBanner
                }
                switch session.conflict {
                case .externalChange: conflictBanner
                case .fileMissing: missingFileBanner
                case .none: EmptyView()
                }
                if let error = session.lastSaveError {
                    errorBanner(error)
                }
                capabilityBanner

                documentBody

                statusBar
            }
            .onAppear {
                resolveInitialMode(width: proxy.size.width)
            }
        }
        .navigationTitle(session.displayName)
        .navigationSubtitle(session.isDirty ? "Edited" : "")
        .toolbar {
            if isMarkdown {
                ToolbarItem(placement: .principal) {
                    modePicker
                }
            }
        }
        .onChange(of: session.text) {
            scheduleRender()
        }
        .onChange(of: activeMode) {
            session.viewState.previewMode = activeMode?.rawValue
            scheduleRender(immediate: true)
        }
        .onChange(of: session.previewModeRequest) {
            guard let request = session.previewModeRequest,
                  let mode = MarkdownPreviewMode(rawValue: request.rawValue)
            else { return }
            previewMode = mode
        }
        .onDisappear {
            renderTask?.cancel()
        }
        .sheet(item: $comparison) { value in
            ConflictComparisonView(comparison: value)
        }
    }

    private var activeMode: MarkdownPreviewMode? {
        isMarkdown ? previewMode : nil
    }

    private var modePicker: some View {
        Picker("Markdown Mode", selection: Binding(
            get: { previewMode ?? .editor },
            set: { previewMode = $0 }
        )) {
            ForEach(MarkdownPreviewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.icon)
                    .accessibilityLabel(mode.label)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .focusable()
        .help("Switch between editing, split, and preview")
        .accessibilityIdentifier(AccessibilityID.modePicker)
    }

    // MARK: - Layout

    private var editor: some View {
        EditorTextView(
            session: session,
            profile: profilesStore.profile(for: session.languageID),
            theme: profilesStore.theme,
            imageInsertion: insertImage,
            libraryStore: libraryStore
        )
    }

    @ViewBuilder
    private var documentBody: some View {
        if let context = previewContext, isMarkdown, let mode = previewMode {
            switch mode {
            case .editor:
                editor
            case .split:
                HSplitView {
                    editor.frame(minWidth: 280)
                    previewPane(context).frame(minWidth: 280)
                }
            case .preview:
                ZStack {
                    // The editor stays mounted (zero-sized) so checkbox
                    // toggles stay on the native undo stack.
                    editor
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    previewPane(context)
                }
            }
        } else {
            editor
        }
    }

    private func preview(_ context: PreviewContext) -> some View {
        MarkdownPreviewView(
            session: session,
            assetRoot: context.assetRoot,
            noteDirectoryRelativePath: context.noteDirectoryRelativePath,
            bodyHTML: renderedHTML,
            openDocumentLink: context.openDocumentLink
        )
    }

    private func previewPane(_ context: PreviewContext) -> some View {
        ZStack {
            preview(context)
            if session.capabilities.previewBehavior == .disabled {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "lock.doc",
                    description: Text("Choose Open Anyway to use manual preview.")
                )
                .background(Color(nsColor: .textBackgroundColor))
            } else if session.capabilities.previewBehavior == .manual && previewIsStale {
                VStack(spacing: 12) {
                    Text(renderedHTML.isEmpty ? "Preview is ready to render." : "Preview is out of date.")
                        .foregroundStyle(.secondary)
                    Button(isRenderingPreview ? "Rendering…" : "Render Preview") {
                        scheduleRender(force: true)
                    }
                    .disabled(isRenderingPreview)
                    .accessibilityIdentifier(AccessibilityID.renderPreview)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Mode + rendering

    private func resolveInitialMode(width: CGFloat) {
        guard isMarkdown, previewMode == nil else { return }
        if let stored = session.viewState.previewMode,
           let mode = MarkdownPreviewMode(rawValue: stored) {
            previewMode = mode
        } else {
            previewMode = width >= Self.splitDefaultMinimumWidth ? .split : .editor
        }
        scheduleRender(immediate: true)
    }

    /// Re-renders 250 ms after the last edit; obsolete renders are cancelled.
    private func scheduleRender(immediate: Bool = false, force: Bool = false) {
        renderTask?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        isRenderingPreview = false
        guard isMarkdown, previewMode != .editor else { return }
        switch session.capabilities.previewBehavior {
        case .disabled:
            renderedHTML = ""
            previewIsStale = true
            isRenderingPreview = false
            return
        case .manual where !force:
            previewIsStale = true
            isRenderingPreview = false
            return
        case .live, .manual:
            break
        }
        let text = session.text
        let policy = MarkdownRenderPolicy(
            allowRawHTML: previewContext?.allowRawHTML ?? false,
            allowRemoteImages: false
        )
        isRenderingPreview = true
        renderTask = Task {
            if !immediate && !force {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let html = await Task.detached(priority: .userInitiated) {
                MarkdownHTMLRenderer(policy: policy).renderBody(text)
            }.value
            guard !Task.isCancelled, renderGeneration == generation else { return }
            renderedHTML = html
            previewIsStale = false
            isRenderingPreview = false
        }
    }

    // MARK: - Image insertion

    /// Writes pasted image data into Assets and returns the relative link,
    /// or nil when no Assets destination is available.
    private func insertImage(_ data: Data, fileExtension: String) -> String? {
        guard let context = previewContext,
              let assetsDirectory = context.assetsDirectory() else { return nil }
        do {
            let assetURL = try AssetStore.writeImage(
                data, fileExtension: fileExtension, assetsDirectory: assetsDirectory
            )
            let noteDirectory = session.fileURL.deletingLastPathComponent()
            return AssetStore.relativePath(from: noteDirectory, to: assetURL)
        } catch {
            return nil
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var capabilityBanner: some View {
        switch session.capabilities.tier {
        case .full:
            EmptyView()
        case .large:
            banner(
                icon: "doc.badge.clock",
                color: .secondary,
                message: isMarkdown
                    ? "Large-file mode: AI is off and Markdown preview updates manually."
                    : "Large-file mode: AI completion is off."
            ) {
                if isMarkdown {
                    Button(isRenderingPreview ? "Rendering…" : "Render Preview") {
                        scheduleRender(force: true)
                    }
                    .disabled(isRenderingPreview)
                    .accessibilityIdentifier(AccessibilityID.renderPreview)
                }
            }
            .accessibilityIdentifier(AccessibilityID.largeFileMode)
        case .readOnlyLarge:
            banner(
                icon: "lock.doc",
                color: .orange,
                message: "This file is over 10 MB and opened read-only."
            ) {
                Button("Open Anyway") {
                    session.openLargeFileAnyway()
                }
                .accessibilityIdentifier(AccessibilityID.openLargeFileAnyway)
            }
        }
    }

    private var recoveryBanner: some View {
        banner(
            icon: "clock.arrow.circlepath",
            color: .blue,
            message: "Unsaved changes from a previous session were recovered."
        ) {
            Button("Restore") { session.acceptPendingRecovery() }
            Button("Discard") { session.discardPendingRecovery() }
        }
    }

    private var conflictBanner: some View {
        banner(
            icon: "exclamationmark.triangle.fill",
            color: .orange,
            message: "This file was changed outside Ashtyn MD while you had unsaved edits."
        ) {
            Button("Compare") {
                comparison = session.conflictComparison()
            }
            .accessibilityIdentifier(AccessibilityID.conflictCompare)
            Button("Use Disk") { session.resolveConflictUsingDisk() }
            Button("Keep Mine") { Task { await session.resolveConflictKeepingMine() } }
            Button("Save Copy…") { saveCopy() }
        }
    }

    private var missingFileBanner: some View {
        banner(
            icon: "questionmark.folder.fill",
            color: .orange,
            message: "This file was moved or deleted outside Ashtyn MD."
        ) {
            Button("Restore") { Task { await session.restoreMissingFile() } }
            Button("Save Copy…") { saveCopy() }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        banner(icon: "xmark.octagon.fill", color: .red, message: "Save failed: \(message)") {
            Button("Retry") { Task { await session.save(reason: .explicit) } }
        }
    }

    private func banner(
        icon: String,
        color: Color,
        message: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            actions()
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { barBackground }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text(LanguageDefinition.definition(for: session.languageID).displayName)
            Text(session.encoding.displayName)
            Text(session.lineEnding == .crlf ? "CRLF" : "LF")
            aiStatus
            Spacer()
            if session.isDirty {
                Text("Unsaved changes")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background { barBackground }
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var barBackground: some View {
        if reduceTransparency {
            Color(nsColor: .controlBackgroundColor)
        } else {
            Rectangle().fill(.bar)
        }
    }

    /// The active provider is visible whenever automatic completion is on;
    /// failures surface here nonmodally.
    @ViewBuilder
    private var aiStatus: some View {
        let settings = AISettings.shared
        let status = AICompletionStatus.shared
        if let error = status.lastError {
            Label(error, systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if settings.automaticCompletionEnabled, let provider = settings.selectedProvider {
            Label(
                status.isStreaming ? "\(provider.displayName)…" : "AI: \(provider.displayName)",
                systemImage: "sparkles"
            )
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.displayName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            try? await session.saveCopy(to: destination)
        }
    }
}
