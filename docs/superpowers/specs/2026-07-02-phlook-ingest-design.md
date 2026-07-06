# PHLOOK Ingest — Design Spec

**Date:** 2026-07-02
**Status:** Approved (interactive review)
**Sub-project 1 of 2** — sub-project 2 (in-app "Import from iPhone" via ImageCaptureCore) gets its own spec later and will reuse the engine built here.

## Problem

Media arrives on the Mac (Image Capture from iPhone, AirDrop, downloads) as raw files named `IMG_5305.HEIC`. The PHLOOK library (`~/Pictures/PHLOOK`) requires `YYYY-MM-DD_HH-MM-SS_OriginalName.ext` naming derived from capture metadata. Today that renaming only exists inside the osxphotos export ritual, which depends on Photos.app. We want a Photos-free path: dump files into a staging folder, run one command, files land in the library correctly named — with the same verification rigor used for the 3,021-file migration (counts, no overwrites, anomalies reported).

## Goals

- One command ingests `~/Pictures/PHLOOK_staging` → `~/Pictures/PHLOOK`.
- Capture dates come from media metadata, not filesystem accident.
- Never overwrite; never lose a file; anomalies are reported, not guessed at.
- The core logic lives in `PhlookCore`, tested, so the future ImageCaptureCore import reuses it unchanged.

## Non-goals

- No deletion from any device or from Photos.
- No content-hash dedup (name collision = presumed duplicate; skip and report).
- No GUI (that is sub-project 2 territory).
- No transcoding or metadata editing ever — files move byte-identical, rename only.

## Components

### 1. `CaptureDateExtractor` (PhlookCore)

Given a file URL, returns `(date: Date, source: DateSource)` where `DateSource` is `exif | videoMetadata | fileCreation`.

Resolution order:
1. **Images:** EXIF `DateTimeOriginal` (falling back to `DateTimeDigitized`, then TIFF `DateTime`) via ImageIO (`CGImageSourceCopyPropertiesAtIndex`) — already the pattern used by `LibraryScanner`. EXIF dates are capture-local wall time; format directly, no timezone conversion.
2. **Videos:** `com.apple.quicktime.creationdate` via AVFoundation (`AVAsset` common/metadata items). This value carries the capture-local timezone offset; format the name in that offset so the filename shows wall-clock time at capture. Fall back to the container `creationDate` (UTC) if absent.
3. **Fallback (both):** file creation date (birthtime), flagged as `fileCreation` in the report so the user knows the name may not be capture time (e.g., EXIF-stripped WhatsApp images).

### 2. `IngestService` (PhlookCore)

`ingest(staging: URL, library: URL) throws -> IngestReport`

Pipeline per file:
1. Enumerate staging, **skipping hidden files entirely** (`.osxphotos_export.db` lives there). Visible non-regular entries (directories, symlinks) are not hidden, so they are enumerated and reported as unsupported, left in staging — see the invariant below.
2. Partition by extension against `LibraryScanner.imageExts` / `videoExts`; unsupported extensions are left in place and reported.
3. Compute target name: `YYYY-MM-DD_HH-MM-SS_<original base name>.<original extension>` (extension case preserved as-is). If the base name already starts with a `YYYY-MM-DD_HH-MM-SS_` prefix (file was previously ingested/exported), keep the name unchanged rather than double-prefixing.
4. Collision policy — a target name that already exists (in the library **or** claimed earlier in this batch) means "presumed duplicate": leave the file in staging, report it, do not rename or overwrite. In-batch, first file wins.
5. Move (`FileManager.moveItem` — same-volume rename, atomic, content untouched). Never overwrite.

`IngestReport` (struct): `moved: [String]`, `skippedDuplicates: [String]`, `fallbackDated: [String]`, `unsupported: [String]`, plus computed `leftInStaging` and `isClean` (nothing skipped/unsupported).

Invariant: **every enumerated file is either moved or still in staging and named in the report.** No third state.

### 3. `phlook-ingest` (new executable target)

Thin CLI over `IngestService`:
- Defaults: staging `~/Pictures/PHLOOK_staging`, library `~/Pictures/PHLOOK`; overridable as `phlook-ingest [staging] [library]` positional args.
- Prints the report grouped by category with counts; explicit `staging is empty — nothing to ingest` case.
- Exit codes: `0` all moved (fallback-dated still counts as moved, but listed); `1` anything left in staging (duplicates/unsupported); `2` hard error.

### 4. Build integration

- `Package.swift`: add `.executableTarget(name: "phlook-ingest", dependencies: ["PhlookCore"])`.
- `Makefile`: `make ingest` → `swift run -c release phlook-ingest`.

## Error handling

- Staging dir missing → hard error with message (exit 2), don't create it silently.
- Move failure mid-batch (permissions, disk) → stop, report what moved so far and the error; already-moved files stay moved (re-running is safe because collision policy makes ingest idempotent).
- Unreadable/corrupt metadata → falls through to `fileCreation`, never blocks the move.

## Testing (swift-testing, TDD)

- `CaptureDateExtractor`: JPEG fixture with embedded EXIF date (extend `TestFixtures.writeJPEG` to accept a capture date); fixture without EXIF → `fileCreation` source; date formatting including single-digit months/hours.
- `IngestService`: happy path renames+moves; duplicate in library → skipped, file remains in staging; in-batch collision → first wins, second skipped; hidden files ignored; unsupported extension left and reported; empty staging → clean empty report; idempotency (second run over leftovers is a no-op with same report).
- Video metadata path: exercised via unit test on the metadata-item parsing given injected `AVMetadataItem`-like values (no binary video fixture committed); the AVAsset path itself is covered manually during `make ingest` smoke test.

## Workflow after shipping

1. Plug in iPhone → Image Capture → import to `~/Pictures/PHLOOK_staging` (originals, no conversion).
2. `make ingest` (or `swift run phlook-ingest`).
3. Open Phlook.app — new media indexed and visible.
4. Delete imported items from the phone, on the phone (iOS blocks USB-initiated deletion).
