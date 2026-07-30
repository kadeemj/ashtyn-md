# Ashtyn MD — Implementation Handoff

**Date:** 2026-07-30
**State:** All 6 phases complete and verified. A signed, universal, Hardened-Runtime `.dmg` builds via `script/release.sh`; notarization is the only step needing operator credentials.
**Repo:** `/Users/kadeem/Development/ashtyn_md` — git initialized, **no commits yet** (nothing was ever committed; make an initial commit first thing if you want history).

## What this is

A native macOS 14+ notes-first Markdown/code editor per the full product spec (the spec document is the source of truth for requirements — it defines the three-column library UI, per-language editor profiles, SQLite/FTS5 search, Markdown preview, and provider-neutral AI completion). Swift 6 strict concurrency, SwiftUI shell + AppKit editor, bundle id `com.kadeem.ashtynmd`.

## Build and test

```bash
brew install xcodegen               # already installed on this machine
xcodegen generate                   # regenerate AshtynMD.xcodeproj from project.yml
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug build
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test
```

- **`project.yml` is the source of truth** — never edit the `.xcodeproj` directly, and **rerun `xcodegen generate` after adding/removing source files** (forgetting this causes "cannot find X in scope" errors for new files).
- Tests: **149 tests in 20 suites, all passing** (Swift Testing, hosted in the app). Suite runs in ~3 s.
- Toolchain verified: Xcode 26.6, Swift 6.3.3, Apple silicon.
- Local dev signing is ad-hoc (`CODE_SIGN_IDENTITY: "-"`, manual style). Hardened Runtime is enabled for Release config only.
- App Sandbox is ON with user-selected read-write + security-scoped bookmarks.

## Source layout (matches the spec's tree)

```
AshtynMD/
  App/AshtynMDApp.swift            @main, all menu commands, AppDelegate (open-file events, termination save)
  Core/
    Documents/   TextFileFormat (encoding/BOM/line endings), SaveCoordinator (atomic writes),
                 DocumentSession (autosave/recovery/conflicts), RecoveryStore, SessionRegistry
    FileSystem/  AppSupportPaths, LibraryBookmarkStore (security-scoped bookmarks),
                 FSEventsWatcher, FileOperations (trash/rename/move/duplicate)
    Indexing/    SQLiteDatabase (raw sqlite3 wrapper), LibraryStore (actor, FTS5, schema v1),
                 LibraryIndexer (actor, lazy scan + FSEvents reconcile, move detection by inode)
    Languages/   LanguageID/LanguageDefinition, LanguageDetector (override→ext→shebang→content),
                 GrammarRegistry (tree-sitter configs + capture mapping), SyntaxHighlighter (actor)
    Security/    CredentialStore (Keychain generic passwords)
    Themes/      EditorProfile + SyntaxToken + CodableColor, EditorTheme (System/Light/Dark),
                 EditorProfilesStore (persisted editor-profiles-v1.json)
  Features/
    Library/     AppModel (tabs, sidebar, search, file ops, UI-state persistence),
                 LibraryBrowser (folder tree enumeration), LibraryWindowView (3-column UI),
                 StandaloneDocumentView (Finder-opened files outside a library)
    Editor/      PlainTextView (all editing commands/pairing/markdown helpers/ghost text),
                 EditorTextView (NSViewRepresentable + Coordinator: highlighting, view state,
                 AI wiring, source-edit routing), LineNumberRulerView, OfflineCompletion,
                 EditorContainerView (banners, preview modes, status bar, image insertion)
    MarkdownPreview/  MarkdownHTMLRenderer (safe HTML over swift-markdown AST), MarkdownTasks
                 (checkbox↔source mapping), MarkdownPreviewView (WKWebView + JS bridge),
                 PreviewAssetSchemeHandler (restricted ashtyn-file: scheme), AssetStore
    AICompletion/ AITypes (spec interfaces), StreamDecoders (SSE/NDJSON), AIProviders
                 (OpenAI Responses / Anthropic Messages / Ollama chat, all streaming),
                 AISettings (no secrets), AICompletionController (ghost text lifecycle),
    Settings/    SettingsView (Editor tab: profiles/themes), AISettingsView (keys, models, consent)
  Tests/         149 tests: format/save/recovery/session-conflicts, store/indexer (incl. 1,500-file
                 perf test w/ <200 ms search), highlighter fixtures for all 10 grammars,
                 editor commands, markdown renderer/task fixtures, SSE/provider mapping,
                 controller-with-mock-provider, Keychain no-leak
Vendor/          tree-sitter-yaml, -python, -javascript, -css (see "Dependency quirks")
project.yml      XcodeGen manifest (packages pinned here; Package.resolved pins exact revisions)
```

## Phase status vs. spec exit gates

