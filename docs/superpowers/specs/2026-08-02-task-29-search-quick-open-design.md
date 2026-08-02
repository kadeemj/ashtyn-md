# Task 29 — Search Snippets and Quick Open — Design

**Date:** 2026-08-02
**Branch:** `main`
**Scope:** Gate 5, Task 29 (per `docs/PHASE-7-HANDOFF.md`)
**Status:** Approved, ready for implementation planning

## Context

Gate 5 (links, search, export, info panel) has Tasks 27 and 28 complete. Task 29
covers three related deliverables named directly in the handoff: `SearchSnippet`,
`SearchQuery`, and Quick Open (⇧⌘O; ⌘K is already Insert Link).

Today, `LibraryStore.search(_:limit:)` runs an FTS5 query whose SQL calls
`snippet(files_fts, 3, '⟦', '⟧', '…', 12)` — real `⟦`/`⟧` characters as the
highlight delimiters. FTS5's `snippet()` does not escape its own markers, so a
note containing a literal `⟦` in its text would corrupt the parse.
`SearchColumnView.plainSnippet` (`LibraryWindowView.swift`) currently just
strips both markers rather than rendering them, with a comment noting this is
deliberately deferred to Gate 5.

There is no Quick Open today. The existing "Search Library" (⇧⌘F) is full-text
content search over title/path/content, shown in the sidebar's
`SearchColumnView`. Quick Open is a different, complementary tool: a fast,
keyboard-driven jump to a note by title/filename, reusing the same
`FuzzyMatch`/`LibraryStore.titleCandidates()` infrastructure already built and
proven for wiki-link autocomplete (Task 28).

## SearchQuery

New file: `AshtynMD/Features/Library/SearchQuery.swift`.

Extracts the FTS5 match-expression construction currently inline in
`LibraryStore.search()` — splitting the raw query on whitespace, quoting each
term (escaping embedded quotes), appending `*` for prefix matching on the final
term — into a pure static function:

```swift
enum SearchQuery {
    static func ftsMatchExpression(for rawQuery: String) -> String?
}
```

Returns `nil` for empty/whitespace-only input, matching `LibraryStore.search()`'s
existing empty-query guard. Behavior is unchanged; this only makes the query
construction independently unit-testable without SQLite. `LibraryStore.search()`
calls this instead of duplicating the logic inline.

## SearchSnippet

New file: `AshtynMD/Features/Library/SearchSnippet.swift`.

**Delimiter fix:** `LibraryStore.search()`'s SQL call changes from
`snippet(files_fts, 3, '⟦', '⟧', '…', 12)` to two private-use-area scalars
(U+E000 / U+E001), defined as constants on `SearchSnippet` so the SQL literal
and the parser share one source of truth rather than duplicating magic
characters in two files.

**Parsing:** a pure function splits the raw snippet string into segments:

```swift
enum SearchSnippet {
    struct Segment: Equatable {
        let text: String
        let isHighlighted: Bool
    }
    static func segments(from raw: String) -> [Segment]
}
```

