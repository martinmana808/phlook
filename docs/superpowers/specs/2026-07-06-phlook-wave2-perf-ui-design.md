# PHLOOK Wave 2 — Performance, Grid Densities, Timeline Rail, Hover-Scrub — Design Spec

**Date:** 2026-07-06
**Status:** Approved (user YOLO). Built AFTER the phone-import feature (user priority).

## 1. Incremental scan (performance)

**Problem:** every launch re-hashes and re-reads EXIF for all ~17k files (~75 GB) — minutes of I/O for a library that barely changed.

- Schema (migration `user_version = 4`): `files` gains `file_size INTEGER`, `modified_at TEXT` (file mtime).
- Scan pass: for each file, `stat` first. If a row exists for the path AND size+mtime match → keep the row untouched (no hash, no EXIF read). Else → full extract as today (and store size+mtime).
- Prune (`deleteMissing`) unchanged. Enrichment pending-query unchanged (unchanged videos keep their enrichment because their rows are untouched).
- One-time cost: first launch after upgrade backfills size+mtime for every row (full rescan, as slow as today — once).
- Tests: unchanged file (same size+mtime) is not re-hashed (hash sentinel trick: manually corrupt stored hash, rescan, assert hash untouched); touched file (different mtime) is re-extracted; new/removed files behave as today.

## 2. Thumbnail memory (performance)

**Problem:** every instantiated `ThumbCell` holds its `NSImage` in `@State`; scrolling the whole library accumulates hundreds of MBs.

- `LibraryViewModel` gains a shared `NSCache<NSString, NSImage>` (`countLimit` 2_000). `thumbnail(for:)` checks the cache first, stores on load. Cells keep their `@State` but the cache is the backing store; eviction bounds total memory.
- No tests (app target); verified by scrolling smoke.

## 3. Grid densities

- Three levels: micro 80pt (current), medium 160pt, large 240pt.
- UI: segmented control with SF Symbols (`square.grid.4x3.fill` / `square.grid.3x2` / `square.grid.2x2`) beside the media filter; keyboard ⌘+ / ⌘− steps through levels.
- Thumbnail request size = 2× cell size (ThumbnailCache already takes a size; larger sizes generate on demand and cache on disk alongside the existing 160s).
- Duration badge and ▶ glyph scale with the cell (font `.caption2` → `.caption` at large).
- Choice persists in `UserDefaults` (`gridDensity`).

## 4. Timeline scrubber rail (Grok-style)

Reference: user-supplied screenshot — a thin vertical rail of tick marks hugging the right edge, vertically centered, minimal.

- Rail maps the **date range of `visibleItems`** (newest top, matching sort) onto its height. One tick per month with >0 items; year boundaries get a longer tick; subtle color, brightens on hover.
- Hover: a floating bubble shows "Mar 2026" for the month under the cursor.
- Click or drag: the grid scrolls (ScrollViewReader `scrollTo`) to the first item of that month; dragging scrubs continuously (throttled to one jump per month change).
- Rail fades to low opacity when the mouse is elsewhere; hidden entirely when the viewer is open or fewer than 2 months exist.
- Pure logic (month bucketing: `[(monthStart: Date, firstItemPath: String, count: Int)]` from `[MediaItem]`) lives in PhlookCore (`TimelineIndex`) with tests: bucketing, ordering, nil-date items grouped into a trailing "Undated" bucket, year-boundary flags.

## 5. Hover-scrub video previews

- Hovering a video cell for 350ms starts a **muted, looping** inline preview (AVPlayer + AVPlayerLayer in an NSViewRepresentable sized to the cell); mouse-exit reverts to the thumbnail and tears the player down.
- At most ONE active preview player app-wide (hovering a new cell steals it) — a tiny `HoverPreviewCoordinator` (app target) owns the single player.
- Skips items whose duration is the -1 sentinel or nil.
- No autoplay of audio ever. No scrub-by-mouse-position in v1 (plain loop; positional scrubbing is a refinement).
- No unit tests (AVPlayer + hover); human smoke.

## Order of implementation

1 (incremental scan) → 2 (thumb cache) → 3 (densities) → 4 (rail) → 5 (hover-scrub). Each lands as its own reviewed task; 1–2 ship value even if the wave pauses.
