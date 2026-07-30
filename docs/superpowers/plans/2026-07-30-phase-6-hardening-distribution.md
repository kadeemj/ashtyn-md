# Phase 6 Hardening and Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining hardening gaps and produce a universal, Developer ID-signed, notarized, stapled Ashtyn MD 0.1.0 DMG.

**Architecture:** A session-owned `DocumentCapabilities` policy controls large-file behavior across the editor, preview, and AI layers. Debug-only launch configuration supplies deterministic XCUITest fixtures, while dedicated stress/performance gates exercise production types. A fail-closed release script builds the exact verified revision, notarizes the app and DMG, and validates the mounted artifact.

**Tech Stack:** Swift 6.0 with strict concurrency, SwiftUI, AppKit/TextKit 1, SQLite/FTS5, FSEvents, Swift Testing, XCTest/XCUITest, XcodeGen, `xcodebuild`, `codesign`, `notarytool`, `stapler`, `hdiutil`, and `spctl`.

## Global Constraints

- Target macOS 14.0 and later.
- Build universal `arm64` and `x86_64` Release artifacts.
- Keep `project.yml` as the Xcode project source of truth; never edit `AshtynMD.xcodeproj` directly.
- Run `xcodegen generate` after adding or removing source files or targets.
- Keep Swift strict concurrency at `complete`.
- Keep note files as canonical data; do not add note-body persistence outside the disposable FTS index.
- Preserve original encoding, BOM, and LF/CRLF line endings.
- Keep the App Sandbox, user-selected read/write access, app-scoped bookmarks, and outbound network entitlement.
- Add no runtime dependency beyond the existing permissively licensed Tree-sitter packages and `swift-markdown` 0.8.0.
- Do not place Apple credentials, app-specific passwords, file content, or signing secrets in source, scripts, logs, or artifacts.
- Bundle identifier remains `com.kadeem.ashtynmd`.
- Release version remains `0.1.0` with build number `1`.
- Direct-download signing uses team `JUQMKZZ7TJ` and the installed `Developer ID Application: Kadeem Jeffery (JUQMKZZ7TJ)` identity.
- Notarization uses the login-Keychain profile `AshtynMD-notary`.
- A self-updater remains out of scope.

---

## File map

### Production files to create

- `AshtynMD/Core/Documents/DocumentCapabilities.swift` — pure byte-size policy and Open Anyway transition.
- `AshtynMD/Features/Editor/ConflictComparisonView.swift` — native read-only comparison sheet.
- `AshtynMD/App/AccessibilityIdentifiers.swift` — stable accessibility identifiers shared by views and UI tests.
- `AshtynMD/App/UITestLaunchConfiguration.swift` — Debug-only fixture-library and mock-AI bootstrap.

### Test files to create

- `AshtynMD/Tests/DocumentCapabilitiesTests.swift` — tier boundaries and Open Anyway.
- `AshtynMD/Tests/ExternalSyncStressTests.swift` — rapid filesystem mutation and conflict transitions.
- `AshtynMD/Tests/PerformanceGateTests.swift` — opt-in 10,000-file, Markdown, syntax, editor, and memory gates.
- `AshtynMD/UITests/UITestCase.swift` — deterministic app launch and polling helpers.
- `AshtynMD/UITests/LibraryWorkflowUITests.swift` — library, file, tab, search, favorite, and recent workflows.
- `AshtynMD/UITests/EditorWorkflowUITests.swift` — paste, preview, image, standalone, and AI workflows.
- `AshtynMD/UITests/KeyboardAccessibilityUITests.swift` — keyboard-only and accessibility assertions.
- `script/tests/release_lib_test.sh` — pure release-helper tests.
- `script/tests/release_config_test.sh` — generated Release build-setting assertions.

### Automation and documentation files to create

- `script/performance_gate.sh` — opt-in performance test entry point.
- `script/release_lib.sh` — pure shell validation helpers.
- `script/release.sh` — end-to-end build, signing, notarization, packaging, and validation.
- `docs/verification/phase-6-accessibility.md` — recorded manual appearance and assistive-technology audit.

### Existing files to modify

- `AshtynMD/Core/Documents/DocumentSession.swift`
- `AshtynMD/Core/Indexing/SQLiteDatabase.swift`
- `AshtynMD/Core/Indexing/LibraryStore.swift`
- `AshtynMD/Core/Indexing/LibraryIndexer.swift`
- `AshtynMD/Core/FileSystem/LibraryBookmarkStore.swift`
- `AshtynMD/Features/AICompletion/AICompletionController.swift`
- `AshtynMD/Features/Editor/EditorTextView.swift`
- `AshtynMD/Features/Editor/EditorContainerView.swift`
- `AshtynMD/Features/Library/AppModel.swift`
- `AshtynMD/Features/Library/LibraryWindowView.swift`
- `AshtynMD/Features/Library/StandaloneDocumentView.swift`
- `AshtynMD/App/AshtynMDApp.swift`
- `AshtynMD/Tests/AICompletionTests.swift`
- `AshtynMD/Tests/LibraryIndexerTests.swift`
- `AshtynMD/Tests/LibraryStoreTests.swift`
- `AshtynMD/Tests/SaveAndRecoveryTests.swift`
- `project.yml`
- `.gitignore`

---

### Task 1: Add the session-owned large-file capability policy

**Files:**

- Create: `AshtynMD/Core/Documents/DocumentCapabilities.swift`
- Create: `AshtynMD/Tests/DocumentCapabilitiesTests.swift`
- Modify: `AshtynMD/Core/Documents/DocumentSession.swift:20-92`

**Interfaces:**

- Produces: `DocumentCapabilities`, `DocumentCapabilities.Tier`, `DocumentCapabilities.PreviewBehavior`
- Produces: `DocumentSession.capabilities: DocumentCapabilities`
- Produces: `DocumentSession.openLargeFileAnyway()`
- Consumes: file byte size from `FileManager.attributesOfItem(atPath:)`

- [ ] **Step 1: Write boundary and override tests**

```swift
import Testing
@testable import AshtynMD

@Suite("Document capabilities")
struct DocumentCapabilitiesTests {
    @Test(arguments: [
        (Int64(0), DocumentCapabilities.Tier.full),
        (2 * 1024 * 1024, .full),
        (2 * 1024 * 1024 + 1, .large),
        (10 * 1024 * 1024, .large),
        (10 * 1024 * 1024 + 1, .readOnlyLarge),
    ])
    func byteBoundaries(byteCount: Int64, expected: DocumentCapabilities.Tier) {
        #expect(DocumentCapabilities(byteCount: byteCount).tier == expected)
    }

    @Test func largeModeDefersPreviewAndDisablesAI() {
        let value = DocumentCapabilities(byteCount: 3 * 1024 * 1024)
        #expect(value.isEditable)
        #expect(value.previewBehavior == .manual)
        #expect(!value.allowsAICompletion)
    }

    @Test func readOnlyLargeOpensIntoSafeguardedLargeMode() {
        let value = DocumentCapabilities(byteCount: 11 * 1024 * 1024)
        #expect(!value.isEditable)
        let overridden = value.openingAnyway()
        #expect(overridden.tier == .large)
        #expect(overridden.isEditable)
        #expect(overridden.previewBehavior == .manual)
        #expect(!overridden.allowsAICompletion)
    }
}
```

- [ ] **Step 2: Regenerate and run the focused test to verify RED**

Run:

```bash
xcodegen generate
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/DocumentCapabilitiesTests
```

Expected: compilation fails because `DocumentCapabilities` does not exist.

- [ ] **Step 3: Implement the minimal pure policy**

```swift
import Foundation

struct DocumentCapabilities: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        case full
        case large
        case readOnlyLarge
    }

    enum PreviewBehavior: Equatable, Sendable {
        case live
        case manual
        case disabled
    }

    static let fullFeatureByteLimit: Int64 = 2 * 1024 * 1024
    static let readOnlyByteLimit: Int64 = 10 * 1024 * 1024

    let byteCount: Int64
    let tier: Tier

    init(byteCount: Int64, openedAnyway: Bool = false) {
        self.byteCount = max(0, byteCount)
        if byteCount <= Self.fullFeatureByteLimit {
            tier = .full
        } else if byteCount <= Self.readOnlyByteLimit || openedAnyway {
            tier = .large
        } else {
            tier = .readOnlyLarge
        }
    }

    var isEditable: Bool { tier != .readOnlyLarge }
    var allowsAICompletion: Bool { tier == .full }

    var previewBehavior: PreviewBehavior {
        switch tier {
        case .full: .live
        case .large: .manual
        case .readOnlyLarge: .disabled
        }
    }

    func openingAnyway() -> DocumentCapabilities {
        DocumentCapabilities(byteCount: byteCount, openedAnyway: true)
    }
}
```

- [ ] **Step 4: Make `DocumentSession` compute and own capabilities**

Add:

```swift
private(set) var capabilities: DocumentCapabilities
private var openedLargeFileAnyway = false

private static func fileByteCount(at url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

func openLargeFileAnyway() {
    guard capabilities.tier == .readOnlyLarge else { return }
    openedLargeFileAnyway = true
    capabilities = capabilities.openingAnyway()
}

private func refreshCapabilities() {
    capabilities = DocumentCapabilities(
        byteCount: Self.fileByteCount(at: fileURL),
        openedAnyway: openedLargeFileAnyway
    )
}
```

Initialize `capabilities` from `fileURL` before recovery handling. Call
`refreshCapabilities()` after adopting an external disk version and after
`fileWasMoved(to:)`.

- [ ] **Step 5: Run focused and full unit tests to verify GREEN**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/DocumentCapabilitiesTests
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test
```

Expected: capability tests pass and the existing 149 tests remain green.

- [ ] **Step 6: Commit the policy**

```bash
git add AshtynMD/Core/Documents/DocumentCapabilities.swift \
  AshtynMD/Core/Documents/DocumentSession.swift \
  AshtynMD/Tests/DocumentCapabilitiesTests.swift \
  AshtynMD.xcodeproj
git commit -m "feat: add large-file capability policy"
```

---

### Task 2: Enforce editing, preview, and AI capabilities

**Files:**

- Modify: `AshtynMD/Features/Editor/EditorTextView.swift:13-165`
- Modify: `AshtynMD/Features/Editor/EditorContainerView.swift:44-218`
- Modify: `AshtynMD/Features/AICompletion/AICompletionController.swift:86-96`
- Modify: `AshtynMD/Tests/AICompletionTests.swift:269-334`
- Modify: `AshtynMD/Tests/EditorCommandTests.swift`

**Interfaces:**

- Consumes: `DocumentSession.capabilities`
- Produces: `EditorTextView.Coordinator.applyCapabilities(to:)`
- Produces: manual large-file preview state and `Render Preview` action

- [ ] **Step 1: Add a failing AI eligibility test**

```swift
@Test func nilContextDoesNotConstructAProvider() {
    let controller = AICompletionController()
    var providerWasRequested = false
    controller.providerFactory = {
        providerWasRequested = true
        return MockProvider(behavior: .stream(["unused"], delayMilliseconds: 0))
    }

    controller.requestManually { nil }

    #expect(!providerWasRequested)
    #expect(controller.ghostText == nil)
}
```

- [ ] **Step 2: Add a failing AppKit editability test**

Create a file larger than 10 MB using `FileHandle.truncate(atOffset:)`, open a
`DocumentSession`, construct `PlainTextView`, and assert:

```swift
let coordinator = EditorTextView.Coordinator(session: session)
let textView = PlainTextView(frame: .zero)
coordinator.applyCapabilities(to: textView)
#expect(!textView.isEditable)

session.openLargeFileAnyway()
coordinator.applyCapabilities(to: textView)
#expect(textView.isEditable)
```

- [ ] **Step 3: Run the focused tests to verify RED**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/AICompletionControllerTests \
  -only-testing:AshtynMDTests/EditorCommandTests
```

Expected:

- AI test fails because `providerFactory` is called before the nil context is checked.
- Editor test fails because `applyCapabilities(to:)` does not exist.

- [ ] **Step 4: Reorder AI request construction**

In `AICompletionController.start`, evaluate the context before constructing a
provider:

```swift
guard let request = context() else { return }
guard let provider = providerFactory() else {
    AICompletionStatus.shared.lastError =
        "AI completion isn’t configured. Choose a provider in Settings."
    return
}
```

- [ ] **Step 5: Apply session capabilities to the AppKit editor**

Add:

```swift
func applyCapabilities(to textView: PlainTextView) {
    textView.isEditable = session.capabilities.isEditable
    textView.isSelectable = true
}
```

Call it from `makeNSView` after assigning the coordinator's text view and from
`updateNSView`. Guard `makeAIRequest` with:

```swift
guard session.capabilities.allowsAICompletion else {
    AICompletionStatus.shared.lastError =
        "AI completion is unavailable in large-file mode."
    return nil
}
```

When capabilities no longer allow AI, call `aiController.cancelAll()` and
clear any ghost text.

- [ ] **Step 6: Add the read-only banner and manual-preview state**

In `EditorContainerView`, add:

```swift
@State private var previewIsStale = true
@State private var isRenderingPreview = false
```

Display a large-file banner based on `session.capabilities.tier`:

```swift
case .large:
    banner(
        icon: "doc.badge.clock",
        color: .secondary,
        message: "Large-file mode: AI is off and Markdown preview updates manually."
    ) {
        if isMarkdown {
            Button("Render Preview") { scheduleRender(force: true) }
        }
    }
case .readOnlyLarge:
    banner(
        icon: "lock.doc",
        color: .orange,
        message: "This file is over 10 MB and opened read-only."
    ) {
        Button("Open Anyway") { session.openLargeFileAnyway() }
    }
```

Change rendering to:

```swift
private func scheduleRender(immediate: Bool = false, force: Bool = false) {
    renderTask?.cancel()
    guard isMarkdown, previewMode != .editor else { return }
    switch session.capabilities.previewBehavior {
    case .disabled:
        renderedHTML = ""
        previewIsStale = true
        return
    case .manual where !force:
        previewIsStale = true
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
        defer { isRenderingPreview = false }
        if !immediate && !force {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        let html = await Task.detached(priority: .userInitiated) {
            MarkdownHTMLRenderer(policy: policy).renderBody(text)
        }.value
        guard !Task.isCancelled else { return }
        renderedHTML = html
        previewIsStale = false
    }
}
```

After a successful forced render, set `previewIsStale = false`. Overlay stale
large-file preview content with a `Render Preview` button rather than
silently displaying obsolete output.

- [ ] **Step 7: Run focused tests and the full suite**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/AICompletionControllerTests \
  -only-testing:AshtynMDTests/EditorCommandTests
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test
```

Expected: all tests pass.

- [ ] **Step 8: Commit capability enforcement**

```bash
git add AshtynMD/Features/AICompletion/AICompletionController.swift \
  AshtynMD/Features/Editor/EditorTextView.swift \
  AshtynMD/Features/Editor/EditorContainerView.swift \
  AshtynMD/Tests/AICompletionTests.swift \
  AshtynMD/Tests/EditorCommandTests.swift
git commit -m "feat: enforce large-file safeguards"
```

---

### Task 3: Add conflict comparison and external-sync transition coverage

**Files:**

- Create: `AshtynMD/Features/Editor/ConflictComparisonView.swift`
- Create: `AshtynMD/Tests/ExternalSyncStressTests.swift`
- Modify: `AshtynMD/Core/Documents/DocumentSession.swift:214-286`
- Modify: `AshtynMD/Features/Editor/EditorContainerView.swift:221-260`
- Modify: `AshtynMD/Tests/SaveAndRecoveryTests.swift:154-204`

**Interfaces:**

- Produces: `ConflictComparison: Equatable, Sendable`
- Produces: `DocumentSession.conflictComparison() -> ConflictComparison?`
- Consumes: `LoadedTextFile.load(from:)`

- [ ] **Step 1: Write failing comparison tests**

```swift
@Test func comparisonReturnsEditorAndCurrentDiskText() throws {
    let (session, docURL, dir) = try makeSession()
    defer { try? FileManager.default.removeItem(at: dir) }
    session.updateText("local\n")
    try Data("remote\n".utf8).write(to: docURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)],
        ofItemAtPath: docURL.path
    )
    session.checkForExternalChanges()

    let comparison = session.conflictComparison()
    #expect(comparison?.editorText == "local\n")
    #expect(comparison?.diskText == "remote\n")
    #expect(session.text == "local\n")
}
```

- [ ] **Step 2: Write failing rapid-change tests**

Add this suite to `ExternalSyncStressTests.swift`:

```swift
import Foundation
import Testing
@testable import AshtynMD

@Suite("External sync stress")
@MainActor
struct ExternalSyncStressTests {
    private func makeSession()
        throws -> (session: DocumentSession, document: URL, directory: URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-sync-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let document = directory.appendingPathComponent("note.md")
        try Data("original\n".utf8).write(to: document)
        let store = RecoveryStore(
            directory: directory.appendingPathComponent("Recovery")
        )
        let session = DocumentSession(
            fileURL: document,
            file: try LoadedTextFile.load(from: document),
            recoveryStore: store
        )
        return (session, document, directory)
    }