| Phase | Status | Exit-gate evidence |
|---|---|---|
| 1. Shell + document core | ✅ | Open/edit/autosave (700 ms)/recover (2 s snapshots) tested; Finder open smoke-tested; encoding/BOM/CRLF byte-exact round-trips tested |
| 2. Library + search | ✅ | SQLite schema v1 + FTS5 + FSEvents; tabs/recents/favorites/trash/drag-move; state restore; 1,500-file scan + <200 ms search test (10k claim extrapolated, not yet formally profiled) |
| 3. Editor + languages | ✅ | All 10 grammars load + per-language highlight fixtures; incremental edits w/ emoji ranges; every line command tested incl. boundaries; pairing/skip-over; ⌘L/⇧⌘D/⇧⌘K/⌥⌘↑↓/⌘//⌃Space wired; profiles+themes+settings UI; language override menu |
| 4. Markdown preview | ✅ | GFM fixtures (tables w/ alignment, tasks, strikethrough, autolinks); raw HTML escaped by default w/ per-library opt-in (View menu); remote images blocked; task checkbox → undoable source edit; Assets image paste/drop w/ relative links; per-file mode + scroll persistence; 250 ms debounced re-render |
| 5. AI completion | ✅ | Three streaming adapters + model discovery + connection test; Keychain-only keys (no-leak test); one-time cloud consent dialog; ghost text (Tab accept / Esc dismiss, never auto-inserted); 800 ms auto-trigger off by default; provider in status bar; mock-provider tests for streamed/cancelled/failed/accepted |
| 6. Hardening + distribution | ✅ | 15 XCUITests (editor/library/keyboard/bootstrap); large-file tiers via `DocumentCapabilities`; external-sync stress + conflict comparison; `script/release.sh` produces a verified signed universal .dmg (archive → export → verify → notarize → staple) |

## Releasing

```bash
script/release.sh                      # full pipeline (requires a notary profile)
script/release.sh --skip-notarization  # signed + verified .dmg, no notarization
```

Output: `build/release/AshtynMD-<version>.dmg` (gitignored). Verified locally:
universal (`x86_64 arm64`), Hardened Runtime, Developer ID `JUQMKZZ7TJ`, all four
entitlements present, `codesign --verify --deep --strict` clean, 5.9 MB.

**Notarization needs a one-time credential setup** (not yet done on this machine):

```bash
xcrun notarytool store-credentials AshtynMD \
  --apple-id <apple-id> --team-id JUQMKZZ7TJ --password <app-specific-password>
```

Override the profile name with `ASHTYN_NOTARY_PROFILE`, the output directory with
`ASHTYN_OUTPUT_DIR`. `script/release_lib.sh` holds the reusable helpers; the three
`script/tests/release_*.sh` scripts cover version parsing, architecture assertions,
identity resolution, and temp-file purging.

### Signing pitfalls that already bit us

- **Never sign with `codesign --deep`.** Apple treats `--deep` as a diagnostic
  aid, not a distribution signing mode. Let Xcode's archive+export sign nested
  code inside-out (this app embeds 12 tree-sitter resource bundles).
- **Stale `*.cstemp` files poison a bundle permanently.** `codesign` writes each
  signature to `<name>.cstemp` then renames it. If a run is interrupted, killed,
  or races another `codesign`, the partial file survives inside the bundle, and
  every later signing/verification pass walks into it and fails with
  `invalid or unsupported format for signature` / `main executable failed strict
  validation`, naming `AshtynMD.cstemp` as the bad subcomponent. Deleting the
  stray file is the whole fix; `purge_signing_temporaries` does it before each
  signing stage, and `release_signing_test.sh` guards the behavior.
- **Resolve the identity to its 40-char SHA-1, not a display-name fragment.**
  Parsing `security find-identity` with zsh word-splitting yielded `)`, which
  xcodebuild reported as the misleading
  `No certificate for team 'JUQMKZZ7TJ' matching ')' found`.
- **Keep `--timestamp`.** A secure timestamp is mandatory for notarization, so
  never substitute `--timestamp=none`.

### Remaining distribution follow-ups

1. Run the pipeline once with real notary credentials and confirm
   `spctl --assess` passes on a second Mac.
2. Optional: a self-updater, which the spec defers until after the first
   notarized beta.

## Dependency quirks (important)

