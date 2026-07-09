# PHLOOK — Live Photo Poster-Frame Picker (non-destructive) — Design Spec

**Date:** 2026-07-08 · **Status:** Approved (YOLO queue #10). NON-DESTRUCTIVE by design — originals never rewritten.

## Goal

For a Live Photo (HEIC still + short MOV), let the user pick a different frame from the motion clip to use as the item's "poster" (the still shown in the grid and before playback) — exactly like Photos' "Make Key Photo", but without ever modifying the original HEIC or MOV.

## Non-destructive mechanism

- Store the chosen frame's **time offset (seconds into the MOV)** in the DB, keyed to the still. Migration `user_version = 7` adds `poster_time REAL` to `files` (NULL = use the original HEIC, the default). No file is written.
- Rendering: when a live still has a non-null `poster_time`, PHLOOK renders its grid thumbnail AND viewer still by extracting that frame from the paired MOV via `AVAssetImageGenerator` (cached), instead of decoding the HEIC. When `poster_time` is null → the HEIC as today.
- "Reset to Original" clears `poster_time` (back to the HEIC). Fully reversible, always.

## Components

- **Core**: `MediaItem.posterTime: Double?` (col `poster_time`, migration v7, guarded like prior columns; NOT touched by scan upsert — only an explicit setter writes it, mirroring `hidden`). `MediaIndex.setPosterTime(path:time:)` (time nil clears). Upsert preserves it in both branches (user intent survives rescan/replacement like `hidden`).
- **App — rendering**: a `PosterRenderer` (app) `func posterImage(for item: MediaItem, motionPath: String, time: Double, size: Int) async -> NSImage?` using `AVAssetImageGenerator` (appliesPreferredTrackTransform = true, tolerance zero for exact frame), cached by (path, time, size). `LibraryViewModel.thumbnail(for:size:)` gains: if `vm.isLive(item)` and `item.posterTime != nil` and a motion path exists → return the poster frame; else the existing ThumbnailCache path. Viewer's still load (`loadCurrent`) does the same for the displayed image.
- **App — picker UI**: `PosterPickerSheet` — opened from the viewer's LIVE item (a "Set Poster…" button in the top bar for live stills, next to LIVE). Shows the MOV in an AVPlayer with a scrubber (or a filmstrip of sampled frames); user scrubs to a frame; "Use This Frame" saves `player.currentTime()` seconds via `vm.setPosterTime(item, time:)`; "Reset to Original" clears. On save: setPosterTime → invalidate that item's cached thumbnails → epoch-refresh so grid updates.
- `setPosterTime` in VM: `service.mediaIndex.setPosterTime(...)`, drop cached thumbnails for the path, refreshItems.

## Non-goals
- Only Live Photos (items with a motion pair) — non-live photos have no motion to pick from; the "Set Poster…" affordance only appears for live stills.
- No cropping/rotation/edits — just frame selection.
- No writing a new still file (that's the whole point — DB metadata only).

## Testing
- Core: migration v7 (poster_time default null, guarded); `setPosterTime` round-trip + clear; upsert preserves poster_time against rescan (mirror the `hidden` "rescan never changes it" test).
- `PosterRenderer` frame extraction over a generated test MOV (reuse `TestFixtures.writeQuickTimeMovie`): extract a frame at t=0.5, assert a non-nil image of expected dims — deterministic enough.
- Human smoke: open a Live Photo, Set Poster…, scrub, Use This Frame → grid thumbnail changes to the chosen frame; Reset → back to original; relaunch → poster persists (DB-stored); confirm the HEIC/MOV files on disk are byte-unchanged.
