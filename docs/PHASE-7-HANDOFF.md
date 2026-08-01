# Phase 7 — Bear-like note-taking: Handoff

**Date:** 2026-08-01
**Branch:** `phase-7` (13 commits ahead of `main`, not merged)
**State:** Gates 0–4 complete; Task 27 complete (27 of 32 tasks). Gate 5 is in progress.
**Plan:** `/Users/kadeem/.claude/plans/lets-create-a-better-delegated-crayon.md`

## Goal

Turn the Markdown side of Ashtyn MD into a Bear-like notes app — inline-styled
editor, `#tag` organization, title-from-first-line, an Inbox for capture —
while keeping files as plain files on disk, the SQLite index disposable, and
the tree-sitter code editor untouched for non-Markdown files.

Four decisions were locked with the user before implementation:

| Decision | Choice |
|---|---|
| Editor rendering | Inline styling, always on for Markdown |
| Organization | Tags first, folders kept |
| Note identity | First line is the title, **and the file is renamed to match** |
| Capture | Real `<library>/Inbox/` folder, selected at launch |

---

## Current state

**Tests: 446 passed, 5 skipped (451 total) in the unit target, all passing.**
Baseline before Gate 4 was 435 unit tests in 41 suites; the original phase
baseline was 167 in 23 suites.

```bash
xcodegen generate
xcodebuild -project AshtynMD.xcodeproj -scheme AshtynMD -configuration Debug test -only-testing:AshtynMDTests
```

The 10,000-file performance gate still passes at 3.30 s
(`./script/performance_gate.sh`).

**XCUITests: 19 passing**, including the Gate 5 Note Info inspector flow.

### Commits

```
2a2d59f feat: rebuild the library UI around tags and an Inbox
6820218 feat: derive note metadata in the indexer and fix rename identity
36e0818 feat: add schema v2 with nested tags, note metadata, and links
ab77c6a feat: expose markdown editor settings and tighten prose spacing
31b322e feat: add Bear-style markdown formatting commands and modes
d9cd651 feat: style markdown inline in the editor
3f14e3d feat: extend editor themes with full palettes and markdown roles
3d930c0 feat: add the shared markdown scanner, metadata parser, and fuzzy match
0d7b976 perf: cache prepared statements in SQLiteDatabase
```

---

## What was built

### Gate 0 — Foundations (`Core/Markdown/`, `Core/Notes/`)

One masking pass, `MarkdownMaskIndex`, resolves front matter, fenced and inline
code, HTML comments, link destinations, and autolinks. Both the editor styler
and the indexer consume it, so **tag grammar has exactly one definition**
(`MarkdownTagScanner`) — a `#tag` that highlights while typing is always the
same `#tag` that reaches the sidebar.

`MarkdownStyleScanner` is hand-written rather than driven from tree-sitter or
swift-markdown because the editor needs structure neither provides: heading
level, list and quote depth, marker sub-ranges for dimming, and tag ranges,
which no grammar models at all. `MarkdownScannerParityTests` cross-checks it
against swift-markdown over 13 ASCII documents so the editor and the WebKit
preview cannot silently drift.

Also: `MarkdownMetadata` (title/excerpt/tags/links/counts in one pass, reusing
`MarkdownTasks` for checkboxes so the info panel can never disagree with the
preview), `FuzzyMatch` (a DP, not a greedy scan — greedy ranked "Wireframes"
above "Work Retrospective" for `wr`), and a prepared-statement cache in
`SQLiteDatabase`.

### Gate 1 — The inline-styled editor (`Features/Editor/`)

Markdown renders with real typography: heading sizes, bold/italic faces,
monospace code spans, hanging indents, markers that dim off the caret line.

**The load-bearing mechanism:** `NSLayoutManager` temporary attributes are
applied at draw time and ignored for glyph metrics, so real font sizes and
paragraph indents are unreachable from the syntax-highlight path. Markdown
therefore writes `NSTextStorage` attributes via `MarkdownStyler`; code keeps
temporary attributes untouched. `reapplyTypingAttributes` — whose whole-buffer
stomp is right for code and fatal for prose — is now `applyCodeBaseAttributes`
and only runs for non-Markdown.

