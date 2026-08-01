# Ashtyn MD

Ashtyn MD is a native macOS notes-first Markdown and code editor with a Bear-like Markdown experience: inline styling, nested tags, Inbox capture, and plain files on disk.

The app combines a SwiftUI library shell with an AppKit editor. Markdown files get rich inline typography while code files keep tree-sitter syntax highlighting, and the SQLite/FTS5 index can be rebuilt from the filesystem at any time.

Maintained by [Kadeem Jeffery](https://github.com/kadeemj).

## Highlights

- Plain Markdown files remain the source of truth; the local index is disposable.
- Inline Markdown styling for headings, emphasis, code spans, lists, quotes, tasks, and tags.
- Bear-style organization with nested `#tags`, folders, Inbox capture, pinned notes, recents, archive, and trash.
- Markdown preview with safe local asset handling and undoable task-checkbox edits.
- Code editing with tree-sitter highlighting, language detection, editor profiles, themes, and AI completion.
- Native macOS behaviors including autosave, recovery snapshots, conflict handling, keyboard commands, and Finder integration.

## Project status

The `phase-7` branch is the current development branch. Gates 0–3 of the Bear-like notes work are complete (22 of 32 planned tasks). Gate 4 is next and covers on-disk lifecycle management, title-to-filename synchronization, and tag rewriting; Gates 5–6 cover links, search, export, coverage, and documentation.

The current verification baseline includes passing unit tests and the 10,000-file performance gate. XCUITests still require a macOS automation-permission pass before they can be rerun reliably.

## Requirements

- macOS 14 or later
- Xcode with Swift 6 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build and test

`project.yml` is the source of truth for the Xcode project. Regenerate the project after adding or removing source files:

```bash
xcodegen generate
xcodebuild -project AshtynMD.xcodeproj \
  -scheme AshtynMD \
  -configuration Debug \
  build
```

Run the unit tests:

```bash
xcodebuild -project AshtynMD.xcodeproj \
  -scheme AshtynMD \
  -configuration Debug \
  test \
  -only-testing:AshtynMDTests
```

Run the opt-in performance gates:

```bash
./script/performance_gate.sh
```

## Architecture

```text
AshtynMD/
├── App/                 App lifecycle, menus, and accessibility identifiers
├── Core/                Documents, filesystem, indexing, languages, security, themes
├── Features/            Library, editor, Markdown preview, AI completion, settings
├── Tests/               Swift Testing unit and performance suites
└── UITests/             macOS workflow and keyboard UI tests
Vendor/                  Vendored tree-sitter grammars with external scanners
project.yml              XcodeGen project manifest
```

The main dependencies are SwiftUI, AppKit, SQLite/FTS5, tree-sitter, and swift-markdown. There are no third-party runtime services required for local notes and code editing.
