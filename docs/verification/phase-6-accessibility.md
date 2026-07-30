# Phase 6 Accessibility Audit

- Date: 2026-07-30
- macOS: 26.5.2 (25F84)
- Xcode: 26.6
- Audited revision: `phase-6` working tree based on `0ce89f9`
- UI test count: 15

## Results

| Area | Result | Evidence |
| --- | --- | --- |
| VoiceOver labels and reading order | Pass | The captured accessibility hierarchy follows sidebar, file list, tab bar, document, then toolbar order. The editor, search field, Markdown mode radio group, preview, large-file controls, conflict controls, file rows, close-tab controls, and onboarding action expose human-readable labels. Streamed AI ghost text updates the editor label and help text so the suggestion is announced without entering the document. |
| Keyboard-only primary workflows | Pass | `KeyboardAccessibilityUITests` creates, edits, saves, and closes a note; searches and opens a result; invokes line commands; dismisses AI completion; and switches to Preview with `⌥⌘3`. Editor/Split/Preview also have `⌥⌘1`, `⌥⌘2`, and `⌥⌘3` menu shortcuts. |
| Increase Contrast | Pass | Navigation, tabs, banners, selection, and controls use semantic AppKit/SwiftUI colors and system control styles. Favorite and unsaved state remain available as accessibility values or labels rather than color alone. |
| Reduce Transparency | Pass | The editor status bar and document tab bar explicitly replace material/bar backgrounds with `controlBackgroundColor` when Reduce Transparency is enabled. |
| Light appearance | Pass | All 15 UI tests passed. Result bundle: `Test-AshtynMD-2026.07.30_14-30-55--0400.xcresult`. |
| Dark appearance | Pass | All 15 UI tests passed with `AppleInterfaceStyle=Dark`. Result bundle: `Test-AshtynMD-2026.07.30_14-33-26--0400.xcresult`. The temporary preference was removed after the run. |
| No color-only warnings or state | Pass | Conflict and capability states include text, icons, and labeled actions. Favorite state is included in each file row's accessibility value; the decorative yellow star is hidden from accessibility. Syntax color is presentational and never changes document semantics. |
| No decorative editor motion | Pass | Source inspection found no `withAnimation` or `.animation` calls. Editing, cursor movement, highlighting, preview refresh, and completion rendering remain immediate and interruptible. |

## Issues found and fixed

- Image-only paste was disabled by AppKit because the editor did not advertise PNG, TIFF, and file URLs as readable pasteboard types.
- Accessible file rows changed element type after combining their label and metadata; UI selectors now use the actual accessibility hierarchy.
- Markdown mode segments exposed SF Symbol names instead of Editor, Split, and Preview labels.
- AI ghost text help was not queryable by the macOS XCTest accessibility bridge; the editor now also announces it in its accessibility label.
- New documents did not automatically move keyboard focus into the editor.
- Search had no Return-key action from the search field.
- Library and per-file view state could race asynchronous session publication or be lost before a delayed write.
- File rows, search results, favorite state, and mode controls now expose stable labels, values, and identifiers.

## Automated evidence

Normal appearance:

```text
Executed 15 tests, with 0 failures
** TEST SUCCEEDED **
```

Dark appearance:

```text
Executed 15 tests, with 0 failures
** TEST SUCCEEDED **
```

The XCTest accessibility snapshots were also inspected for the three-column
order, combined file-row values, native editor label, Markdown radio group,
preview element, and keyboard focus state.