    private func replace(
        _ url: URL,
        with text: String,
        generation: Int
    ) throws {
        try SaveCoordinator.writeAtomically(
            LoadedTextFile(
                text: text,
                encoding: .utf8(bom: false),
                lineEnding: .lf
            ),
            to: url
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(Double(generation + 1))],
            ofItemAtPath: url.path
        )
    }

    @Test func repeatedMetadataTouchesDoNotCreateAConflict() throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for generation in 0..<20 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(generation + 1))],
                ofItemAtPath: fixture.document.path
            )
            fixture.session.checkForExternalChanges()
            #expect(fixture.session.conflict == .none)
            #expect(fixture.session.text == "original\n")
        }
    }

    @Test func rapidAtomicReplacementsReloadTheNewestCleanVersion() throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for generation in 0..<20 {
            try replace(
                fixture.document,
                with: "remote \(generation)\n",
                generation: generation
            )
            fixture.session.checkForExternalChanges()
        }

        #expect(fixture.session.text == "remote 19\n")
        #expect(fixture.session.conflict == .none)
        #expect(!fixture.session.isDirty)
    }

    @Test func dirtySessionNeverOverwritesRapidExternalReplacement() async throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.session.updateText("local unsaved\n")

        for generation in 0..<20 {
            try replace(
                fixture.document,
                with: "remote \(generation)\n",
                generation: generation
            )
            fixture.session.checkForExternalChanges()
        }
        try await Task.sleep(for: DocumentSession.autosaveDelay + .milliseconds(200))

        #expect(fixture.session.conflict == .externalChange)
        #expect(fixture.session.text == "local unsaved\n")
        #expect(
            try String(contentsOf: fixture.document, encoding: .utf8)
                == "remote 19\n"
        )
    }

    @Test func deleteThenRecreateCanBeReconciled() throws {
        let fixture = try makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try FileManager.default.removeItem(at: fixture.document)
        fixture.session.checkForExternalChanges()
        #expect(fixture.session.conflict == .fileMissing)

        try replace(fixture.document, with: "recreated\n", generation: 1)
        fixture.session.checkForExternalChanges()
        #expect(fixture.session.conflict == .none)
        #expect(fixture.session.text == "recreated\n")
        #expect(!fixture.session.isDirty)
    }
}
```

The helper advances modification dates by one second per mutation so the
test does not depend on filesystem timestamp resolution.

- [ ] **Step 3: Run focused tests to verify RED**

Run:

```bash
xcodegen generate
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/DocumentSessionTests \
  -only-testing:AshtynMDTests/ExternalSyncStressTests
```

Expected: comparison test fails to compile; any transition failure reports the
specific unexpected `DocumentConflictState`.

- [ ] **Step 4: Add the comparison value and session loader**

```swift
struct ConflictComparison: Equatable, Sendable {
    let fileName: String
    let editorText: String
    let diskText: String
}
```

Add:

```swift
func conflictComparison() -> ConflictComparison? {
    guard conflict == .externalChange,
          let diskFile = try? LoadedTextFile.load(from: fileURL) else { return nil }
    return ConflictComparison(
        fileName: displayName,
        editorText: text,
        diskText: diskFile.text
    )
}
```

- [ ] **Step 5: Implement the native comparison sheet**

Create:

```swift
import SwiftUI

struct ConflictComparisonView: View {
    let comparison: ConflictComparison
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                pane(title: "Your Unsaved Version", text: comparison.editorText)
                pane(title: "Version on Disk", text: comparison.diskText)
            }
            Divider()
            HStack {
                Text(comparison.fileName)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func pane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextEditor(text: .constant(text))
                .font(.system(.body, design: .monospaced))
                .disabled(true)
                .accessibilityLabel(title)
        }
        .padding()
    }
}
```

In `EditorContainerView`:

```swift
@State private var comparison: ConflictComparison?
```

Add `Button("Compare") { comparison = session.conflictComparison() }` before
Use Disk and present:

```swift
.sheet(item: $comparison) { value in
    ConflictComparisonView(comparison: value)
}
```

Make `ConflictComparison` conform to `Identifiable` by adding
`let id = UUID()`. Keep exactly one Use Disk button.

- [ ] **Step 6: Run the transition suite and full unit suite**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/DocumentSessionTests \
  -only-testing:AshtynMDTests/ExternalSyncStressTests
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test
```

Expected: comparison and sync-transition tests pass with no silent overwrite.

- [ ] **Step 7: Commit conflict hardening**

```bash
git add AshtynMD/Core/Documents/DocumentSession.swift \
  AshtynMD/Features/Editor/ConflictComparisonView.swift \
  AshtynMD/Features/Editor/EditorContainerView.swift \
  AshtynMD/Tests/SaveAndRecoveryTests.swift \
  AshtynMD/Tests/ExternalSyncStressTests.swift \
  AshtynMD.xcodeproj
git commit -m "feat: add conflict comparison and sync stress coverage"
```

---

### Task 4: Make SQLite and library teardown explicit

**Files:**

- Modify: `AshtynMD/Core/Indexing/SQLiteDatabase.swift:4-121`
- Modify: `AshtynMD/Core/Indexing/LibraryStore.swift:36-52`
- Modify: `AshtynMD/Features/Library/AppModel.swift:94-134`
- Modify: `AshtynMD/Tests/LibraryStoreTests.swift`
- Modify: `AshtynMD/Tests/LibraryIndexerTests.swift`

**Interfaces:**

- Produces: `SQLiteDatabase.close() throws`
- Produces: `LibraryStore.close() throws`
- Produces: `AppModel.detachLibrary()` ordered indexer/store shutdown

- [ ] **Step 1: Add a failing idempotent-close test**

```swift
@Test func explicitCloseIsIdempotentAndRejectsNewStatements() throws {
    let dir = try makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let database = try SQLiteDatabase(path: dir.appendingPathComponent("db.sqlite").path)
    try database.executeScript("CREATE TABLE value (id INTEGER);")

    try database.close()
    try database.close()

    #expect(throws: SQLiteError.self) {
        try database.executeScript("SELECT 1;")
    }
}
```

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/LibraryStoreTests
```

Expected: compilation fails because `close()` does not exist.

- [ ] **Step 3: Implement close-aware SQLite access**

Add `SQLiteError.closed`, then:

```swift
func close() throws {
    guard let handle else { return }
    let result = sqlite3_close_v2(handle)
    guard result == SQLITE_OK else {
        throw SQLiteError.stepFailed(
            String(cString: sqlite3_errmsg(handle)),
            sql: "sqlite3_close_v2"
        )
    }
    self.handle = nil
}

deinit {
    try? close()
}
```

Add a private `openHandle()` that throws `.closed`; call it from
`executeScript` and `prepare`. `userVersion` already routes through
`query`/`executeScript`. Keep `lastInsertRowID` as a nonthrowing property, but
precondition that the handle is open because it is read only inside a live
transaction:

```swift
private func openHandle() throws -> OpaquePointer {
    guard let handle else { throw SQLiteError.closed }
    return handle
}

var lastInsertRowID: Int64 {
    precondition(handle != nil, "lastInsertRowID read after database close")
    return sqlite3_last_insert_rowid(handle)
}
```

- [ ] **Step 4: Expose actor-isolated store shutdown**

```swift
func close() throws {
    try database.close()
}
```

In `AppModel.detachLibrary`, capture both the old indexer and old store, clear
published references immediately, then order asynchronous cleanup:

```swift
Task {
    await oldIndexer?.stop()
    try? await oldStore?.close()
}
```

- [ ] **Step 5: Add deterministic async test-fixture cleanup**

In both store and indexer test files, add helpers with `do/catch` cleanup:

```swift
private func withTemporaryStore<T>(
    _ body: (URL, LibraryStore) async throws -> T
) async throws -> T {
    let directory = try makeStoreDirectory()
    let store = try makeStore(in: directory)
    do {
        let result = try await body(directory, store)
        try await store.close()
        try FileManager.default.removeItem(at: directory)
        return result
    } catch {
        try? await store.close()
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}
```

Use the `(URL, LibraryStore, LibraryIndexer)` helper below for every indexer
test, always calling `await indexer.stop()` before `store.close()`. Convert
each test in `LibraryStoreTests` and `LibraryIndexerTests` to use the helper
rather than deleting a directory in `defer`.

The indexer helper is:

```swift
private func withTemporaryLibrary<T>(
    _ body: (URL, LibraryStore, LibraryIndexer) async throws -> T
) async throws -> T {
    let fixture = try makeLibrary()
    do {
        let result = try await body(fixture.root, fixture.store, fixture.indexer)
        await fixture.indexer.stop()
        try await fixture.store.close()
        try FileManager.default.removeItem(at: fixture.root)
        return result
    } catch {
        await fixture.indexer.stop()
        try? await fixture.store.close()
        try? FileManager.default.removeItem(at: fixture.root)
        throw error
    }
}
```

- [ ] **Step 6: Run the suites and inspect output for diagnostics**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/LibraryStoreTests \
  -only-testing:AshtynMDTests/LibraryIndexerTests 2>&1 | tee /tmp/ashtyn-sqlite-tests.log
! rg "database integrity compromised|vnode unlinked while in use|invalidated open fd" \
  /tmp/ashtyn-sqlite-tests.log
```

Expected: tests pass and the diagnostic search returns no matches.

- [ ] **Step 7: Run the full test suite and commit**

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test
git add AshtynMD/Core/Indexing/SQLiteDatabase.swift \
  AshtynMD/Core/Indexing/LibraryStore.swift \
  AshtynMD/Features/Library/AppModel.swift \
  AshtynMD/Tests/LibraryStoreTests.swift \
  AshtynMD/Tests/LibraryIndexerTests.swift
git commit -m "fix: close library databases before teardown"
```

---

### Task 5: Add deterministic Debug-only UI-test bootstrap

**Files:**

- Create: `AshtynMD/App/UITestLaunchConfiguration.swift`
- Modify: `AshtynMD/Core/FileSystem/LibraryBookmarkStore.swift:8-19`
- Modify: `AshtynMD/Features/Library/AppModel.swift:66-117`
- Modify: `AshtynMD/Features/Editor/EditorTextView.swift:103-137`
- Modify: `AshtynMD/App/AshtynMDApp.swift:134-155`
- Create: `AshtynMD/UITests/UITestCase.swift`
- Modify: `project.yml`

**Interfaces:**

- Produces: `UITestLaunchConfiguration.current`
- Produces: `LibraryBookmarkStore.ResolvedRoot.unscoped(_:)`
- Produces: `UITestAIProvider`
- Produces: Xcode target `AshtynMDUITests`

- [ ] **Step 1: Add the UI-test target and an intentionally failing smoke test**

Add to `project.yml`:

```yaml
  AshtynMDUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: AshtynMD/UITests
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.kadeem.ashtynmd.uitests
        GENERATE_INFOPLIST_FILE: true
        TEST_TARGET_NAME: AshtynMD
    dependencies:
      - target: AshtynMD
```

Add `AshtynMDUITests` to the scheme's test targets. Create:

```swift
import XCTest

final class UITestBootstrapTests: XCTestCase {
    func testFixtureLibraryLaunchesWithoutAnOpenPanel() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-test-reset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixture Note"].waitForExistence(timeout: 10))
    }
}
```

- [ ] **Step 2: Regenerate and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDUITests/UITestBootstrapTests
```

