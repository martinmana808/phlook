# PHLOOK — Live Photos + Selection & Delete — Design Spec

**Date:** 2026-07-06
**Status:** Approved (user YOLO). One wave: delete must be live-pair-aware, so the features ship together.

## Part A — Live Photos (Photos.app parity, files-first)

### Problem

A Live Photo arrives from the iPhone as two files — `IMG_1234.HEIC` + a ~3s `IMG_1234.MOV`. Today PHLOOK shows both: the motion file clutters the grid as a "video," doubling every live shot. Photos.app shows one item, badged LIVE, playable on demand.

### Pairing rule (index-level; NO file is modified)

Two items form a live pair when ALL hold:
1. Identical filename minus extension (our ingest naming preserves the shared stem: `2026-07-06_12-00-00_IMG_1234.HEIC` / `…_IMG_1234.MOV`).
2. One is an image, the other a video.
3. The video's enriched `duration` is `0 < d <= 6.5` seconds (nil/sentinel/longer → not a pair; an unenriched video simply pairs later, after enrichment fills its duration).

Rationale: zero new metadata extraction, zero schema change, instant on the existing 17k rows, testable as a pure function. The embedded content-identifier (Apple MakerNote 17 / `com.apple.quicktime.content.identifier`) is the gold-standard link — documented here as future hardening if stem-matching ever misfires; not needed for v1.

### `LivePairs` (PhlookCore, pure)

`LivePairs.compute(items: [MediaItem]) -> LivePairs` where the result exposes:
- `hiddenVideoPaths: Set<String>` — motion halves, excluded from every visible list;
- `videoPath(forImagePath:) -> String?` — the motion half for a still.

### Behavior

- **Grid**: paired videos never render (any filter). Paired stills render under the Photos filter (they are images) with a `LIVE` badge (SF `livephoto` glyph), never a duration badge.
- **Viewer**: paired still shows the image plus a `LIVE` control (top bar); clicking it plays the motion file once, muted OFF (live photos have sound), then returns to the still. Prev/next order skips hidden motion files automatically (they're not in `visibleItems`).
- **Sidebar / details modal**: kind reads `Live Photo (HEIC + MOV)`; a second path row shows the motion file with its own Show in Finder.
- **Counts**: "N of M" and filter counts use visible items — motion halves don't count.
- Ingest, files, and DB rows are untouched — hiding is a view-level computation.

## Part B — Selection & Move to Trash

### Problem

No way to remove media from inside PHLOOK. Files-first answer: the macOS **Trash** is the safety net (fully recoverable via Finder) — no proprietary "Recently Deleted".

### Selection model (`LibraryViewModel`)

- `selectedPaths: Set<String>` published.
- Single click on a cell: select only that item. ⌘-click: toggle membership. Shift-click: contiguous range from the last-selected anchor within `visibleItems`. Click on empty grid space or Esc (grid context, viewer closed): clear. ⌘A: select all `visibleItems`.
- Visual: selected cells get a 3pt accent border + filled checkmark badge (top-right).
- Selection clears when the filter changes or items refresh removes selected paths (prune stale paths on refresh).

### Delete flow

- Context menu on a cell: if the clicked item is NOT in the current selection, the selection becomes just that item (Photos behavior). Menu item: `Move to Trash` (title shows count when >1: `Move 5 Items to Trash`).
- Delete/Backspace key in the grid deletes the selection; in the viewer it deletes the current item and advances (clamps at end; closes if library empties).
- Confirmation: a `confirmationDialog` always ("Move N item(s) to Trash? You can restore them from the Trash."). Destructive-styled button.
- **Live-pair aware**: deleting a paired still ALSO trashes its motion file (the pair is one user-facing item). Deleting a lone video trashes just it.
- Mechanics (`PhlookCore.LibraryTrasher`): for each path (plus paired motion paths), `FileManager.trashItem(at:)`; on success collect the path; per-item failure recorded, does not abort the batch. Then `MediaIndex.delete(paths:)` removes the rows of successfully-trashed files, and the UI refreshes from the DB (no full rescan needed). Thumbnails cache entries are left to age out.
- Report failures (file locked/missing) in a small alert listing names.

### `MediaIndex.delete(paths: [String])` (PhlookCore)

Single write transaction, `DELETE FROM files WHERE path IN (…)` (chunked if needed).

## Error handling

- Trash failure on some items: successful ones are gone (rows deleted), failed ones stay in grid + alert names them.
- File already missing on disk at delete time: treat as success for the row (prune the row).
- Viewer open on a deleted item: existing `refreshItems` path-re-resolution closes/advances it safely.

## Testing (swift-testing; UI by build + human smoke)

- `LivePairs`: pairs stem+image+video+short-duration; rejects long videos, nil-duration, sentinel, same-stem image+image; multiple pairs; `videoPath(forImagePath:)` lookup; stems with dots in original names (`archive.2024.HEIC`) pair on full basename-minus-final-extension.
- `MediaIndex.delete(paths:)`: rows gone, others intact; empty input no-op.
- `LibraryTrasher`: real temp files trashed (FileManager.trashItem works in tests), rows deleted, missing-file treated as prune, partial failure isolation.
- Human smoke: LIVE badge on real pairs; motion plays with sound and returns to still; select/⌘-click/⌘A/shift-click; right-click delete outside selection; Trash contains both halves of a deleted live pair; Delete key in viewer advances.
