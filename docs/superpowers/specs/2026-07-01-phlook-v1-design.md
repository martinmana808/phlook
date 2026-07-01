# PHLOOK v1 — "The Window" — Design Spec

_Date: 2026-07-01_

## Vision

**PHLOOK is the Photos.app experience you already know, but your media stays as plain files in real folders on disk — no giant proprietary library blob.** The database is a rebuildable index that sits *beside* your files, never a cage around them. Delete the DB, rebuild it from the folder, lose nothing.

v1 ("The Window") is a fast, beautiful, **view-only** media browser that lets you escape Photos.app and browse your whole library faster than Finder. Search and cleanup (the "++++") layer on in later phases, powered by a brain that already exists.

## Scope

### In scope (v1)
- **Ingest**: a repeatable "Import from Photos" pipeline that exports true originals + metadata into the PHLOOK folder.
- **Library layout**: plain files on disk, date-organized; a rebuildable index (`phlook.db`) + thumbnail cache beside it.
- **Background indexer**: scans the folder, extracts EXIF, generates thumbnails, watches for new files.
- **3 views**: Micro grid, Normal listing, Fullscreen detail (+ metadata panel).
- **Timeline rail**: VS Code-style Years→Months density heatmap navigator.
- **Native interactions**: Quick Look (spacebar), Show in Finder (⌘R / right-click), drag-out to Final Cut, sort by date, basic filter by type.
- **Sidebar**: All Media · Map · Locked (Locked UI present; password-gating fully implemented in v2).

### Explicitly OUT (cut from Photos.app, permanently)
- Photo/video **editing** (crop, filters, adjustments, retouch) — view only; editing stays in Final Cut etc.
- **Face / people** recognition.
- **Memories / auto-montages / slideshows / "For You"**.
- **Any cloud / sync** (iCloud, Shared Albums, web) — 100% local.
- **Albums** — user never uses them; dropped entirely.

### Deferred to later phases
- **v2 "Organize"**: Locked password-gating, Map view, import polish, Finder-tag read/write.
- **v3 "The Brain"**: wire existing CLIP embeddings + OCR (`phlook.db` already has 6,279 embeddings, 2,800 OCR rows) → semantic search, text-in-image search, smart filtering; audio/Whisper search.
- **v4 "The Janitor"**: duplicate/frenzy finder, quality culling (green/yellow/red), compression slider.

## Architecture

The key lesson from the shelved v2 (Electron + always-on Python FastAPI server): **no always-running backend.** v1 is a self-contained native app plus a one-shot import tool.

- **PHLOOK.app** — native **SwiftUI/AppKit** (macOS only). Does all browsing itself: reads files, extracts EXIF via **ImageIO / AVFoundation**, generates thumbnails, renders the 3 views. No Python required to browse.
- **`phlook.db`** (SQLite, beside the library) — index/cache: path, hash, date_taken, file_type, width, height, thumbnail ref, last_scanned. (Extends the existing schema: `files`, `ocr_data`, `embeddings`.) Rebuildable from files.
- **Thumbnail cache** — generated thumbnails stored on disk, keyed by file content hash, at 2 sizes (micro + normal).
- **Background indexer** (in-app) — on launch scans the PHLOOK folder, upserts into `phlook.db`, generates missing thumbnails; watches for new/changed/removed files via **FSEvents**.
- **Ingest tool** — `osxphotos` (Python CLI in the project `venv`) invoked as a **subprocess** by the "Import from Photos" action. Not a live server.
- **AI brain** — separate, optional Python/CoreML piece; NOT run in v1.

### Metadata guarantee (non-negotiable)
- On import, `osxphotos --exiftool` writes Photos metadata (date, GPS, title, keywords) **into each file's EXIF/XMP**.
- PHLOOK **reads** metadata from files; v1 never modifies or strips originals.
- The index only caches metadata for speed; the file is always authoritative.

## Library layout