Expected: the app opens onboarding because no fixture bootstrap exists.

- [ ] **Step 3: Implement the Debug-only launch parser and fixtures**

Wrap the complete file in `#if DEBUG`. Parse:

```swift
struct UITestLaunchConfiguration {
    let isEnabled: Bool
    let resetsLibrary: Bool
    let showsOnboarding: Bool
    let opensStandalone: Bool

    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AshtynMD-UITests", isDirectory: true)

    static var current: UITestLaunchConfiguration {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        return UITestLaunchConfiguration(
            isEnabled: arguments.contains("-ui-testing"),
            resetsLibrary: arguments.contains("-ui-test-reset"),
            showsOnboarding: arguments.contains("-ui-test-show-onboarding"),
            opensStandalone: arguments.contains("-ui-test-standalone")
        )
    }

    static func prepareFixtureLibrary() throws -> URL {
        let library = root.appendingPathComponent("Library", isDirectory: true)
        if current.resetsLibrary {
            let metadata = AppSupportPaths.libraryDirectory(forRoot: library)
            if FileManager.default.fileExists(atPath: metadata.path) {
                try FileManager.default.removeItem(at: metadata)
            }
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        if !FileManager.default.fileExists(atPath: library.path) {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent("Code", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent("Images", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("# Fixture Note\n\nSearchable alpha content.\n".utf8)
                .write(to: library.appendingPathComponent("Fixture Note.md"))
            try Data("let fixtureValue = 42\n".utf8)
                .write(to: library.appendingPathComponent("Code/sample.swift"))
            let largeFile = library.appendingPathComponent("Large.md")
            FileManager.default.createFile(atPath: largeFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: largeFile)
            try handle.write(contentsOf: Data("# Large Fixture\n".utf8))
            try handle.truncate(atOffset: 11 * 1024 * 1024)
            try handle.close()
            let pixel = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!
            try pixel.write(to: library.appendingPathComponent("Images/pixel.png"))
        }
        return library
    }

    static func standaloneFixtureURL() throws -> URL {
        _ = try prepareFixtureLibrary()
        let url = root.appendingPathComponent("Standalone.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data("# Standalone Fixture\n".utf8).write(to: url)
        }
        return url
    }
}
```

Use a fixed directory under `FileManager.default.temporaryDirectory` named
`AshtynMD-UITests`. On reset, remove only that exact child and recreate:

```text
Library/
  Fixture Note.md
  Large.md
  Code/
    sample.swift
  Images/
    pixel.png
Standalone.md
```

Write exact fixture contents:

```markdown
# Fixture Note

Searchable alpha content.
```

```swift
let fixtureValue = 42
```

- [ ] **Step 4: Add the unscoped root and AppModel test path**

Add to `LibraryBookmarkStore.ResolvedRoot`:

```swift
static func unscoped(_ url: URL) -> ResolvedRoot {
    ResolvedRoot(url: url, isAccessingSecurityScope: false)
}
```

Replace `AppModel.init` with:

```swift
init() {
    #if DEBUG
    let configuration = UITestLaunchConfiguration.current
    if configuration.isEnabled {
        do {
            let url = try UITestLaunchConfiguration.prepareFixtureLibrary()
            if !configuration.showsOnboarding {
                attachLibrary(.unscoped(url))
            }
        } catch {
            openError = "Couldn’t prepare UI fixtures: \(error.localizedDescription)"
        }
        return
    }
    #endif
    if let root = LibraryBookmarkStore.resolveKnownRoots().first {
        attachLibrary(root)
    }
}
```

Add this at the start of `chooseLibraryFolder()`:

```swift
#if DEBUG
if UITestLaunchConfiguration.current.isEnabled {
    do {
        attachLibrary(
            .unscoped(try UITestLaunchConfiguration.prepareFixtureLibrary())
        )
    } catch {
        openError = "Couldn’t prepare UI fixtures: \(error.localizedDescription)"
    }
    return
}
#endif
```

Release behavior remains unchanged because all bypass code is compiled only
under `#if DEBUG`.

- [ ] **Step 5: Add deterministic mock AI under Debug**

Add this below the launch configuration, inside the same `#if DEBUG`:

```swift
struct UITestAIProvider: AICompletionProvider {
    let id = AIProviderID.ollama

    func availableModels() async throws -> [AIModel] {
        [AIModel(id: "ui-test", displayName: "UI Test")]
    }

    func validateConfiguration() async throws {}

    func complete(
        _ request: AICompletionRequest
    ) -> AsyncThrowingStream<AICompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("fixtureSuggestion"))
            continuation.yield(.completed(nil))
            continuation.finish()
        }
    }
}
```

In `EditorTextView.Coordinator.init`:

```swift
init(session: DocumentSession) {
    self.session = session
    #if DEBUG
    if UITestLaunchConfiguration.current.isEnabled {
        aiController.providerFactory = { UITestAIProvider() }
    }
    #endif
}
```

No credential or consent state is changed.

- [ ] **Step 6: Route the standalone launch fixture**

Add to the end of `AppDelegate.applicationDidFinishLaunching`:

```swift
#if DEBUG
if UITestLaunchConfiguration.current.isEnabled,
   UITestLaunchConfiguration.current.opensStandalone,
   let url = try? UITestLaunchConfiguration.standaloneFixtureURL() {
    Task { @MainActor in
        await Task.yield()
        StandaloneOpenRequests.shared.requests.send(url)
    }
}
#endif
```

- [ ] **Step 7: Run the UI smoke test and Release compile guard**

Run:

```bash
xcodegen generate
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDUITests/UITestBootstrapTests
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Release \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: UI smoke test passes and Release compiles with all Debug-only
branches excluded.

- [ ] **Step 8: Commit the UI harness**

```bash
git add project.yml AshtynMD.xcodeproj \
  AshtynMD/App/UITestLaunchConfiguration.swift \
  AshtynMD/App/AshtynMDApp.swift \
  AshtynMD/Core/FileSystem/LibraryBookmarkStore.swift \
  AshtynMD/Features/Library/AppModel.swift \
  AshtynMD/Features/Editor/EditorTextView.swift \
  AshtynMD/UITests/UITestCase.swift
