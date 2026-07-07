# PHLOOK — Rail v4 Scrubber, Viewer Zoom (animation + slider), Years/Months/All — Design Spec

**Date:** 2026-07-07 · **Status:** Approved (user: "#15 #16 #17 NOW. YOLO."; rail: "remove the spine — just a scroll bar with years and months as you hover")
Tracker #15, #16, #17, #18-replacement.

## Part 1 — Rail v4: the hover scrubber (replaces v3 entirely)

Delete the bars/spine/year-labels concept. The rail becomes a minimal scrubber strip on the grid's right edge:

- Idle: nearly invisible — a slim (~14pt) hover zone; optionally a faint rounded handle indicating relative position of the current scroll viewport (v1: skip viewport tracking; strip is invisible until hover).
- Hover: a floating capsule appears at cursor height showing **"Mar 2026"** (month + year, from the same time-linear mapping: top = newest, bottom = oldest, over the CURRENT scope's dated span). A thin horizontal indicator line marks the cursor position.
- Click or drag: label tracks continuously; ONE jump on release (proven anti-stutter). 
- Hidden when < 2 dated months or viewer open. `TimelineIndex` stays as the data source (buckets, yFraction); only the view changes.

## Part 2 — #16 Viewer zoom slider (+ pan)

- Viewer top bar gains a zoom slider (1×–4×) for IMAGES (disabled/hidden for videos). Reset-to-fit button (or double-tap already closes — so a small "1×" button).
- Implementation: the image sits in a `ScrollView([.horizontal, .vertical])` sized `fitSize * zoom`; slider drives zoom; scroll = pan. Pinch (`MagnifyGesture`) also drives zoom when available.
- Zoom resets to 1× on navigation to another item.
- Downsampling note: at >1× re-decode at a larger max pixel (cap ~2× screen) so zooming isn't blurry — reuse `downsampledImage` with a higher cap when zoom > 1.5×, swap in when loaded.

## Part 3 — #15 open/close zoom animation

Photos-style expand: on double-click open, the media appears to grow FROM its grid cell to full-window; on close it shrinks back.

- Mechanism: capture the tapped cell's frame in window coordinates (anchor preference on ThumbCell, resolved at open time) into `vm.viewerOriginFrame: CGRect?`. ViewerView, on appear, starts its media layer at that rect (position + size via `.scaleEffect`/`.position` or explicit frame interpolation) and animates (~0.28s easeOut) to the fitted rect; on close (Esc/✕/double-click) animates back to the (re-resolved, may have scrolled) origin rect, falling back to a plain fade when the cell is no longer materialized. Chrome (top bar/chevrons/backdrop) fades in after the expansion.
- Applies to the still/thumbnail layer; videos animate the poster frame then swap the player in at full size.
- v1 tolerance: if pixel-perfect matched-geometry fights the ZStack architecture, an approximate frame-interpolation (cell rect → full rect) is acceptable; a crossfade is NOT.

## Part 4 — #17 Years / Months / All Photos

A Photos-parity time browser. A segmented control (top center of the grid area): **Years · Months · All**.

- **All** = the existing grid, unchanged.
- **Months**: vertical list of month cards, newest first: each card = large key photo (first item of the month), overlaid label ("March 2026") + count. Click → switches to All scrolled to that month's first item.
- **Years**: grid of year cards (2-3 per row): key photo + year + count. Click → Months view scrolled to that year's first month.
- Cards derive from `TimelineIndex` buckets (Months) and a year-level rollup (`TimelineIndex.yearBuckets(items:)` — new pure Core function + tests: year label, firstItemPath, count, key photo path = first item).
- View mode is per-session state (`vm.timeMode: TimeMode = .all`), not persisted; scope/date filters apply to all three modes (cards computed from visibleItems).
- Selection/hide/trash/context menus operate only in All (cards are navigation, not selection surfaces) — v1.

## Testing

Core: `TimelineIndex.yearBuckets` (grouping, counts, key paths, order); month-card mapping reuses existing buckets (already tested). App: build + human smoke (animation feel, zoom, scrubber, mode navigation). Zoom math (fit-size × zoom clamping) as pure helpers where practical.