Never throws. An unterminated/malformed marker yields the remainder as one
trailing plain segment rather than crashing or dropping content. The ellipsis
character `…` (FTS5's truncation marker) passes through as ordinary plain text.

**Rendering:** `SearchColumnView` replaces `plainSnippet(_:)` (which currently
strips both markers) with a `Text` built by concatenating segments — bold/
`.foregroundStyle(.primary)` for highlighted runs, `.foregroundStyle(.secondary)`
for plain — using SwiftUI's native `Text` concatenation (`+`). No
`AttributedString` machinery needed.

## Quick Open

New file: `AshtynMD/Features/Library/QuickOpen.swift`.

**`QuickOpenModel`** (`@MainActor @Observable`) mirrors the shape
`WikiLinkAutocompleteModel` already established for exactly this kind of
fuzzy-typeahead: a `query: String`, a 120 ms debounce (matching the wiki-link
popover's convention), and a per-request ID guard so a slow/stale lookup can
never overwrite a newer query's results.

Data source is entirely reused — no new `LibraryStore` methods:
- Empty query → `LibraryStore.recents(limit: 30)` (existing, using its
  standing default), matching the recents-before-typing convention Task 28's
  gap-closing work established for wiki-link autocomplete.
- Non-empty query → `LibraryStore.titleCandidates(limit: 500)` (existing)
  ranked by `FuzzyMatch.score(pattern:in:)` (existing) — the same DP matcher
  already proven against the "wr" → Wireframes/Work Retrospective ordering
  problem.

Each result carries `FuzzyMatch.Score.ranges` (`[NSRange]`, UTF-16-based,
already merged into runs by `FuzzyMatch`) for bolding matched characters in the
title, plus a secondary line:
`"#<primary tag> · edited <relative date>"`, falling back to `"Untagged"` —
reusing the exact visual convention the wiki-link popover already uses, so the
app's two fuzzy-pickers stay visually consistent.

**`QuickOpenView`** (SwiftUI): a text field plus a list of ranked results with
highlighted titles. Up/Down navigates, Return opens the selection, Escape
dismisses.

**Presentation:** a new `LibraryCommandRequests.Request.quickOpen` case, sent
from a new ⇧⌘O `CommandGroup` button in `AshtynMDApp.swift`
(`.disabled(appModel.libraryRoot == nil)`, matching the existing "Search
Library" button). The `.sheet` and matching `.onReceive` attach to
`LibraryWindowView` — **not** `NoteListView`, where the existing Move-to sheet
lives. `LibrarySplitView.middleColumn` swaps `NoteListView` out for
`SearchColumnView` whenever `sidebarSelection == .search`, so anything attached
to `NoteListView` stops receiving events while the search column is showing —
a pre-existing gap this design does not repeat and does not fix.
`LibraryWindowView` is the one view that's always mounted whenever a library is
open (it already hosts the analogous always-on `StandaloneOpenRequests`
receiver), so Quick Open's sheet belongs there.

Presentation mechanism is a SwiftUI `.sheet`, not a custom floating `NSPanel`.
A true centered/chromeless floating panel would be more visually accurate to
Spotlight/Sublime's Cmd+P, but its custom key-window and focus-return handling
can't currently be visually verified — XCUITests are blocked in this
environment by the TCC/automation-permission issue documented in
`docs/PHASE-7-HANDOFF.md`. `.sheet` reuses the app's one existing overlay
pattern (the Move-to… folder picker, via the same `LibraryCommandRequests`
relay), so it carries far less unverified new code.

On accept: dismiss the sheet, then call `appModel.openFile(at:)` — the
existing open path, which already handles sidebar selection and tab creation,
so Quick Open does not duplicate any of that logic.

## Error handling

- `SearchSnippet.segments(from:)` never throws; malformed input degrades to a
  plain trailing segment.
- `SearchQuery.ftsMatchExpression(for:)` returns `nil` for empty/whitespace
  input rather than an empty-but-non-nil expression.
- `QuickOpenModel` reuses `WikiLinkAutocompleteModel`'s existing
  request-ID cancellation discipline — no new error-handling pattern.
- Open failures from Quick Open flow through the existing
  `appModel.openFile(at:)` path and inherit whatever error surfacing that
  already does.

## Testing Plan

- `SearchQueryTests` — term quoting/escaping, empty input, FTS
  operator-injection characters (`"`, `*`), multi-term prefix behavior.
  Currently only reachable indirectly through `LibraryStoreTests`; this pulls
  it into direct, SQLite-free unit tests.
- `SearchSnippetTests` — no markers, one span, multiple spans, empty string,
  ellipsis passthrough, unterminated/malformed marker.
- `QuickOpenModelTests` — debounce/cancellation (same shape as the existing
  `WikiLinkAutocompleteTests` coverage), fuzzy ranking order, empty-query-shows-
  recents, stale-request guarding.
- A UI test extending the existing UI test suites for the open flow — caveated
  the same way the wiki-link gap-closing spec caveated its own UI test: only as
  reliable as the current XCUITest automation-permission blocker allows it to
  run.
- Full unit suite + `xcodegen generate` + performance gate, per this repo's
  standing convention.

## Out of Scope

- Task 30 (export) — untouched.
- Any rework of the sidebar Search column's architecture beyond snippet
  rendering.
- The `NoteListView`/`SearchColumnView` visibility gap for the Move-to sheet,
  noticed during exploration — pre-existing, unrelated to Task 29, not fixed
  here.
- A true floating `NSPanel` implementation of Quick Open — deferred until the
  XCUITest environment issue is resolved and it can be visually verified.
