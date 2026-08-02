# Wiki-Link Autocomplete Popover — Design

**Date:** 2026-08-02
**Branch:** `phase-7`
**Scope:** Gate 5, Task 28 (per `docs/PHASE-7-HANDOFF.md` and `docs/GATE-5-TASK-27-HANDOFF.md`)
**Status:** Approved, ready for implementation planning

## Goal

While typing a wiki link (`[[...`) in the Markdown editor, show a live-filtered
popover of matching note titles so the user can insert a link without leaving
the keyboard, and create a new note on the spot when nothing matches.

## Background

Store-side support already exists and is tested: `LibraryStore.titleSuggestions`,
`resolveWikiLink`, `backlinks`, `outgoingLinks`. What's missing is the editor-side
trigger, ranking, and UI.

Two existing things must **not** be reused as-is, for reasons already on record:

- `EditorTextView`'s `completions(forPartialWordRange:)` (`EditorTextView.swift:204`)
  is NSTextView's built-in word-completion hook. It only fires on explicit
  Control-Space, `forPartialWordRange` excludes `[` and stops at spaces, it
  returns a bare synchronous `[String]`, and title lookup is an actor call.
  It cannot be adapted; a new mechanism is needed.
- `AICompletionController` is the right model for the *async shape*
  (debounce → cancel-on-supersede → actor-backed fetch), but its UI shape is
  inline ghost text with Tab-to-accept, not a list. The wiki-link feature needs
  a genuinely new UI element — there is no existing `NSPopover` or list-picker
  anywhere in the app to imitate visually, which is why the popover's look was
  worked out separately (see Visual Design below).

Confirmed while designing this: wiki links are display-only today
(`MarkdownStyleScanner`/`MarkdownAttributeBuilder` only underline them; nothing
resolves or creates a note on click). So there is no later point at which an
unresolved link could lazily create its target — creation has to happen at
insertion time, when the user picks "Create note" from the popover.

`MarkdownMaskIndex.parseWikiLink` defines the only link syntax the app
recognizes: `[[<text>]]`, no pipe/alias form. The autocomplete does not need to
handle alias syntax because none exists to handle.

## Trigger & Lifecycle

- **Open condition:** the caret sits inside an unclosed `[[` on the current
  line — scan backward from the caret for the nearest `[[` that is not
  already followed by a `]]` before the caret. The substring from just after
  that `[[` to the caret is the live query.
- **Debounce:** ~150 ms per keystroke (shorter than the AI controller's 800 ms
  — this is a local DB read, not a network stream, so it can afford to feel
  more immediate).
- **Suppression:** while the popover is open, `AICompletionController`'s
  automatic trigger (`noteEdit`'s 800 ms inactivity timer) is skipped
  entirely. The two features never compete for the same keystroke.
- **Close conditions:** Escape; caret moves outside the open `[[` range
  (including by typing the closing `]]` itself, which completes the link);
  click elsewhere in the document; editor loses focus.

## Matching & Ranking

- `LibraryStore.titleSuggestions` currently does a SQL prefix `LIKE` match
  ordered by `mtime DESC`. This will be widened to fetch a bounded candidate
  set (still filtered to `trashed_at IS NULL`), then ranked in-app with the
  existing, currently-unused `FuzzyMatch.score(pattern:in:)` — the same DP
  matcher Gate 0 built specifically because prefix/greedy ranking put
  "Wireframes" above "Work Retrospective" for the query "wr". Results sort by
  score.
- **Empty query** (caret right after a freshly typed `[[`): skip fuzzy scoring
  and show recently-modified notes, matching Bear/Obsidian convention of
  offering recents before the user types anything.
- Matched character ranges from `FuzzyMatch.Score` are used to bold/highlight
  the matching characters in each row's title.

## Visual Design

Settled interactively (mockups in `.superpowers/brainstorm/`, not committed):

- Rounded 8px corners, compact row height, no per-row icon.
- Each row: title (with fuzzy-matched characters highlighted) on one line,
  a muted `tag · relative-date` metadata line beneath it.
- Selected row filled with the accent color.
- Adapts to the app's active light/dark theme (mockups were dark-only;
  color values must be re-derived from the existing theme system, not
  hardcoded).
- Anchored to the caret's screen rect (`NSTextView.firstRect(forCharacterRange:)`
  is the natural AppKit API here) and repositions live as the user types or
  scrolls.
- Scrollable if the ranked results exceed the visible row count (~8 rows);
  Up/Down navigates through the full result set, not just what's visible.
- A trailing `Create note "<query>"` row appears whenever the query is
  non-empty and nothing scores well enough to be a confident match.

## Insertion Behavior

- Selecting an existing title replaces the typed query (from `[[` to the
  caret) with that title and auto-appends `]]` if the closing brackets are
  not already present; caret lands just after the inserted `]]`.
- Selecting "Create note" performs the same text replacement/insertion for
  the literal typed query, and creates a new, empty Markdown file titled
  accordingly **in the same directory as the note currently being edited**
  (there is no sidebar-context signal available from inside the editor to
  do otherwise). The new file is picked up by the ordinary indexer pass;
  no special-case indexing is needed.
- Keyboard: Up/Down moves the highlighted row; Return or Tab accepts it.
  Tab is unambiguous here because the popover suppresses AI ghost text
  while open (see Trigger & Lifecycle).

## Error Handling

- Title lookup failures (actor/DB errors) fail silently — the popover simply
  shows no results, the same low-stakes posture as any other local-index
  read; this is not worth a user-facing error path.
- "Create note" file-creation failures surface the error once and stop,
  matching the existing pattern used by `TitleRenameCoordinator` for its own
  failure cases.

## Testing Plan

- Trigger-range unit tests: caret inside/outside/at the edges of `[[`,
  multiple `[[` on one line, an already-closed `[[...]]`, adjacent spaces.
- Ranking unit tests: fuzzy order matches expectation (the Gate 0 "wr"
  example), empty-query falls back to recents.
- Debounce/cancellation unit tests, mirroring `AICompletionControllerTests`.
- Insertion unit tests: replacing query text, auto-appending `]]`, and the
  create-note path producing a file the indexer subsequently picks up.
- A UI test exercising keyboard selection end-to-end — written but, like the
  rest of the Gate 4/5 UI test additions, unverified pending the existing
  XCUITest automation-permission blocker documented in
  `docs/PHASE-7-HANDOFF.md`.

## Out of Scope

- `[[target|alias]]` syntax — not supported by `MarkdownMaskIndex.parseWikiLink`
  today and not part of this task.
- Task 29 (search snippets/Quick Open) and Task 30 (export) are separate,
  already-planned tasks and untouched by this design.
