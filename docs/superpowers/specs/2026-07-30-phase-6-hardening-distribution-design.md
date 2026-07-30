# Phase 6 Hardening and Distribution Design

**Date:** 2026-07-30  
**Product:** Ashtyn MD 0.1.0  
**Target:** macOS 14+, Apple silicon and Intel  
**Distribution:** Signed and notarized direct-download DMG

## Objective

Complete the original product plan's Phase 6 by closing the remaining
large-file, conflict, UI-test, accessibility, performance, external-sync, and
distribution gaps. The phase ends with a universal Developer ID-signed,
notarized, stapled DMG that passes local Gatekeeper validation.

The first beta does not include a self-updater.

## Guiding approach

Phase 6 is a gate-driven hardening pass. Runtime safety and acceptance coverage
come before packaging so the distributed artifact is built from the exact
source revision that passed the quality gates.

The work is organized into four independently verifiable gates:

1. Runtime hardening
2. Quality automation
3. Stress and performance validation
4. Distribution

## Gate 1: Runtime hardening

### Large-file policy

Add a pure, testable `DocumentCapabilities` value derived from the file's byte
size when a `DocumentSession` opens.

The supported tiers are:

| File size | Mode | Editing | Syntax | Preview | AI |
|---|---|---:|---:|---:|---:|
| Up to and including 2 MB | Full | Yes | Yes | Live, 250 ms debounce | Available |
| More than 2 MB through 10 MB | Large | Yes | Yes | Explicit/manual render | Disabled |
| More than 10 MB | Read-only large | No | Visible-range only | Disabled | Disabled |

For files over 10 MB, the document area explains the limitation, displays the
file size, and offers **Open Anyway**. The override changes the session to
large-file mode rather than full mode: editing becomes available while manual
preview and disabled AI remain in force.

`DocumentSession` owns the computed tier and the in-memory Open Anyway
override. `EditorContainerView`, `EditorTextView`, syntax scheduling,
Markdown preview, and AI request construction consume the session capability
instead of independently comparing file sizes.

The override is intentionally not persisted. Reopening a file over 10 MB
requires a new explicit decision.

### Conflict comparison

The existing conflict banner gains the missing **Compare** action. It presents
a native sheet with the current editor text and current disk text in
side-by-side, read-only text views. Comparison does not mutate the session and
does not introduce a third-party diff dependency.

The existing actions remain:

- Use Disk
- Keep Mine
- Save Copy

The duplicate Use Disk button is removed.

### SQLite lifecycle

`SQLiteDatabase` gains an idempotent explicit close path. `LibraryStore`
exposes actor-isolated shutdown, and application/library teardown calls it
after the indexer has stopped. Tests close stores before removing temporary
directories.

The required outcome is a clean test run without SQLite "vnode unlinked while
in use" diagnostics.

## Gate 2: Quality automation

### UI-test target

Add an `AshtynMDUITests` `bundle.ui-testing` target through `project.yml`.
`project.yml` remains the source of truth, and XcodeGen regenerates the project
after the target and sources are added.

### Deterministic test library

Debug UI-test launches use explicit launch arguments to create or reopen a
fixture library inside the app's own test container. The fixture root bypasses
`NSOpenPanel` only under the UI-test build condition.

The harness supports:

- Resetting to a known fixture library
- Reopening the same fixture library on a later launch
- Seeding Markdown, source, plain-text, and image fixtures
- Opening a standalone fixture document
- Returning deterministic mock AI ghost text

Release builds do not include test fixture data, mock providers, onboarding
bypasses, or test-only menus.

### UI acceptance coverage

The UI suite covers:

- Choose and reopen a library
- Create nested folders and multiple file types
- Open multiple tabs and restore their order and state
- Open a standalone document
- Paste text and verify exact character and newline fidelity
- Toggle Editor, Split, and Preview and restore the prior mode
- Search, favorite, and reopen recent notes
- Paste an image and verify the inserted relative link
- Accept and dismiss deterministic ghost-text completion
- Operate primary workflows using only the keyboard

### Accessibility

Every icon-only or visually inferred control receives a meaningful
accessibility label and stable identifier. Focus order follows:

1. Library sidebar
2. File list
3. Tab strip
4. Editor or preview
5. Status information

Primary workflows remain available through menus, shortcuts, Tab, arrow keys,
Space, Return, and Escape. Dynamic system colors remain the default for
increased-contrast compatibility. When Reduce Transparency is enabled,
translucent bar backgrounds use opaque system alternatives.

