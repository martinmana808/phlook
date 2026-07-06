# PHLOOK Viewer & Video Metadata — Design Spec

**Date:** 2026-07-06
**Status:** Approved (interactive review)
**Scope:** Plan 2, wave 1 — the first richer-UI wave on top of the v1 micro-grid.

## Problem

The grid is "just squares." Videos are indistinguishable from photos and carry no dates (extraction was deferred in v1), so all ~5,900 videos clump undated at the bottom of the date-sorted grid. There is no way to view media large, play a video, see metadata, or reveal a file in Finder without leaving the app.

## Goals

- Videos show duration on their grid cell and sort chronologically like photos.
- Double-click (or context-menu Open) shows any item filling the app window; videos play with native controls.
- ← → arrows, on-screen chevrons, and two-finger trackpad swipe move through neighbors in grid order.
- A details sidebar slides open in the viewer showing the item's metadata.
- Right-click on a grid cell: **Open**, **View Details**, **Show in Finder**.

## Non-goals (this wave)

- Grid density levels, timeline rail, Quick Look, drag-out to Final Cut, folder sidebar (later waves).
- Editing of any kind; no metadata writing.
- No wrap-around navigation (ends clamp).
- No separate viewer window; the viewer is an overlay inside the existing window.

## Components

### 1. Schema: `duration` column (PhlookCore)

- `MediaItem` gains `duration: Double?` (seconds; nil for images and not-yet-enriched videos). Column `duration REAL`.
- `MediaIndex.migrate()` adds the column to existing databases: check `PRAGMA table_info(files)` (via GRDB's column introspection) and `ALTER TABLE files ADD COLUMN duration REAL` only when absent. Idempotent across launches.
- `upsert` preserves an existing row's `duration`, `date_taken`, `width`, and `height` when the incoming scan item has nil for them (the scanner knows nothing about videos; enrichment must not be wiped by the next scan).

### 2. `VideoMetadataEnricher` (PhlookCore)

`enrich(index: MediaIndex) async -> Int` (returns count enriched):

- Selects video rows where `duration IS NULL OR date_taken IS NULL`.
- Per file, via modern async AVFoundation only: `duration` from `AVAsset.load(.duration)` (seconds); `dateTaken` from the existing `CaptureDateExtractor` (QuickTime creationdate → container date → file creation); `width`/`height` from the first video track's `naturalSize` (with `preferredTransform` applied so rotated portrait video stores portrait dimensions).
- Writes each row back as it completes. Unreadable/corrupt video: set `duration = -1` sentinel (meaning "tried, unreadable" — excluded from future enrichment queries; UI shows no badge), never throws out of the loop.
- `IndexingService.reindex()` gains a post-pass that runs the enricher; `LibraryViewModel.load()` refreshes `items` after enrichment completes so dates/badges appear. The ~5,900-video backfill happens on first launch after the update, in the background, behind the existing "Updating…" chip.

### 3. Grid additions (Phlook app target)

- `ThumbCell`: for `fileType == "video"`, a bottom-right capsule badge with formatted duration over the thumbnail, plus a small ▶ glyph bottom-left. No badge while duration is nil or the -1 sentinel.
- Duration formatting is a pure function in PhlookCore (`DurationFormatter.string(seconds:)`): `0:34`, `12:05`, `1:12:05` (h only when ≥ 1h; zero-padded mm/ss appropriately). Nil/negative → nil.
- Double-click on a cell opens the viewer at that item. (Single click: no behavior this wave.)
- `.contextMenu`: **Open** (viewer), **View Details** (viewer with sidebar open), **Show in Finder** (`NSWorkspace.shared.activateFileViewerSelecting`).

### 4. `ViewerView` overlay (Phlook app target)

- Presentation: ZStack overlay in `ContentView` covering the whole window when `vm.viewerIndex != nil`; dark backdrop (`.black`); grid stays alive underneath.
- Images: async full-size load, downsampled via ImageIO thumbnailing (`kCGImageSourceThumbnailMaxPixelSize` ≈ 2× screen max dimension) so 48MP HEICs don't balloon memory.
- Videos: AVKit `VideoPlayer` with native controls. Player is created per item and torn down on navigation/close (no background playback).
- Navigation: `viewerIndex` moves through `vm.items` (current grid order), clamped at both ends. Inputs: ← → keys, hover-visible chevron buttons, two-finger horizontal trackpad swipe (scroll-wheel deltaX with a threshold + debounce, via a local NSEvent monitor active only while the viewer is open).
- Chrome: top bar (hover-visible) with ✕ close (also Esc), filename, "N of M" position, and ⓘ sidebar toggle (also ⌘I).
- Index math (clamp, position string) lives in the view model as pure testable functions.
- When `vm.items` refreshes while the viewer is open (background reindex/enrichment), the viewer re-resolves its current item by path in the new array; if the path is gone, the viewer closes. Prev/next always operate on the current array.

### 5. Details sidebar (Phlook app target + PhlookCore)

- Trailing panel, 280pt, slides in/out with animation; toggled by ⓘ / ⌘I; state persists while navigating prev/next (stays open, content updates).
- Contents from a testable `MediaDetails.from(item: MediaItem, fileManager: FileManager) -> MediaDetails` in PhlookCore: filename, date taken (formatted, or "Unknown"), dimensions ("4032 × 3024"), duration (videos, formatted), file size (formatted, from disk attributes), kind ("HEIC image", "QuickTime movie" from extension), full path.
- Sidebar actions: copy path (`NSPasteboard`), Show in Finder.

## Error handling

- Missing file at viewer time (moved/deleted behind our back): viewer shows a "file missing" placeholder; navigation still works; no crash.
- Enricher: per-file failures marked with the -1 sentinel and skipped thereafter; a failure never aborts the batch.
- Thumbnail/full-image decode failure: existing gray placeholder behavior.

## Testing (swift-testing, TDD — core logic only; SwiftUI views verified by build + manual smoke)

- Migration: fresh DB has `duration` column; pre-existing DB (created without the column) gains it; running migrate twice is safe; upsert preserves enriched `duration`/`date_taken` against a nil-valued incoming scan row.
- `TestFixtures.writeQuickTimeMovie(at:duration:)` — a real tiny `.mov` generated with `AVAssetWriter` (solid-color frames, ~1s). This finally gives automated coverage of the AVAsset happy path flagged in earlier reviews.
- Enricher: fills duration/date/dims on the fixture movie; corrupt file gets -1 sentinel; second run enriches nothing (idempotent).
- `DurationFormatter`: 34 → "0:34", 725 → "12:05", 4325 → "1:12:05", nil/negative → nil.
- Viewer index math: clamp at 0 and count-1; position string "3 of 10".
- `MediaDetails`: assembly from a MediaItem + real temp file (size/kind/dimensions), video vs image variants, missing file → nil size with placeholder text.

## Manual smoke (after build)

`make run-app`: badges visible on video cells; double-click a photo and a video; play the video; arrows/swipe/chevrons; Esc; ⌘I sidebar with correct metadata; right-click all three menu items; grid chronology visibly fixed after backfill completes.