The `isRichText` spike the plan called for came back clean: programmatic
storage attributes stick with `isRichText = false`, so paste stays plain and
no fallback was needed.

Format menu with 17 commands. Conflicts resolved: selectors are deliberately
**not** `toggleBoldface:`/`toggleItalics:` (NSTextView no-ops those under
`isRichText = false`); code is ⇧⌘E because ⌘E is the find bar's "Use Selection
for Find"; todo is ⇧⌘L because ⇧⌘C is the system color panel; headings reserve
⌘1–⌘6 app-wide.

`MarkdownStylerSnapshotTests` renders light and dark themes to PNGs behind
`ASHTYN_SNAPSHOT=1`. It asserts nothing about pixels — it exists so the styling
can be inspected without launching the app. **It caught two bugs the attribute
assertions could not:** vertical gaps were double-counted (a blank source line
*is* the paragraph gap) and dividers were invisible in dark mode.

### Gate 2 — Schema v2 (`Core/Indexing/`)

New `files` columns (title, title_key, excerpt, created_at, word/char counts,
todo counts, pin, archive, trash, title_is_managed, reindex_pending) plus
`tags`, `file_tags`, and `links`.

Three choices worth preserving:

- **Nested tags use a materialized path**, not `parent_id`. Every hot query is
  "this tag and its descendants", which a path makes a plain predicate where
  `parent_id` needs a recursive CTE per sidebar count. The usual weakness
  (renames rewrite the subtree) does not apply — tags are derived from note
  text, so renaming one rewrites the notes and the table re-derives.
- **`file_tags` stores every ancestor.** All sidebar counts become one grouped
  equality join, and a note carrying both `#work` and `#work/alpha` counts once
  under `work`.
- **`links` has no `target_file_id`.** Resolution is `title_key` equality, so
  backlinks follow a renamed note with zero maintenance and ambiguity is just
  "more than one row".

FTS5 cannot be `ALTER`ed, so gaining a `title` column means drop-and-recreate —
safe only because content re-derives from disk, which `reindex_pending` forces.
**Both silent-breakage traps are handled:** the snippet column index and the
result column offset are derived in code, since hardcoding either still
compiles while returning the wrong string.

**A latent bug was fixed and proven.** FSEvents reports a batch in arbitrary
order; handling a rename's vanished old path first deleted the row, so indexing
the new path found no `resource_id` match and inserted a fresh one — losing id,
favorite, recents, and view state. Paths that still exist are now processed
first. Verified by reverting the fix and watching the test report **id 2 instead
of id 1** with the favorite and view state gone. This also repairs plain Finder
renames, and it had to land before Gate 4 makes renames constant.

Verified against a real v1 database from a prior run: migrated to v2 on launch,
derived titles and todo counts, indexed `#work/alpha` with `work` as a
non-direct ancestor, recorded a `[[wiki link]]`.

### Gate 3 — Library UI (`Features/Library/`)

`AppModel` went from 566 lines to a composition root over `LibrarySession`,
`TabsModel`, `NoteListModel`, `TagsModel`, `SearchModel`, `NoteActionsModel`.
Sub-models take closures rather than back-references, so each is constructible
in a test — which mattered, since UI tests were unavailable.

Sidebar is tags-first: Inbox / Notes / Untagged / To-Dos / Pinned with count
badges, a nested tag tree, folders collapsed below, then Favorites / Recents /
Search / Archive / Trash. Counts come from one grouped query refreshed when the
indexer commits, never from a view body. Dropping a note on a tag inserts the
tag into the note's **text** (tags are content); open notes route through
`performSourceEdit` to join the native undo stack.

Note list is Bear-shaped: title, two-line excerpt, relative date, pin/star/todo
indicators. List selection is its own `Set<String>` rather than derived from the
active tab — that decoupling is what makes multi-note actions possible.