Syntax color is supplemental. Selection, warnings, conflicts, completion
state, and read-only state retain text, shape, or icon indicators. No
decorative motion is introduced in the editor input path.

Light and dark appearances are both included in the verification pass.

## Gate 3: Stress and performance validation

### Automated performance gates

Dedicated performance commands exercise production types with deterministic
fixtures:

- Index 10,000 supported text files without blocking the main actor.
- Return indexed search results in under 200 ms.
- Render a deterministic 100 KB Markdown document in under 300 ms.
- Produce visible syntax updates for representative normal-document edits in
  under 100 ms.
- Exercise representative typing and scrolling in a 2 MB document while
  recording elapsed time and peak resident memory.

Expensive performance coverage runs through a dedicated script rather than on
every ordinary unit-test invocation. The script fails when a product-plan
threshold is exceeded and records timing, machine architecture, macOS version,
and toolchain version with the results.

Memory profiling records a repeatable baseline and investigates unbounded
growth; the original product plan does not define a numerical memory ceiling,
so Phase 6 does not invent one.

### External-sync stress

Tests simulate sync-provider filesystem behavior without coupling to iCloud or
Dropbox:

- Rapid atomic replacements
- Repeated metadata-only touches
- Rename and move bursts
- Delete followed by recreation
- External edits while the session is clean
- External edits while local changes are dirty
- Missing-file restore and Save Copy
- FSEvents reconciliation after coalesced event delivery

Clean sessions reload external content. Dirty sessions pause autosave and enter
the conflict state. No conflict path silently overwrites the disk version.
Stress tests use bounded waits and identify the exact failed transition.

## Gate 4: Distribution

### Release configuration

The release build targets `arm64` and `x86_64`, keeps
`MACOSX_DEPLOYMENT_TARGET=14.0`, enables Hardened Runtime, retains the App
Sandbox and existing entitlements, and uses:

- Bundle identifier: `com.kadeem.ashtynmd`
- Team ID: `JUQMKZZ7TJ`
- Signing identity: `Developer ID Application: Kadeem Jeffery (JUQMKZZ7TJ)`
- Notary Keychain profile: `AshtynMD-notary`

Secrets and app-specific passwords never appear in project files, scripts,
logs, command output, or release artifacts.

### Release automation

A repository-owned release script:

1. Requires a clean source revision.
2. Regenerates the Xcode project from `project.yml`.
3. Runs the required unit, UI, stress, and performance gates.
4. Creates a fresh universal Release archive.
5. Exports and verifies the signed app.
6. Confirms both `arm64` and `x86_64` are present.
7. Inspects Hardened Runtime, entitlements, and nested signatures.
8. Submits the app archive through `notarytool`.
9. Preserves the submission identifier and failure log.
10. Staples and validates the accepted app ticket.
11. Creates a DMG containing the app and an Applications-folder link.
12. Signs, notarizes, staples, and validates the DMG.
13. Mounts the DMG and validates its contained app with `codesign`, `spctl`,
    `stapler`, and architecture inspection.
14. Writes a SHA-256 checksum.

The output is:

```text
dist/
  AshtynMD-0.1.0.dmg
  AshtynMD-0.1.0.dmg.sha256
  notarization/
```

Staging occurs in a fresh temporary directory. A previously accepted release
is never overwritten implicitly. The script exits at the first failed build,
test, signature, architecture, notarization, staple, mount, or Gatekeeper
check.

## Verification order

Implementation and verification proceed in this order:

1. Large-file and runtime-hardening tests, then implementation
2. External-sync and SQLite-lifecycle tests, then implementation
3. UI-test harness and UI acceptance coverage
4. Accessibility and appearance audit
5. Performance and memory gates
6. Universal Release build
7. Signing and entitlement inspection
8. App notarization and stapling
9. DMG creation, signing, notarization, and stapling
10. Mounted-artifact Gatekeeper validation and checksum

## Phase completion criteria

Phase 6 is complete only when:

- Unit and UI tests pass.
- Test output contains no SQLite integrity diagnostics.
- The external-sync stress suite passes.
- The product-plan performance thresholds pass on the recorded machine.
- Accessibility and keyboard-only acceptance checks pass in light and dark
  appearances, including increased contrast and reduced transparency.
- The Release app contains both required architectures.
- The app and DMG have valid Developer ID signatures and notarization tickets.
- Gatekeeper accepts the app from the mounted DMG.
- `dist/AshtynMD-0.1.0.dmg` and its SHA-256 checksum are preserved from the
  verified source revision.
