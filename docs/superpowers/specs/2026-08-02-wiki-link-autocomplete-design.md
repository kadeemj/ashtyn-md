# Wiki-Link Autocomplete — Gap-Closing Design

**Date:** 2026-08-02
**Branch:** `main`
**Scope:** Gate 5, Task 28 follow-up (per `docs/PHASE-7-HANDOFF.md`)
**Status:** Approved, ready for implementation planning

## Context

Task 28 (the wiki-link autocomplete popover) was designed from scratch in this
session before it became clear that it had already been implemented, tested,
and merged to `main` in commit `7a13e77` ("feat: add wiki-link autocomplete"),
independently of this conversation. That implementation is solid — real
XCUITest coverage, a clean debounce/cancellation state machine, correct
keyboard-priority handling — but it differs from what was designed here in a
few concrete ways. This document is now scoped as a **follow-up that closes
those specific gaps against the existing code**, not a from-scratch build.

## What's already built (no changes needed)

All in `AshtynMD/Features/Editor/WikiLinkAutocomplete.swift` unless noted:

- **Trigger detection** — `WikiLinkAutocompleteContext.detect` scans backward
  for an unclosed `[[`, is escape-aware (an odd count of preceding backslashes
  bails out), and bails on `\n`, `\r`, `|`, `]]`, or a nested `[` in the query.
  This is more complete than the original design (it handles backslash-escaped
  `\[[`, which hadn't been considered).
- **Debounce + cancellation** — `WikiLinkAutocompleteModel`, 120 ms debounce,
  a per-request `requestID` guards against stale results replacing a newer
  query.
- **Popover positioning** — `NSPopover` anchored to
  `textView.firstRect(forCharacterRange:)`, `.semitransient` behavior,
  repositions as the context changes.
- **Keyboard priority** — Up/Down/Return/Escape via `handleKeyDown`; Tab via
  `PlainTextView.insertTab`, checked *before* AI ghost-text acceptance. So
  "the popover wins" is already correct at accept-time.
- **Insertion** — one undoable edit via `textView.applyExternalEdit`,
  replacing exactly `context.targetRange`.
- **Bracket auto-pairing** (`PlainTextView.insertText`, pre-existing feature,
  unrelated to this task) already inserts `[[|]]` with the caret between the
  brackets in the common case — so accepted suggestions normally don't need
  to append `]]` themselves. The one gap: if `[[` was typed immediately
  before non-whitespace text, auto-pairing doesn't fire and no `]]` exists
  yet. Insertion should check for this and append `]]` only when it's
  actually missing.
- **Unit/UI coverage** — `WikiLinkAutocompleteTests.swift`,
  `EditorWorkflowUITests.swift`.

## Gap 1 — Fuzzy matching + highlighting

`LibraryStore.titleSuggestions` does a SQL prefix `LIKE` match ordered by
`mtime DESC`. Widen it (or add a sibling method) to fetch a bounded candidate
set, then rank in-app with the existing, currently-unused
`FuzzyMatch.score(pattern:in:)` — the same DP matcher Gate 0 built because
prefix/greedy ranking put "Wireframes" above "Work Retrospective" for "wr".
`WikiLinkAutocompleteModel`'s `suggestionProvider` closure signature
(`(String, Int) async -> [FileRecord]`) doesn't need to change — this is a
change inside the provider, not the state machine. Use `FuzzyMatch.Score`'s
matched-position ranges to bold the matching characters in
`WikiLinkAutocompletePopoverView`'s title text.

## Gap 2 — "Create note" row

Currently, an empty result set renders "No matching notes" with no way
forward. Instead: when the query is non-empty and the ranked result list is
empty, append a synthetic trailing row, `Create note "<query>"`, in place of
the dead-end placeholder. (No partial-match threshold — fuzzy matching still
returns anything with a nonzero score, so this only fires when truly nothing
matches.) Selecting it:

- Replaces `context.targetRange` with the typed query (same insertion path as
  an existing-title match), appending `]]` only if it isn't already present
  immediately after the caret (see the auto-pairing note above).
- Creates a new, empty Markdown file titled from the query, **in the same
  directory as the note currently being edited** — there's no sidebar-context
  signal available from inside the editor to do otherwise. Reuse/extend
  `NoteActionsModel`'s existing file-creation path (`create(language:in:seedTag:)`)
  rather than duplicating `FileOperations` calls. The new file is picked up
  by the ordinary indexer pass; no special-case indexing is needed.
- On file-creation failure, surface the error once and stop, matching the
  pattern `TitleRenameCoordinator` already uses for its own failures.

## Gap 3 — Full AI-trigger suppression

`EditorTextView.Coordinator.textDidChange` already calls
`wikiLinkAutocomplete?.update()` before `aiController.noteEdit(...)`, but
nothing stops the latter from arming its own 800 ms trigger while the popover
is showing. Guard that call so it's skipped whenever
`wikiLinkAutocomplete?.model.isActive == true` — the same place `isEligible`
already gates on selection/composition state, so this is a one-line addition
to an existing check, not new plumbing.

## Gap 4 — Polish parity

- Swap the popover row's secondary line from `record.relativePath` to
  `"#<primary tag> · edited <relative date>"`, falling back to "Untagged"
  when a note has no tags. This was the originally agreed visual design;
  the shipped `relativePath` is a reasonable alternative but wasn't the
  decision made when the visual style was picked.
- `WikiLinkAutocompleteModel.update` currently short-circuits to `cancel()`
  when the query is empty (`!next.query.isEmpty` guard). Change this so an
  empty query (caret right after a freshly typed `[[`) instead populates
  `suggestions` with recently-modified notes, matching Bear/Obsidian
  convention of showing recents before the user types anything.

## Testing Plan

Additions to `WikiLinkAutocompleteTests.swift` (the existing trigger-range
and debounce tests are unaffected):

- Fuzzy ranking order (the Gate 0 "wr" example) and highlighted-range
  correctness.
- Create-note row appears only when the query is non-empty and the ranked
  result list is empty; selecting it creates a file at the expected path and the
  indexer subsequently sees it; `]]` is appended only when not already
  present.
- AI auto-trigger does not arm while `wikiLinkAutocomplete.model.isActive`.
- Empty-query state shows recent notes instead of clearing.

A UI test extending `EditorWorkflowUITests.swift` for the create-note flow —
written but, like the rest of the Gate 4/5 UI test additions, only as
reliable as the existing XCUITest automation-permission environment allows
(documented in `docs/PHASE-7-HANDOFF.md`).

## Out of Scope

- `[[target|alias]]` syntax — not supported by `MarkdownMaskIndex.parseWikiLink`
  and not part of this task.
- Task 29 (search snippets/Quick Open) and Task 30 (export) are separate,
  already-planned tasks and untouched by this design.