The **Inbox is an ordinary folder**, not a smart list, so filing is a real move
that Finder shows and an index rebuild cannot lose. Nothing about it appears in
the schema; membership is a path prefix. ⌘N always captures there, ⌥⌘N creates
where the sidebar points, ⌃⌘M files out (⌘M is system Minimize). A tag
selection still captures to the Inbox and seeds the tag into the body, because
a tag is not a location. Launch restores tabs and cursor positions but always
selects the Inbox.

### Gate 4 — Lifecycle and title↔filename sync

Gate 4 is complete. `NoteLifecycle` keeps recovery state on disk under `.archive/`
and `.trash/`, with collision-safe restore and Trash manifests that preserve the
original relative path. The indexer has a dedicated lifecycle pass so the
disposable SQLite index can be rebuilt without resurrecting archived or trashed
notes; archived previews resolve links and assets against their original
directory.

Open Markdown sessions can opt into a debounced first-line → filename rename.
The coordinator saves before renaming, sanitizes unsafe names to the 120-byte
contract, preserves index identity, retargets the open session, and stops after
surfacing a failure. The setting is persisted per library as `titleRename.v1`.

Tag rename/delete rewrites use the shared Markdown scanner, apply ranges from
back to front, and keep byte-exact undo snapshots in Application Support with a
2,000-file cap. Archive, in-library Trash, permanent deletion, restore, tag
rewrite, and title-management actions are wired into the library UI.

Focused lifecycle/title/tag tests, the full unit target, and the performance
gate pass. XCUITests remain unverified because the existing macOS automation/TCC
blocker is still present.

---

## Known problems

### 1. XCUITests cannot run (blocking, environment)

Every UI test fails with:

```
Failed to initialize for UI testing:
"Timed out while enabling automation mode."
```

They passed at the end of Gate 1 (15 tests, ~154 s). The failure began after an
AppleScript/System Events call during a Gate 1 visual check, which likely left a
TCC permission prompt pending that a non-interactive session cannot answer.
`screencapture` is blocked the same way. Restarting `testmanagerd` did **not**
fix this (that fixed a different problem — see below).

**To fix:** grant Accessibility and Screen Recording to Xcode and Terminal in
System Settings → Privacy & Security, or run the UI tests once from the Xcode
GUI to answer whatever prompt is stuck.

**Consequence:** UI test *sources* were updated for the enumerated breakage but
**never executed**. This is the largest unverified surface in the phase:

- `UITestCase.file(named:)` now matches the row's **title**; `file(withName:)`
  added for filename matching; `searchResult(named:)` added for the search list.
- `chooseSidebarItem` matches on **label**, since sidebar values now carry counts.
- `LibraryWorkflowUITests` rewritten; new tests for Inbox capture, launch
  selecting Inbox, and tag filtering.
- Fixtures gained `Tagged Note.md` (`#work/alpha`, `#reading`, todos, a wiki
  link) and `Inbox/Captured Note.md`.

Expect some of these to need adjustment on first real run.

### 2. `testmanagerd` can wedge (resolved, but recurrable)

Mid-Gate-3, killing `xcodebuild` processes to unstick a hung filtered test run
wedged `testmanagerd`, after which **every** test run hung at launch — including
suites unrelated to the changes. A stack sample showed XCTest stuck in
`_prepareTestConfigurationAndIDESession`, waiting on a coordinator handshake.

**Cure:** `pkill -9 -x testmanagerd` (it respawns). Verified working afterwards
on the default derived-data path.

**Lesson:** do not kill `xcodebuild` mid-run to unstick a hang; it made things
considerably worse and cost significant time.

### 3. Deliberate deferrals

- **Per-window model split** (plan Task 18). Needs `@FocusedValue` plumbing for
  ~20 App-scope menu commands, and menus are exactly what the unrunnable UI
  tests cover. Took the plan's own documented fallback: presentation state stays
  view-local (the Move to… sheet uses `LibraryCommandRequests`, a relay, rather
  than model state) so two windows will not fight once the split lands.
- **System Trash remains the final recovery layer.** Gate 4 now uses the
  in-library `.trash/` contract for ordinary deletion; "Delete Permanently"
  sends the already-trashed note to the macOS system Trash.
- `MarkerVisibility.hidden` colors markers but does not yet collapse them to
  zero width; the glyph suppression belongs in a layout-manager delegate.

