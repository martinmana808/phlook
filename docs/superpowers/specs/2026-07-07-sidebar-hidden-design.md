# PHLOOK — Left Sidebar + Hidden (auth-gated) — Design Spec

**Date:** 2026-07-07 · **Status:** Approved (user: "#6 and #7 Go ahead! DO IT")
Tracker items #6 and #7.

## Part A — Left sidebar

A persistent source list (native `NavigationSplitView`-style column, collapsible) replacing the cramped segmented filter as the primary navigation:

- **Library**: All · Photos · Videos · Live Photos
- **Kinds** (detectable from existing metadata, no ML): Screenshots · Selfies
- **Hidden** (Part B) — last section, lock icon
- Selecting a row drives `vm.filter`, generalized from the 3-case enum to a `LibraryScope` enum covering all rows. Counts shown per row (computed with visibleItems machinery, cached like `timeline`).
- The old segmented filter control is removed; density picker + ImportBar stay in the top bar.

### Detection rules (index-time, stored — migration `user_version = 5`)

New column `kind_flags INTEGER NOT NULL DEFAULT 0` (bitmask: 1 = screenshot, 2 = selfie). Populated during full extraction (incremental scan means new/changed files only) by `KindDetector` (PhlookCore, pure, tested):
- **Screenshot**: PNG with no camera EXIF (no `TIFF Make`/`Model`), OR EXIF `UserComment == "Screenshot"`. (Existing rows backfill via a one-time enrichment-style pass over images, same pattern as video enrichment: `kind_flags IS NULL`-equivalent via a `kinds_scanned` marker — simpler: backfill pass keyed on migration, nulling nothing; a `kindsNeedingDetection` query where `kind_flags = -1` sentinel default for pre-v5 rows, 0 after scan.)
  - Simplification: migration sets existing rows' `kind_flags = -1` ("unknown"); detector pass processes `= -1` rows in the background like the video enricher; new scans set flags at extraction time.
- **Selfie**: EXIF `LensModel` contains "front" (case-insensitive).

### Date-range slider

- A FROM–TO dual-anchor slider at the sidebar's bottom, spanning the library's date range (min/max of dateTaken), bucketed by month.
- Dragging either anchor filters `visibleItems` (composes with the selected scope). "Reset" clears.
- Pure range logic in Core (`DateRangeFilter`), tested; slider UI app-side.

## Part B — Hidden (Photos-parity, auth-gated)

- **Hide**: context menu on selection → "Hide N Item(s)" (⌘H). Sets `hidden INTEGER DEFAULT 0` → 1 (same migration v5). Hidden items vanish from every scope, count, timeline bucket, and the viewer's navigation (excluded in `rebuildVisible`). Files never move — the flag lives in our DB.
- **Reveal**: sidebar "Hidden" row. Clicking it prompts **LocalAuthentication** (`LAContext.evaluatePolicy(.deviceOwnerAuthentication…)` — Touch ID with password fallback, i.e. "your Mac's password", matching Photos). On success the Hidden scope unlocks for the session (relocks on app quit or after clicking any other scope + 5 minutes, whichever first — keep simple: relock when navigating away).
- In the Hidden scope: normal grid; context menu shows "Unhide" instead of "Hide"; delete works as usual.
- Unauthenticated state shows a lock placeholder ("Hidden items are locked — click to authenticate").
- Hide/unhide is instant and non-destructive; trash from Hidden behaves like anywhere else (pair-aware).
- Live pairs: hiding a paired still hides the pair (motion files are never independently visible anyway); `LivePairs` computes over ALL items so pairing is unaffected by hidden state.

## Error handling

- LAContext unavailable (no Touch ID, no password?) → fall back to `.deviceOwnerAuthentication` (password); if that policy can't evaluate, show the error and keep locked.
- Auth denied → stay locked, no error dialog spam (LA shows its own UI).

## Testing

- Core: `KindDetector` (screenshot/selfie rules against synthesized EXIF fixtures — extend `TestFixtures.writeJPEG` with optional maker/lens fields), migration v5 (flags default, -1 backfill sentinel, hidden column), scope filtering incl. hidden exclusion (`LibraryScope.matches`), date-range compose logic, hide/unhide round-trip (`MediaIndex.setHidden(paths:hidden:)`).
- App/auth flow: human smoke (LA cannot be unit-tested).