git commit -m "test: add deterministic macOS UI test harness"
```

---

### Task 6: Implement UI acceptance and accessibility coverage

**Files:**

- Create: `AshtynMD/App/AccessibilityIdentifiers.swift`
- Create: `AshtynMD/UITests/LibraryWorkflowUITests.swift`
- Create: `AshtynMD/UITests/EditorWorkflowUITests.swift`
- Create: `AshtynMD/UITests/KeyboardAccessibilityUITests.swift`
- Modify: `AshtynMD/Features/Library/LibraryWindowView.swift`
- Modify: `AshtynMD/Features/Editor/EditorContainerView.swift`
- Modify: `AshtynMD/Features/Library/StandaloneDocumentView.swift`
- Create: `docs/verification/phase-6-accessibility.md`

**Interfaces:**

- Produces: stable `AccessibilityID` string constants
- Consumes: Debug UI-test launch arguments from Task 5

- [ ] **Step 1: Define identifiers and write failing UI queries**

```swift
enum AccessibilityID {
    static let onboardingChooseFolder = "onboarding.choose-folder"
    static let sidebar = "library.sidebar"
    static let fileList = "library.file-list"
    static let searchField = "library.search-field"
    static let tabBar = "document.tab-bar"
    static let editor = "document.editor"
    static let modePicker = "markdown.mode-picker"
    static let renderPreview = "markdown.render-preview"
    static let openLargeFileAnyway = "document.open-anyway"
    static let conflictCompare = "conflict.compare"
}
```

Start each UI test with a query for one of these identifiers so the initial run
fails before identifiers are attached.

- [ ] **Step 2: Add the library workflow tests**

Create this shared base in `UITestCase.swift`:

```swift
import XCTest
@testable import AshtynMD

