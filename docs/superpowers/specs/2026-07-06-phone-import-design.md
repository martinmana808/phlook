# PHLOOK — Import from iPhone (ImageCaptureCore) — Design Spec

**Date:** 2026-07-06
**Status:** Approved (user: "THIS IS THE MOST IMPORTANT TO ME", YOLO)
**This is Plan 3 proper** — the in-app import that retires Image Capture and Photos.app as middlemen.

## Problem

Getting media off the iPhone requires a middleman (Photos.app or Image Capture), and neither remembers what was already imported once the library empties: Photos re-offers everything, Image Capture has no memory at all. PHLOOK owns a database — the memory of "have I imported this?" belongs there, keyed to the *import event*, not to what files currently exist anywhere.

## Goals

- Plug in iPhone → PHLOOK shows "Import N new from <device>" — N counts only never-imported items.
- One click: downloads originals to staging → runs the existing `IngestService` → grid shows them.
- The imports table remembers item identifiers forever; deleting/moving library files never causes re-offers.
- A clean run ends with the familiar green light: safe to delete those items from the phone (on the phone).

## Non-goals

- No deletion from the device (iOS blocks USB-initiated deletion anyway).
- No per-item selection UI in v1 — import-all-new only (selection is a later refinement).
- No Wi-Fi/AirDrop transport; USB (and whatever ImageCaptureCore exposes) only.
- Live-Photo pairing/AAE handling beyond what IngestService already does (separate wave).

## Components

### 1. Imports memory (PhlookCore — testable)

- `MediaIndex` gains table (migration bump, `PRAGMA user_version = 3`):
  ```sql
  CREATE TABLE IF NOT EXISTS imports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_name TEXT NOT NULL,
      item_identifier TEXT NOT NULL,
      imported_at TEXT NOT NULL,
      UNIQUE(device_name, item_identifier)
  );
  ```
- API: `recordImport(device: String, identifier: String)` (idempotent — INSERT OR IGNORE), `importedIdentifiers(device: String) -> Set<String>`.
- `PhoneImportPlanner` (pure): given `[CameraItemDescriptor]` (name, identifier, isMediaFile) and the recorded set → `[CameraItemDescriptor]` still pending. `CameraItemDescriptor.identifier`: the composite `"\(name)|\(creationDateISO8601)|\(fileSize)"` (deterministic, tested).

### 2. `PhoneImportController` (app target — ObservableObject, ICC delegate)

- `ICDeviceBrowser` with camera mask, running while the app runs.
- On camera connect: open session, wait for the complete content catalog, map `ICCameraFile`s (media extensions only — reuse `LibraryScanner` ext sets) to descriptors, diff via `PhoneImportPlanner` → publish `pendingCount`, `deviceName`, `state`.
- `importAll()`: sequentially `requestDownloadFile` into `~/Pictures/PHLOOK_staging` (original files, no conversion); after each successful download, `recordImport` immediately (crash-safe: a re-run skips downloaded items); publish progress `(done, total)`.
- After the last download: run `IngestService(staging:library:).ingest()`, publish the `IngestReport`, refresh the library (`LibraryViewModel.load()`).
- Device states: no device / device connecting (session opening, trust prompt on phone) / ready with N pending / importing (m of n) / ingested (report) / error (message, retryable). All published for the UI.
- Failure of one download: record nothing for that item, continue with the rest, list failures in the final state.

### 3. UI (app target)

- Grid top bar (next to the filter): when a device is ready, a prominent button `📱 Import N new from <name>`; N == 0 shows quiet "Up to date" text instead. While importing: inline progress `Importing m of n…`.
- On completion: a sheet with the `IngestReport.summaryText` content — including the green `CLEAN — safe to delete originals from the device` line — and a Done button. Failures listed if any.
- Trust hint: while the session opens, show "Unlock your iPhone and tap Trust…" so the user knows why nothing is happening.

## Error handling

- Phone locked / trust declined → state error with a human sentence; retry button re-opens the session.
- Download failure mid-batch → skip, continue, report failed names at the end; nothing recorded for failed items.
- Staging missing → created by the controller before downloading (import staging is ours, unlike ingest's precondition).
- App quit mid-import → already-downloaded items are recorded and sit in staging; next launch's ingest… does NOT run automatically (user re-triggers import or runs make ingest). Recorded identifiers prevent re-download.

## Testing (swift-testing — hardware-free parts)

- Migration v3: imports table exists on fresh + upgraded DBs; idempotent reopen.
- `recordImport` idempotency (UNIQUE ignore); `importedIdentifiers` round-trip.
- `PhoneImportPlanner`: diffing (all new / some recorded / all recorded), non-media exclusion, composite-identifier fallback determinism.
- ICC device flow: NOT unit-testable without hardware — human smoke with the real iPhone is the acceptance gate (plug in, trust, import, verify count matches, re-plug shows 0 pending, delete on phone).

## Reused unchanged

`IngestService` (rename/verify/merge, collision-safe), `IngestReport.summaryText`, staging dir, `LibraryViewModel.load()`.
