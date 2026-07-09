# PHLOOK — Device Browser (Photos-style import) — Design Spec

**Date:** 2026-07-08 · **Status:** Approved (YOLO queue #8). Builds on PhoneImportController. Needs a real iPhone for full smoke.

## Goal

When the iPhone is connected, show a Photos-style import grid *inside* PHLOOK: thumbnails of the camera roll, split into **New** (never imported) and **Already imported**, with per-item selection, so the user picks exactly what to import instead of the current all-or-nothing "Import N new" button.

## Current state (already built)

`PhoneImportController` (ICC): device browsing, session, catalog, `PhoneImportPlanner.pending` diff against the imports table, `importAllNew()` serial download → `IngestService`, watchdog, cancel. The import bar shows "Import N new from <device>". This spec ADDS a browsing/selection UI on top; the all-new fast path stays.

## Design

- **Entry**: when a device is `.ready`, the import bar gains a "Browse…" button (beside "Import N new") that opens a **DeviceBrowserSheet** (full-window sheet/overlay).
- **Thumbnails**: `ICCameraFile.requestThumbnailData` (async, per item) — the controller exposes `func thumbnail(for identifier: String) async -> NSImage?` caching results. The sheet's grid lazily requests thumbnails for visible cells.
- **Sections**: two `LibraryScope`-free sections computed by the controller: `newItems` (PhoneImportPlanner.pending) and `importedItems` (the rest that are media). New section first, selectable (all pre-selected); Imported section shown collapsed/dimmed, not selectable (already in the library), each labeled "Imported".
- **Selection**: click/⌘-click/⌘A within the New section (mirror grid selection semantics, simplified). A footer: "Import N selected" + "Select All / None".
- **Import selected**: new controller method `importSelected(identifiers: Set<String>)` — same serial-download → record → ingest pipeline as `importAllNew` but over the chosen subset (refactor `importAllNew` to `importSelected(all pending ids)`). Progress + result sheet reuse the existing `ImportState`/`ImportResultSheet`.
- **Live/AAE**: unchanged from current ingest handling (AAE sidecars quarantined, live pairs land as two files).
- Sheet dismiss: Done/Esc closes without importing; import runs then shows the existing result sheet.

## Non-goals
- No editing/rotating on device; no delete-from-phone (iOS blocks it).
- No favorites/albums from the phone (v1 = camera roll flat).
- Keep the one-click "Import N new" bar button as the fast path — the browser is the considered path.

## Testing
- Pure/testable: `PhoneImportController` selection→identifier mapping and the `importSelected` subset filter (the pending/selected intersection logic) can be a small tested helper. The ICC thumbnail + device flow is hardware-only → human smoke with the real iPhone (browse, see New vs Imported, select a few, import just those, verify only those landed and the imports table recorded them).
- Keep all 162 tests green; new tests for any pure selection-subset logic.