@MainActor
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func launch(
        reset: Bool = true,
        onboarding: Bool = false,
        standalone: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        if reset { app.launchArguments.append("-ui-test-reset") }
        if onboarding { app.launchArguments.append("-ui-test-show-onboarding") }
        if standalone { app.launchArguments.append("-ui-test-standalone") }
        app.launch()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @discardableResult
    func openFixtureNote() -> XCUIElement {
        let note = app.staticTexts["Fixture Note.md"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.click()
        let editor = element(AccessibilityID.editor)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return editor
    }

    func chooseSidebarItem(_ title: String) {
        let item = app.staticTexts[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.click()
    }

    func chooseFileMenuItem(_ title: String) {
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    func text(in editor: XCUIElement) -> String {
        editor.value as? String ?? ""
    }

    func waitForGhostText(in editor: XCUIElement) {
        let predicate = NSPredicate(
            format: "help == %@",
            "AI suggestion: fixtureSuggestion"
        )
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: editor
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed
        )
    }
}
```

Then implement `LibraryWorkflowUITests.swift`:

```swift
import XCTest
@testable import AshtynMD

@MainActor
final class LibraryWorkflowUITests: UITestCase {
    func testChooseAndReopenLibrary() {
        launch(reset: true, onboarding: true)
        let choose = element(AccessibilityID.onboardingChooseFolder)
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.click()
        XCTAssertTrue(app.staticTexts["Fixture Note.md"].waitForExistence(timeout: 10))

        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.staticTexts["Fixture Note.md"].waitForExistence(timeout: 10))
        XCTAssertFalse(element(AccessibilityID.onboardingChooseFolder).exists)
    }

    func testCreateNestedFolderAndMultipleFileTypes() {
        launch()
        chooseSidebarItem("Library")
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["New Folder"].waitForExistence(timeout: 10))
        chooseSidebarItem("New Folder")
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["New Folder"].waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Untitled.md"].waitForExistence(timeout: 10))
        chooseFileMenuItem("New Code File")
        let swiftItem = app.menuItems["Swift (.swift)"]
        XCTAssertTrue(swiftItem.waitForExistence(timeout: 5))
        swiftItem.click()
        XCTAssertTrue(app.staticTexts["Untitled.swift"].waitForExistence(timeout: 10))
    }

    func testOpenSeveralTabsAndRestoreState() {
        launch()
        openFixtureNote()
        chooseSidebarItem("Code")
        let source = app.staticTexts["sample.swift"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        XCTAssertTrue(app.staticTexts["Fixture Note.md"].exists)
        XCTAssertTrue(app.staticTexts["sample.swift"].exists)

        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.staticTexts["Fixture Note.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sample.swift"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows.staticTexts["sample.swift"].exists)
    }

    func testSearchFavoriteAndReopenRecentNote() {
        launch()
        let note = app.staticTexts["Fixture Note.md"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.rightClick()
        let favorite = app.menuItems["Add to Favorites"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.click()

        chooseSidebarItem("Favorites")
        XCTAssertTrue(app.staticTexts["Fixture Note.md"].waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = element(AccessibilityID.searchField)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("alpha")
        let result = app.staticTexts["Fixture Note.md"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()

        chooseSidebarItem("Recents")
        XCTAssertTrue(app.staticTexts["Fixture Note.md"].waitForExistence(timeout: 10))
    }
}
```

- [ ] **Step 3: Add editor workflow tests**

Add these two identifiers:

```swift
static let previewWebView = "markdown.preview"
static let largeFileMode = "document.large-file-mode"
```

Implement `EditorWorkflowUITests.swift`:

```swift
import AppKit
import XCTest
@testable import AshtynMD

@MainActor
final class EditorWorkflowUITests: UITestCase {
    func testPastePreservesCharactersAndLineBreaks() {
        launch()
        let editor = openFixtureNote()
        let pasted = "  alpha()\n\tbeta = \"🙂\"\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasted, forType: .string)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(text(in: editor), pasted)
    }

    func testMarkdownModeRestores() {
        launch()
        _ = openFixtureNote()
        let picker = element(AccessibilityID.modePicker)
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons["Preview"].click()
        XCTAssertTrue(element(AccessibilityID.previewWebView).waitForExistence(timeout: 10))

        app.terminate()
        launch(reset: false)
        _ = openFixtureNote()
        XCTAssertTrue(element(AccessibilityID.previewWebView).waitForExistence(timeout: 10))
        let restoredPicker = element(AccessibilityID.modePicker)
        XCTAssertEqual(restoredPicker.value as? String, "Preview")
    }

    func testImagePasteInsertsRelativeLink() {
        launch()
        let editor = openFixtureNote()
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AshtynMD-UITests/Library/Images/pixel.png")
        let imageData = try! Data(contentsOf: imageURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(imageData, forType: .png)
        editor.click()
        editor.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(text(in: editor).contains("](Assets/image-"))
    }

    func testMockGhostTextAcceptAndDismiss() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        editor.typeKey(" ", modifierFlags: [.control, .option])
        waitForGhostText(in: editor)
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(text(in: editor).hasSuffix("fixtureSuggestion"))

        editor.typeKey(" ", modifierFlags: [.control, .option])
        waitForGhostText(in: editor)
        editor.typeKey(.escape, modifierFlags: [])
        editor.typeKey(.tab, modifierFlags: [])
        let acceptedCount = text(in: editor)
            .components(separatedBy: "fixtureSuggestion").count - 1
        XCTAssertEqual(acceptedCount, 1)
    }

    func testStandaloneDocumentLaunch() {
        launch(standalone: true)
        XCTAssertTrue(app.windows.staticTexts["Standalone.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(AccessibilityID.editor).waitForExistence(timeout: 10))
    }

    func testLargeFileOpenAnywayKeepsAIDisabled() {
        launch()
        let large = app.staticTexts["Large.md"]
        XCTAssertTrue(large.waitForExistence(timeout: 10))
        large.click()
        let openAnyway = element(AccessibilityID.openLargeFileAnyway)
        XCTAssertTrue(openAnyway.waitForExistence(timeout: 10))
        openAnyway.click()
        XCTAssertTrue(element(AccessibilityID.largeFileMode).waitForExistence(timeout: 10))

        let editor = element(AccessibilityID.editor)
        editor.click()
        editor.typeKey(" ", modifierFlags: [.control, .option])
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(text(in: editor).contains("fixtureSuggestion"))
    }
}
```

In `PlainTextView.ghostText.didSet`, call:

```swift
setAccessibilityHelp(
    ghostText.map { "AI suggestion: \($0)" }
)
```

This makes streamed completion discoverable to VoiceOver and provides the
deterministic readiness signal used by the test. Keep the production document
string as the acceptance assertion.

- [ ] **Step 4: Add keyboard-only tests**

Implement `KeyboardAccessibilityUITests.swift`:

```swift
import XCTest
@testable import AshtynMD

@MainActor
final class KeyboardAccessibilityUITests: UITestCase {
    func testKeyboardSearchAndOpen() {
        launch()
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = element(AccessibilityID.searchField)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("alpha")
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element(AccessibilityID.editor).waitForExistence(timeout: 10))
    }

    func testKeyboardCreateSaveAndCloseTab() {
        launch()
        app.typeKey("n", modifierFlags: .command)
        let editor = element(AccessibilityID.editor)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("# Keyboard note")
        editor.typeKey("s", modifierFlags: .command)
        editor.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(editor.waitForExistence(timeout: 2))
    }

    func testKeyboardEditorCommands() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(.end, modifierFlags: [.command])
        editor.typeText("\nkeyboardLine")
        editor.typeKey("d", modifierFlags: [.command, .shift])
        XCTAssertTrue(text(in: editor).hasSuffix("keyboardLine\nkeyboardLine"))
        editor.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(text(in: editor).hasSuffix("keyboardLine\n// keyboardLine"))
        editor.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertFalse(text(in: editor).hasSuffix("// keyboardLine"))
    }

    func testKeyboardPreviewModeAndCompletionDismissal() {
        launch()
        let editor = openFixtureNote()
        editor.click()
        editor.typeKey(" ", modifierFlags: [.control, .option])
        waitForGhostText(in: editor)
        editor.typeKey(.escape, modifierFlags: [])
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(text(in: editor).contains("fixtureSuggestion"))

        editor.typeKey(.tab, modifierFlags: [.control])
        var reachedModePicker = false
        for _ in 0..<30 {
            if element(AccessibilityID.modePicker).hasKeyboardFocus {
                reachedModePicker = true
                break
            }
            app.typeKey(.tab, modifierFlags: [])
        }
        guard reachedModePicker else {
            XCTFail("Mode picker was not reachable through Full Keyboard Access")
            return
        }
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(element(AccessibilityID.previewWebView).waitForExistence(timeout: 10))
    }
}
```

The bounded focus loop keeps a focus-order regression from hanging the suite.

- [ ] **Step 5: Attach labels, identifiers, and focus semantics**

Attach identifiers at the owning view boundaries:

```swift
// Onboarding button
.accessibilityIdentifier(AccessibilityID.onboardingChooseFolder)

// SidebarView, FileListView, SearchColumnView TextField, and TabBarView
.accessibilityIdentifier(AccessibilityID.sidebar)
.accessibilityIdentifier(AccessibilityID.fileList)
.accessibilityIdentifier(AccessibilityID.searchField)
.accessibilityIdentifier(AccessibilityID.tabBar)

// EditorContainerView and MarkdownPreviewView
.accessibilityIdentifier(AccessibilityID.editor)
.accessibilityIdentifier(AccessibilityID.modePicker)
.accessibilityIdentifier(AccessibilityID.previewWebView)

// Capability and conflict controls
.accessibilityIdentifier(AccessibilityID.renderPreview)
.accessibilityIdentifier(AccessibilityID.openLargeFileAnyway)
.accessibilityIdentifier(AccessibilityID.largeFileMode)
.accessibilityIdentifier(AccessibilityID.conflictCompare)
```

Apply this to `FileRecordRow` after its existing padding:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel(record.name)
.accessibilityValue(
    "\(LanguageDefinition.definition(for: record.languageID).displayName), "
        + "\(record.modifiedAt.formatted(date: .abbreviated, time: .shortened)), "
        + (record.isFavorite ? "Favorite" : "Not favorite")
)
```

Keep existing human-readable labels and mark decorative images
`.accessibilityHidden(true)`. The combined row value exposes favorite state
without relying on the yellow star.

- [ ] **Step 6: Respect Reduce Transparency**

Add to `EditorContainerView` and `TabBarView`:

```swift
@Environment(\.accessibilityReduceTransparency)
private var reduceTransparency

@ViewBuilder
private var barBackground: some View {
    if reduceTransparency {
        Color(nsColor: .controlBackgroundColor)
    } else {
        Rectangle().fill(.bar)
    }
}
```

Replace each `.background(.bar)` with:

```swift
.background { barBackground }
```

Do not add animation to editor updates, cursor movement, highlighting, or
completion rendering.

- [ ] **Step 7: Run UI tests in light and dark appearances**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test \
  -only-testing:AshtynMDUITests
defaults write com.kadeem.ashtynmd AppleInterfaceStyle Dark
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test \
  -only-testing:AshtynMDUITests
defaults delete com.kadeem.ashtynmd AppleInterfaceStyle
```

If app-domain appearance does not affect the test host on this macOS version,
set `NSRequiresAquaSystemAppearance` through the Debug launch environment
instead. Restore the app-domain setting after the run.

- [ ] **Step 8: Perform and record the manual assistive-technology audit**

Record date, macOS build, app revision, and pass/fail evidence for:

- VoiceOver labels and reading order
- Full Keyboard Access traversal
- Increase Contrast
- Reduce Transparency
- Light appearance
- Dark appearance
- No color-only warnings or state
- No decorative motion in the editor input path

Write concrete observations and any fixed issues into
`docs/verification/phase-6-accessibility.md`; do not leave unchecked boxes in
the release revision.

- [ ] **Step 9: Run all tests and commit**

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test
git add AshtynMD/App/AccessibilityIdentifiers.swift \
  AshtynMD/Features/Library/LibraryWindowView.swift \
  AshtynMD/Features/Editor/EditorContainerView.swift \
  AshtynMD/Features/Library/StandaloneDocumentView.swift \
  AshtynMD/UITests \
  docs/verification/phase-6-accessibility.md
git commit -m "test: cover phase 6 UI and accessibility workflows"
```

---

### Task 7: Add formal performance and FSEvents stress gates

**Files:**

- Create: `AshtynMD/Tests/PerformanceGateTests.swift`
- Create: `script/performance_gate.sh`
- Modify: `AshtynMD/Tests/LibraryIndexerTests.swift`
- Modify: `AshtynMD/Core/Indexing/LibraryIndexer.swift` only if a failing gate proves an optimization is required

**Interfaces:**

- Produces: opt-in test suite `PerformanceGateTests`
- Produces: `script/performance_gate.sh`
- Consumes: `ASHTYN_PERFORMANCE_TESTS=1`

- [ ] **Step 1: Add the opt-in 10,000-file gate**

```swift
@Suite(
    "Phase 6 performance gates",
    .enabled(if: ProcessInfo.processInfo.environment["ASHTYN_PERFORMANCE_TESTS"] == "1")
)
struct PerformanceGateTests {
    private func makeLibrary()
        throws -> (root: URL, store: LibraryStore, indexer: LibraryIndexer)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashtyn-performance-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LibraryStore(
            databaseURL: root.appendingPathComponent(".performance.sqlite")
        )
        return (root, store, LibraryIndexer(root: root, store: store, onChange: {}))
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    @Test(.timeLimit(.minutes(2)))
    func tenThousandFileScanAndSearch() async throws {
        let fixture = try makeLibrary()
        do {
            for folder in 0..<100 {
                for file in 0..<100 {
                    try write(
                        "# Note \(folder)-\(file)\nneedle\(folder)x\(file)\n",
                        to: "folder\(folder)/note\(file).md",
                        in: fixture.root
                    )
                }
            }
            let scanStart = ContinuousClock.now
            try await fixture.indexer.fullScan()
            let scanDuration = ContinuousClock.now - scanStart
            #expect(try await fixture.store.fileCount() == 10_000)

            _ = try await fixture.store.search("needle73x42")
            let searchStart = ContinuousClock.now
            let hits = try await fixture.store.search("needle73x42")
            let searchDuration = ContinuousClock.now - searchStart
            #expect(hits.map(\.record.relativePath) == ["folder73/note42.md"])
            #expect(searchDuration < .milliseconds(200))
            print("10k scan: \(scanDuration); search: \(searchDuration)")

            await fixture.indexer.stop()
            try await fixture.store.close()
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            await fixture.indexer.stop()
            try? await fixture.store.close()
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
    }
}
```

- [ ] **Step 2: Add Markdown and syntax timing gates**

```swift
@Test func hundredKilobyteMarkdownRendersUnderTarget() {
    let block = "# Heading\n\nA paragraph with **strong**, [link](https://example.com), and `code`.\n\n"
    let repetitions = (100 * 1024 / block.utf8.count) + 1
    let markdown = String(repeating: block, count: repetitions)
    #expect(markdown.utf8.count >= 100 * 1024)

    let start = ContinuousClock.now
    _ = MarkdownHTMLRenderer(policy: .default).renderBody(markdown)
    let duration = ContinuousClock.now - start
    #expect(duration < .milliseconds(300), "render took \(duration)")
}

@Test func visibleIncrementalSyntaxUpdateStaysUnderTarget() async {
    let highlighter = SyntaxHighlighter()
    let source = String(repeating: "let value = 42\n", count: 500)
    await highlighter.setLanguage(.swift)
    await highlighter.replaceText(source)
    _ = await highlighter.highlights(in: NSRange(location: 0, length: 2_000))

    let insertion = "func added() { return }\n"
    let location = (source as NSString).length
    let updated = source + insertion
    let start = ContinuousClock.now
    await highlighter.applyEdit(
        newText: updated,
        editedRange: NSRange(location: location, length: (insertion as NSString).length),
        delta: (insertion as NSString).length,
        sequence: 1
    )
    _ = await highlighter.highlights(
        in: NSRange(location: max(0, location - 1_000), length: 1_000 + (insertion as NSString).length)
    )
    let duration = ContinuousClock.now - start
    #expect(duration < .milliseconds(100), "syntax update took \(duration)")
}
```

- [ ] **Step 3: Add the 2 MB editor and resident-memory record**

Add `import AppKit` and `import Darwin.Mach`, then:

```swift
private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

@Test @MainActor
func twoMegabyteEditorEditAndLayoutStayUnderTarget() {
    let before = residentBytes()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let scrollView = NSScrollView(frame: window.contentView!.bounds)
    let textView = PlainTextView(frame: scrollView.bounds)
    _ = textView.layoutManager
    scrollView.documentView = textView
    window.contentView = scrollView
    window.orderFront(nil)
    defer {
        window.orderOut(nil)
        window.close()
    }

    let text = String(repeating: "let value = 42\n", count: 140_000)
    #expect(text.utf8.count >= 2 * 1024 * 1024)
    textView.string = text
    if let container = textView.textContainer {
        textView.layoutManager?.ensureLayout(for: container)
    }

    let start = ContinuousClock.now
    textView.insertText(
        "x",
        replacementRange: NSRange(location: (text as NSString).length / 2, length: 0)
    )
    if let container = textView.textContainer {
        textView.layoutManager?.ensureLayout(for: container)
    }
    let duration = ContinuousClock.now - start
    let after = residentBytes()
    print("2 MB editor: \(duration); resident before=\(before), after=\(after)")
    #expect(duration < .milliseconds(100), "edit and layout took \(duration)")
}
```

The test records resident memory without inventing a product threshold.

- [ ] **Step 4: Add a real FSEvents coalescing test**

Add this helper and test to `LibraryIndexerTests`. The test uses the
`withTemporaryLibrary` cleanup helper from Task 4:

```swift
private func eventually(
    timeout: Duration = .seconds(10),
    _ predicate: @escaping () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting for FSEvents reconciliation")
}

@Test func coalescedFSEventsReconcileToFinalDiskState() async throws {
    try await withTemporaryLibrary { root, store, indexer in
        try await indexer.start()

        try write("old body\n", to: "one.md", in: root)
        try write("delete me\n", to: "two.md", in: root)
        try write("let kept = true\n", to: "keep.swift", in: root)
        try write("newest searchable body\n", to: "one.md", in: root)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: root.appendingPathComponent("one.md").path
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("one.md"),
            to: root.appendingPathComponent("notes/final.md")
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("two.md")
        )

        try await eventually {
            let paths = try await store.allFiles()
                .map(\.relativePath)
                .sorted()
            let hits = try await store.search("searchable")
                .map(\.record.relativePath)
            return paths == ["keep.swift", "notes/final.md"]
                && hits == ["notes/final.md"]
        }

        #expect(
            try await store.allFiles().map(\.relativePath).sorted()
                == ["keep.swift", "notes/final.md"]
        )
    }
}
```

This asserts the final store contains only the final paths and latest content,
regardless of how the filesystem batches the intermediate events.

- [ ] **Step 5: Create the performance command**

```bash
#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
cd "$REPO_ROOT"
xcodegen generate
ASHTYN_PERFORMANCE_TESTS=1 xcodebuild \
  -project AshtynMD.xcodeproj \
  -scheme AshtynMD \
  -configuration Debug \
  test -only-testing:AshtynMDTests/PerformanceGateTests
```

Make it executable.

- [ ] **Step 6: Run the gates and optimize only demonstrated failures**

Run:

```bash
./script/performance_gate.sh
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug \
  test -only-testing:AshtynMDTests/LibraryIndexerTests
```

If a threshold fails, keep the failing test unchanged, profile the measured
path, make the narrowest production optimization, and rerun until green.

- [ ] **Step 7: Commit the gates and any proven optimization**

```bash
git add AshtynMD/Tests/PerformanceGateTests.swift \
  AshtynMD/Tests/LibraryIndexerTests.swift \
  AshtynMD/Core/Indexing/LibraryIndexer.swift \
  script/performance_gate.sh \
  AshtynMD.xcodeproj
git commit -m "test: add phase 6 performance and FSEvents gates"
```

---

### Task 8: Configure and test universal Developer ID Release settings

**Files:**

- Create: `script/tests/release_config_test.sh`
- Modify: `project.yml`
- Modify: `.gitignore`

**Interfaces:**

- Produces: generated Release settings for universal Developer ID distribution

- [ ] **Step 1: Write the failing generated-settings test**

```bash
#!/bin/zsh
set -euo pipefail
REPO_ROOT="${0:A:h:h:h}"
cd "$REPO_ROOT"
xcodegen generate
SETTINGS="$(xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD \
  -configuration Release -showBuildSettings)"
grep -Fq 'ARCHS = arm64 x86_64' <<<"$SETTINGS"
grep -Fq 'ONLY_ACTIVE_ARCH = NO' <<<"$SETTINGS"
grep -Fq 'ENABLE_HARDENED_RUNTIME = YES' <<<"$SETTINGS"
grep -Fq 'DEVELOPMENT_TEAM = JUQMKZZ7TJ' <<<"$SETTINGS"
grep -Fq 'CODE_SIGN_IDENTITY = Developer ID Application' <<<"$SETTINGS"
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.kadeem.ashtynmd' <<<"$SETTINGS"
```

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
chmod +x script/tests/release_config_test.sh
./script/tests/release_config_test.sh
```

Expected: failure because Release currently inherits an empty team and ad-hoc
identity.

- [ ] **Step 3: Split Debug and Release signing settings**

Keep common Swift/deployment settings in `base`. Set:

```yaml
  configs:
    Debug:
      CODE_SIGN_STYLE: Manual
      CODE_SIGN_IDENTITY: "-"
      DEVELOPMENT_TEAM: ""
    Release:
      ARCHS: "arm64 x86_64"
      ONLY_ACTIVE_ARCH: false
      ENABLE_HARDENED_RUNTIME: true
      CODE_SIGN_STYLE: Manual
      CODE_SIGN_IDENTITY: "Developer ID Application"
      DEVELOPMENT_TEAM: JUQMKZZ7TJ
```

Do not add credentials or the notary password.

- [ ] **Step 4: Ignore generated release output**

Add:

```gitignore
dist/
```

- [ ] **Step 5: Regenerate, verify settings, and build unsigned universal**

Run:

```bash
./script/tests/release_config_test.sh
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD \
  -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Inspect the executable:

```bash
lipo -archs \
  ~/Library/Developer/Xcode/DerivedData/AshtynMD-*/Build/Products/Release/AshtynMD.app/Contents/MacOS/AshtynMD
```

Expected: output includes both `arm64` and `x86_64`.

- [ ] **Step 6: Commit Release configuration**

```bash
git add project.yml AshtynMD.xcodeproj .gitignore \
  script/tests/release_config_test.sh
git commit -m "build: configure universal Developer ID releases"
```

---

### Task 9: Build fail-closed release automation

**Files:**

- Create: `script/release_lib.sh`
- Create: `script/tests/release_lib_test.sh`
- Create: `script/release.sh`

**Interfaces:**

- Produces: `version_from_project`, `require_clean_tree`, `require_architectures`
- Produces: `./script/release.sh`
- Consumes: Keychain identity and `AshtynMD-notary` profile

- [ ] **Step 1: Write failing pure helper tests**

```bash
#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR:h}/release_lib.sh"

assert_equal() {
  [[ "$1" == "$2" ]] || {
    print -u2 "expected '$2', got '$1'"
    return 1
  }
}

assert_equal "$(version_from_project "${SCRIPT_DIR:h:h}/project.yml")" "0.1.0"
require_architectures "arm64 x86_64"
require_architectures "x86_64 arm64"
if require_architectures "arm64"; then
  print -u2 "single-architecture input was accepted"
  exit 1
fi
```

- [ ] **Step 2: Run helper tests to verify RED**

Run:

```bash
chmod +x script/tests/release_lib_test.sh
./script/tests/release_lib_test.sh
```

Expected: failure because `release_lib.sh` does not exist.

- [ ] **Step 3: Implement pure release helpers**

Create `script/release_lib.sh` with:

```bash
#!/bin/zsh

version_from_project() {
  awk '/CFBundleShortVersionString:/ { gsub(/"/, "", $2); print $2; exit }' "$1"
}

require_architectures() {
  local architectures=" $1 "
  [[ "$architectures" == *" arm64 "* && "$architectures" == *" x86_64 "* ]]
}

require_clean_tree() {
  [[ -z "$(git status --porcelain)" ]] || {
    print -u2 "Release requires a clean Git worktree."
    return 1
  }
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    print -u2 "Required command is unavailable: $1"
    return 1
  }
}

require_identity() {
  local identity="$1"
  local keychain="$2"
  security find-identity -v -p codesigning "$keychain" |
    grep -Fq "\"${identity}\"" || {
      print -u2 "Developer ID identity is unavailable: ${identity}"
      return 1
    }
}

require_notary_profile() {
  local profile="$1"
  local keychain="$2"
  xcrun notarytool history \
    --keychain-profile "$profile" \
    --keychain "$keychain" >/dev/null || {
      print -u2 "Notary profile could not be validated: ${profile}"
      return 1
    }
}

json_field() {
  plutil -extract "$2" raw -o - "$1"
}

require_accepted_notarization() {
  local json="$1"
  local artifact="$2"
  local profile="$3"
  local keychain="$4"
  local log="$5"
  local status
  local submission_id
  status="$(json_field "$json" status 2>/dev/null || true)"
  submission_id="$(json_field "$json" id 2>/dev/null || true)"
  if [[ "$status" == "Accepted" ]]; then
    print "$submission_id"
    return 0
  fi
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" "$log" \
      --keychain-profile "$profile" \
      --keychain "$keychain" || true
  fi
  print -u2 "Notarization failed for ${artifact}: status=${status:-unknown}"
  return 1
}
```

- [ ] **Step 4: Run helper tests to verify GREEN**

Run:

```bash
./script/tests/release_lib_test.sh
```

Expected: all helper assertions pass.

- [ ] **Step 5: Implement release preflight and quality gates**

Start `script/release.sh` with:

```bash
#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
source "$SCRIPT_DIR/release_lib.sh"
cd "$REPO_ROOT"

PRODUCT_NAME="AshtynMD"
DISPLAY_NAME="Ashtyn MD"
TEAM_ID="JUQMKZZ7TJ"
IDENTITY="Developer ID Application: Kadeem Jeffery (JUQMKZZ7TJ)"
NOTARY_PROFILE="AshtynMD-notary"
LOGIN_KEYCHAIN="$(security login-keychain -d user | tr -d ' \"')"
VERSION="$(version_from_project "$REPO_ROOT/project.yml")"
```

Require a clean worktree, the expected version, XcodeGen, Xcode tools,
Developer ID identity, and validated notary profile. Run:

```bash
xcodegen generate
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD \
  -configuration Debug test
./script/performance_gate.sh
```

- [ ] **Step 6: Implement archive, export, and app verification**

Use `mktemp -d` for staging and create `ExportOptions.plist` with `plutil`,
setting `method=developer-id`, `signingStyle=manual`, and
`teamID=JUQMKZZ7TJ`. Archive with:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" archive
```

Export with `xcodebuild -exportArchive`. Verify:

```bash
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$PRODUCT_NAME")"
require_architectures "$APP_ARCHS"
codesign -dvvv --entitlements :- "$APP_PATH"
```

Require the `runtime` flag, sandbox entitlement, user-selected read/write,
app-scoped bookmarks, and network-client entitlement.

- [ ] **Step 7: Implement app notarization and stapling**

Create a ZIP with:

```bash
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
```

Submit with:

```bash
xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --keychain "$LOGIN_KEYCHAIN" \
  --wait --output-format json > "$APP_NOTARY_JSON"
```

Extract and require `status == Accepted`. On failure, download the log using
the submission ID before exiting. Then:

```bash
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl -a -vv --type execute "$APP_PATH"
```

- [ ] **Step 8: Implement DMG creation, signing, notarization, and mounted validation**

Create a packaging directory containing the stapled app and an Applications
symlink. Build:

```bash
hdiutil create -volname "Ashtyn MD" -srcfolder "$DMG_ROOT" \
  -ov -format UDZO "$DMG_PATH"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
```

Submit the DMG with the same profile, require Accepted, then:

```bash
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
```

Mount read-only at an explicit `mktemp -d` mount point. Verify the contained
app's signature, architectures, stapled ticket, and Gatekeeper assessment.
Detach the exact mounted device in a trap.

- [ ] **Step 9: Preserve artifact, evidence, and checksum**

Move only the accepted DMG and nonsecret notarization JSON/logs into:

```text
dist/
  AshtynMD-0.1.0.dmg
  AshtynMD-0.1.0.dmg.sha256
  notarization/
```

Create the checksum from inside `dist` so the checksum file contains a relative
filename:

```bash
(cd "$DIST_DIR" && shasum -a 256 "AshtynMD-${VERSION}.dmg" \
  > "AshtynMD-${VERSION}.dmg.sha256")
```

Print the source commit, artifact path, checksum, app submission ID, and DMG
submission ID. Never print credentials.

- [ ] **Step 10: Syntax-check and dry-run preflight**

Run:

```bash
chmod +x script/release.sh script/release_lib.sh
zsh -n script/release.sh script/release_lib.sh
./script/tests/release_lib_test.sh
./script/tests/release_config_test.sh
```

Temporarily invoke the release script with a deliberately dirty ignored-free
test file and confirm it exits before building; remove only that exact test
file afterward.

- [ ] **Step 11: Commit release automation**

```bash
git add script/release.sh script/release_lib.sh \
  script/tests/release_lib_test.sh
git commit -m "build: automate signed notarized DMG releases"
```

---

### Task 10: Run the complete Phase 6 release gate

**Files:**

- Modify: `HANDOFF.md`
- Produce ignored artifacts under: `dist/`

**Interfaces:**

- Consumes: all prior tasks and Keychain signing/notarization assets
- Produces: `dist/AshtynMD-0.1.0.dmg`
- Produces: `dist/AshtynMD-0.1.0.dmg.sha256`

- [ ] **Step 1: Verify source state and regenerate**

Run:

```bash
git status --short --branch
xcodegen generate
git diff --exit-code
```

Expected: clean source revision and no uncommitted XcodeGen drift.

- [ ] **Step 2: Run the complete Debug suite and capture the test count**

Run:

```bash
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD \
  -configuration Debug test 2>&1 | tee /tmp/ashtyn-phase6-tests.log
rg "Test run with .* tests in .* suites passed|TEST SUCCEEDED" \
  /tmp/ashtyn-phase6-tests.log
! rg "database integrity compromised|vnode unlinked while in use|invalidated open fd" \
  /tmp/ashtyn-phase6-tests.log
```

Expected: unit and UI tests pass and SQLite diagnostics are absent.

- [ ] **Step 3: Run performance and stress gates**

Run:

```bash
./script/performance_gate.sh
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD \
  -configuration Debug test \
  -only-testing:AshtynMDTests/ExternalSyncStressTests \
  -only-testing:AshtynMDTests/LibraryIndexerTests
```

Record timings and resident-memory evidence in the accessibility/verification
document or a sibling `docs/verification/phase-6-performance.md` if the output
needs more than one page.

- [ ] **Step 4: Confirm the accessibility audit has no open failures**

Read `docs/verification/phase-6-accessibility.md`. Resolve every failed or
unchecked item before proceeding. Rerun the relevant UI test after each fix.

- [ ] **Step 5: Commit final source fixes and verification records**

Run the full Debug suite again immediately before the commit, then:

```bash
git add AshtynMD project.yml AshtynMD.xcodeproj script docs/verification HANDOFF.md
git commit -m "chore: complete phase 6 hardening gates"
```

Skip this commit if there are no source or documentation changes.

- [ ] **Step 6: Produce the signed, notarized release**

Run from a clean revision:

```bash
./script/release.sh
```

Do not interrupt `notarytool --wait`. If Apple rejects either submission,
preserve its JSON and log, fix only the reported issue, rerun all affected
verification, commit the fix, and restart the release from a clean revision.

- [ ] **Step 7: Independently re-verify the final DMG**

Run:

```bash
shasum -a 256 -c dist/AshtynMD-0.1.0.dmg.sha256
xcrun stapler validate dist/AshtynMD-0.1.0.dmg
spctl -a -vv --type open --context context:primary-signature \
  dist/AshtynMD-0.1.0.dmg
```

Mount the DMG read-only and independently run:

```bash
codesign --verify --deep --strict --verbose=2 "/Volumes/Ashtyn MD/Ashtyn MD.app"
spctl -a -vv --type execute "/Volumes/Ashtyn MD/Ashtyn MD.app"
xcrun stapler validate "/Volumes/Ashtyn MD/Ashtyn MD.app"
lipo -archs "/Volumes/Ashtyn MD/Ashtyn MD.app/Contents/MacOS/AshtynMD"
```

Expected: valid Developer ID signature, accepted Gatekeeper assessment, valid
stapled ticket, and both `arm64` and `x86_64`.

- [ ] **Step 8: Update the handoff status**

Change Phase 6 to complete and record:

- final source commit
- total unit/UI test count
- performance measurements
- accessibility audit date
- app and DMG notarization submission IDs
- DMG SHA-256
- artifact path

Do not record the app-specific password, Keychain item contents, or private-key
material.

- [ ] **Step 9: Commit the final handoff**

```bash
git add HANDOFF.md docs/verification
git commit -m "docs: record phase 6 release verification"
git status --short --branch
```

Expected: clean worktree; `dist/` remains ignored and preserved locally.

---

## Plan self-review checklist

- Every approved runtime, UI, accessibility, performance, sync, signing,
  notarization, DMG, and Gatekeeper requirement maps to a task above.
- Every production behavior task begins with a focused failing test.
- Configuration and packaging tasks begin with executable validation scripts.
- Type names are consistent: `DocumentCapabilities`, `ConflictComparison`,
  `UITestLaunchConfiguration`, `AccessibilityID`.
- Release credentials are referenced only by identity/profile name.
- `project.yml` remains authoritative and every source/target addition is
  followed by XcodeGen regeneration.
- No phase completion claim occurs before the final mounted-DMG verification.