---

## Gate plan and next steps

### Gate 4 — Lifecycle and title↔filename sync (Tasks 23–26) — **complete**

Its prerequisite (the FSEvents identity fix) landed in Gate 2. The implementation
and verification summary is above; the original task contract is retained here
as a reference for the on-disk behavior.

**Task 23 — `NoteLifecycle` — complete** (`Core/FileSystem/NoteLifecycle.swift`).
Trash and archive live **on disk, not in the index**, because `LibraryStore` is
documented as disposable — an index-only `trashed_at` would resurrect every
trashed note when that promise is exercised.

- Trash: `<root>/.trash/<uuid>/<name>.md` + `meta.json`
  (`{originalRelativePath, trashedAt, title}`). The UUID directory handles name
  collisions and repeated trashing of one path; `meta.json` makes restore
  survive total index loss. *Delete Permanently* then uses the system Trash,
  correctly positioned as the last recovery layer.
- Archive: `<root>/.archive/<original relative path>`, path-preserving, no UUID,
  no metadata file. The asymmetry is deliberate: a path can be trashed
  repeatedly; unarchiving is the only exit from archive.
- Add both names to `LibraryBrowser.excludedDirectoryNames` (checked *before*
  the hidden-file test, so `setShowHiddenFiles(true)` cannot leak them).
- Pin stays index-only — same acceptable loss class as `is_favorite`. Do not
  encode it in note text.
- Known cost: an archived note's directory depth changes, so relative image
  links resolve differently. `DocumentAreaView.previewContext` must resolve
  archived notes against their original directory.

**Task 24 — complete** — lifecycle store methods (`markArchived`, `markTrashed`,
`markRestored`) and a dedicated indexer pass over `.trash`/`.archive`. The
store queries (`archivedNotes`, `trashedNotes`) already exist from Gate 2.

**Task 25 — `TitleFilename` + `TitleRenameCoordinator` — complete.** Owned by neither
`DocumentSession` (also used by `StandaloneDocumentView` for Finder-opened files
outside any library, where renaming would be flatly wrong) nor `AppModel`.
The hook already exists: `DocumentSession.textDidChange` fires from
`updateText`, and `TabsModel` wires it to `onSessionTextChange` — currently
unconsumed.

Sequence, all main-actor: debounce 1.2 s → `await session.save(...)` →
sanitize → bail if the base already matches → `LibraryBrowser.availableURL` →
`FileOperations.rename` → `indexer.applyRename` (already implemented) →
`session.fileWasMoved(to:)` → refresh.

- **Never race the atomic write.** `SaveCoordinator.writeAtomically` resolves
  its destination at call time; renaming mid-save recreates the old filename
  and leaves two files. Save first.
- **No rename ping-pong:** `TitleFilename.matches("Groceries 2.md", title:
  "Groceries") == true`, so a collision suffix does not retrigger.
- **Sanitize:** `/` and `:` → `-`; strip control chars and a leading `.` (also
  guards our own `.name.ashtyn-save-xxxxxxxx` temp prefix); collapse
  whitespace; strip trailing dots/spaces; reject `.`/`..`/empty; truncate to
  **120 UTF-8 bytes** — leaving headroom for both ` 2.md` and the 22-character
  save temp file, which would otherwise blow the path limit on long titles.
- **Opt-out:** `title_is_managed` (column exists; `setTitleIsManaged` exists and
  `NoteActionsModel.rename` already sets it to 0 when the user renames by hand).
  Restore it via an info-panel toggle. Plus guards: only for open sessions,
  never during a conflict, never during state restore, never across directories,
  and on failure surface the error **once** and stop.
- Ship a per-library off switch (*Rename files to match the first line*,
  default on, `app_state` key `titleRename.v1`). Honest costs: sync services
  model renames as delete+create; git will not detect a rename on a nearly-empty
  new note.