```
~/Pictures/PHLOOK/
  2024/2024-06-28_19-30-11_IMG_1234.heic
  2025/2025-01-02_08-14-55_VID_0007.mov
  ...
phlook.db                 # index/cache beside the library
.phlook/thumbnails/       # thumbnail cache (content-hash keyed)
```
- Physical storage: date-organized (year subfolders), files named `YYYY-MM-DD_HH-MM-SS_OriginalName.ext` (matches existing convention from `antigravity.py`).
- Note: the existing PHLOOK folder already holds ~13,947 files from an earlier `antigravity.py` migration. Future imports use `osxphotos --update`; overlap between the legacy import and osxphotos is tolerated in v1 and resolved by the v4 duplicate finder.

## The ingest pipeline ("Import from Photos")

Replaces the fragile direct-read of Photos internals with **osxphotos** (reads Photos' own DB, exports true originals):
- Export **unmodified originals only** (skip edited versions).
- `--exiftool` → write date/GPS/title/keywords into each file.
- File naming template → `YYYY-MM-DD_HH-MM-SS_{original_name}.{ext}`.
- Directory template → year folders.
- `--update` → incremental re-runs ("import today's new photos").
- Surfaced as a documented PHLOOK command + an in-app "Import from Photos" button that shells out to it and reports progress.

## The 3 views + navigation

All views share selection + scroll position; switch via top-bar segmented control.

1. **Micro grid** — smallest thumbnails, maximum density, virtualized (`NSCollectionView` + prefetch). Scan 50k+ smoothly.
2. **Normal listing** — larger thumbnails with filename · date · type.
3. **Fullscreen detail** — one item large; right-side **metadata panel**: date taken, camera make/model, lens, ISO/shutter/aperture, dimensions, file size, format, GPS mini-map, file path. Arrow keys navigate.

- **Timeline rail** (left) — Years → Months with a **density heatmap** (bar length/color = item count per period). Click to jump the main view; doubles as navigator/scrollbar.
- **Top bar** — 3-view switcher, sort (date asc/desc), filter by type (image/video), search box (present; wired to brain in v3).
- **Sidebar** — All Media · Map (v2) · Locked (v2 password).
- **Interactions** — Spacebar → `QLPreviewPanel` Quick Look; ⌘R / right-click → Show in Finder; drag item → drags the file URL out (into Final Cut); double-click → fullscreen detail.

## Performance approach

- `NSCollectionView` with virtualization + prefetching for the grids.
- Thumbnails pre-generated in the background (via `QLThumbnailGenerator` / ImageIO) and cached on disk; UI never blocks on full-res reads.
- Indexer runs off the main thread; incremental via FSEvents so re-scans are cheap.
- Target: smooth scroll at 50k+ items on the existing library.

## Testing

- **Indexer**: unit tests over a fixture folder — correct EXIF date extraction (image + video), dimensions, hash stability, add/remove/rename handled via FSEvents.
- **Ingest**: integration test that `osxphotos` export lands files with expected names + embedded EXIF (using a small test Photos library or mocked osxphotos output).
- **Thumbnail cache**: correct keying by content hash; regeneration on file change.
- **DB rebuild**: delete `phlook.db`, re-index, confirm identical index state (the "no cage" guarantee).
- **Views**: smoke/UI tests for view switching, Quick Look invocation, Show in Finder, drag-out providing a file URL.

## Tech stack

- **App**: Swift + SwiftUI/AppKit, macOS-only.
- **Native frameworks**: ImageIO, AVFoundation, QuickLookUI, FSEvents, MapKit (v2), CoreML (v3).
- **Index**: SQLite (`phlook.db`).
- **Ingest**: `osxphotos` (Python CLI, existing `venv`).
- **AI (v3)**: existing CLIP/OCR Python or CoreML equivalents.

## Open items / decisions made by trust
- Exact detail-panel metadata fields — chosen sensible defaults above; easy to adjust.
- Whether Locked shows as an empty/disabled sidebar item in v1 or is hidden until v2 — default: visible but disabled with a "v2" affordance.