- **Grammar packages with external scanners are vendored** in `Vendor/` (yaml, python, javascript, css). Upstream `Package.swift` files probe `FileManager.fileExists(atPath: "src/scanner.c")` with a CWD-relative path, which silently drops `scanner.c` under Xcode → undefined `_tree_sitter_*_external_scanner_*` symbols at link. The vendored copies list sources statically (MIT licenses copied along). If you bump grammar versions, re-vendor or check upstream fixed their manifests.
- **Swift grammar** is `alex-pinkus/tree-sitter-swift` pinned to **revision `31d17fe…` = tag `0.7.3-with-generated-files`** — plain tags don't contain the generated `parser.c`.
- **SwiftTreeSitter query-bundle lookup is bypassed**: its heuristic breaks under hosted tests (looks in the test bundle's parent). `GrammarRegistry.queriesURL(forBundleNamed:)` resolves `TreeSitter<Name>_TreeSitter<Name>.bundle/Contents/Resources/queries` against the app bundle directly.
- **swift-markdown pinned exactly 0.8.0** per spec. Notes: it does NOT autolink bare URLs (renderer adds regex-based linkification in `visitText`); it applies smart punctuation to quotes; list items wrap content in `Paragraph` (renderer unwraps the leading paragraph for GitHub-style tight lists).

## Bugs found and fixed (don't reintroduce)

- `"\r\n"` is ONE Swift `Character` — `text.contains("\r")` misses CRLF entirely. `LineEnding.normalizeToLF` checks `unicodeScalars`.
- `URL.resourceValues` serves **cached** values → stale external-change/missing-file detection. `SaveCoordinator.diskState` uses `FileManager.attributesOfItem` instead (also builds the `device:inode` resource id used for move detection).
- Conflict resolutions ("Keep Mine", "Restore") must bypass `save()`'s external-change pre-check via the private `performWrite()` — otherwise they re-flag the conflict and never write.
- `NSTextView.undoManager` is nil without a window — editor tests host the view in an `NSWindow`.
- Actor init can't call isolated methods (LibraryStore migration is a `static func` taking the db).

## Architecture decisions worth knowing

- **No third-party runtime deps beyond tree-sitter + swift-markdown.** SQLite is the system libsqlite3 via a ~150-line wrapper owned by the `LibraryStore` actor. FSEvents used directly.
- **DocumentSession** is the per-file editing authority (`@MainActor @Observable`): normalized-`\n` text in memory; byte-faithful encode on save (encoding + BOM + CRLF preserved); autosave 700 ms; recovery snapshot every 2 s while dirty, cleared only after verified save; conflicts never overwritten silently.
- **Highlighting**: `SyntaxHighlighter` actor per editor; `NSTextStorageDelegate` feeds incremental `InputEdit`s (UTF-16 byte offsets ×2, zero Points) with an edit-sequence guard (stale drop, gap → full reparse). Colors applied as TextKit-1 **temporary attributes** for the visible range ±2000 chars; TextKit 1 is deliberately forced by touching `layoutManager` at view creation.
- **Preview security model**: renderer escapes everything by default; images only via relative paths resolved against a base URL on the custom `ashtyn-file:` scheme whose handler canonicalizes paths and confines them to the library root, image extensions only. Web links open in browser via navigation-policy cancel; relative doc links route back into the app. Task checkboxes post JS messages → `MarkdownTasks.toggleEdit` → `session.performSourceEdit` → through the live editor's undo stack (editor stays mounted zero-sized in Preview mode exactly for this).
- **AI**: providers are stateless `Sendable` structs; one shared byte-accurate line streamer (SSE blank-line delimiters preserved — don't switch to `bytes.lines`); event mapping is in pure static `actions(...)` funcs (unit-tested). `AICompletionController` is per-editor, owns ghost lifecycle; `AICompletionStatus.shared` feeds the status bar. Context: 16k prefix / 8k suffix / 4k head, boundaries snapped to composed character sequences, output capped 4000 chars.
- **Per-library app state** (tabs, selection, raw-HTML opt-in, per-file cursor/scroll/preview-mode) lives in `library.sqlite` under `~/Library/Application Support/Ashtyn MD/Libraries/<sha256-of-root>/`. Editor profiles + theme in `editor-profiles-v1.json`. AI config in UserDefaults (never secrets). Keys in Keychain service `com.kadeem.ashtynmd.ai-credentials`.

## Known minor gaps / deviations (beyond Phase 6 items)

- Ghost text draws as an overlay (up to 4 lines, no reflow of following text) — functional, not Xcode-grade.
- Phase-1 folder sidebar tree still comes from direct FS enumeration (`LibraryBrowser.folderTree`), refreshed on index changes; file *lists* come from the store. Fine at spec scale, but the tree could move to the index later.
- Auto-trigger timer isn't cancelled by pure cursor movement (streams/ghosts are); eligibility is re-checked at fire time. Slight deviation from spec wording, noted in `AICompletionController.noteCursorMovement`.
- `restoreUIState` loads the raw-HTML flag only when window state exists (first-run default is false anyway).
- Search-as-you-type quotes FTS terms and appends `*` to the last term; FTS operator injection is tested but exotic queries just return empty.
- Editor find/replace = native NSTextView find bar (`⌘F`); library search = `⇧⌘F`.

## Keyboard map implemented

⌘N new Markdown / ⇧⌘N new folder / ⌘S save / ⌘W close tab / ⇧⌘F library search / ⌘L go to line / ⇧⌘D duplicate / ⇧⌘K delete line / ⌥⌘↑↓ move line / ⌘/ comment / ⌘] ⌘[ indent–outdent / ⌃Space local completion / ⌃⌥Space AI completion / Tab accept ghost / Esc dismiss / ⌥⌘L toggle wrap.