**Task 26 — `TagRewriter` — complete.** Rename/delete a tag by rewriting note text (tags
are derived from text, so the tables re-derive themselves). Candidate set is
free from the closure rows via `LibraryStore.filesTagged(withKeyOrDescendant:)`
— already implemented. Apply edits **back-to-front** so ranges stay valid.
Undo is snapshot-based into
`AppSupportPaths.libraryDirectory(forRoot:)/TagRewrites/<uuid>/`, capped at
2,000 files, behind a confirmation sheet.

### Gate 5 — Links, search, export, info panel (Tasks 27–30) — **in progress**

Store-side work is **already done** in Gate 2: `resolveWikiLink`, `backlinks`,
`outgoingLinks`, `titleSuggestions` all exist and are tested.

- **Task 27 — complete.** Backlinks + note info panel are in a `.inspector`
  (macOS 14+), not a
  section under the editor (that fights the scroll view and breaks the
  editor/split/preview modes). Stats compute from the *editor buffer* with a
  300 ms debounce, and the panel resolves backlinks and outgoing wiki links
  through the existing actor-backed store APIs. The focused unit and UI tests,
  full unit suite, and all 19 macOS UI tests pass.
- **Task 28 — next** — wiki-link autocomplete popover. **Do not reuse** the existing
  completion hook (`EditorTextView.swift:204`): it only fires from explicit
  ⌃Space, `forPartialWordRange` excludes `[[` and stops at spaces, it returns
  bare `[String]`, and it is synchronous while title lookup is an actor call.
  Model it on `AICompletionController` instead.
- **Task 29** — `SearchSnippet` / `SearchQuery` / Quick Open (⇧⌘O; ⌘K is Link).
  **Change the FTS snippet delimiters** to U+E000-range private-use scalars:
  FTS5's `snippet()` does not escape its own markers, so a note containing a
  literal `⟦` corrupts the parse. Then actually render the highlight —
  `SearchColumnView.plainSnippet` currently strips it.
- **Task 30** — export. Markdown = byte-exact `copyItem`. HTML/PDF/RTF need a
  new `MarkdownPreviewPage.exportDocument(bodyHTML:title:)` sibling, because
  `wrap` injects a `window.webkit.messageHandlers` script that is a JS error in
  a standalone file. **DOCX starts with a probe test** (`PK\x03\x04` +
  `word/document.xml`); if it throws, fall back to `.docFormat` and gate the
  menu item on `NoteExporter.isAvailable(.docx)`.

### Gate 6 — Coverage and docs (Tasks 31–32)

Fixtures were partly done early (Gate 3 needed them). Remaining: new UI test
suites, three new perf gates (scanner throughput on 1 MB < 150 ms; initial full
restyle of 1 MB < 400 ms; per-keystroke block restyle < 2 ms p95), design/plan
docs, verification record, and a `HANDOFF.md` update documenting the
`.trash`/`.archive` on-disk contract — that one is a user-visible promise.

---

## Conventions worth not relearning

- `project.yml` is the source of truth. **Run `xcodegen generate` after adding
  any file**, and commit `AshtynMD.xcodeproj`.
- Swift Testing (`@Suite`/`@Test`/`#expect`), hosted in the app. Temp libraries
  under `FileManager.default.temporaryDirectory` with UUID names.
- **Stores must be `close()`d before removing their directory** — teardown
  races the WAL files otherwise. Use the `withStore`/`withTemporaryStore`
  scoped-helper pattern; a `defer` cannot `await`.
- A Swift Testing closure containing **only** `#expect` calls gives the compiler
  nothing to infer throwing-ness from, and the macro's internal `try` then has
  nowhere to propagate. Annotate it:
  `{ (store: LibraryStore) async throws -> Void in`.
- The test host is sandboxed: `/tmp` is not writable, and
  `FileManager.default.temporaryDirectory` maps into
  `~/Library/Containers/com.kadeem.ashtynmd/Data/tmp/`.
- Command-line `xcodebuild` and the Xcode GUI use **different DerivedData
  directories**. When launching the built app manually, take the path from the
  test log, not the first `find` hit.
- In-memory text is **always LF**; `LoadedTextFile` normalizes on load and
  reapplies the file's style on save. Never detect line endings mid-edit.
  (`LineEnding.rawValue` is the case name, `"lf"` — not the characters.)
