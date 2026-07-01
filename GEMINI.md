# PhlookDev - Photo & Video Migration Tool

## Project Summary
PhlookDev is a Python-based tool designed to migrate a massive library of photos and videos from the Apple Photos ecosystem (or any nested folder structure) into a flattened, organized directory.
Key features:
- **Recursive Scan**: Targets a specific folder (e.g., `PHLOOK`) and processes all subdirectories.
- **Metadata Extraction**: Prioritizes internal metadata (EXIF "Date Taken" for images, QuickTime "Creation Date" for videos) over file system dates.
- **Smart Renaming**: Renames files to `YYYY-MM-DD_HH-MM-SS_OriginalName.ext` to ensure chronological ordering.
- **Collision Handling**: Appends counters to filenames to avoid duplicates.
- **Cleanup**: Removes empty directories after moving files.

## Project Brain
Top-level goal: Flatten and rename media files from `PHLOOK/originals` (or similar) to a root `PHLOOK` directory.

## History
### [2025-12-20] Project Initialization
- User requested a "Flatten and Rename" script.
- Verified Paths: Checking `~/Pictures/PHLOOK/originals`.

### [2025-12-20] Migration Execution
- **Audit**: Analyzed 14,103 files. Confirmed 97% had valid internal metadata (EXIF/Video).
- **Tagging**: Tagged 452 fallback files with "Yellow" tag in Finder.
- **Flattening**: Moved all files from `originals/0..F/` to `originals/` root.
- **Migration**: Renamed and moved all files to `~/Pictures/PHLOOK/` using `antigravity.py`.
- **Outcome**: Successful flattening and dating of library.

### [2025-12-21] AAE File Cleanup
- **Analysis**: Detected 1,353 `.AAE` sidecar files in the library.
- **Execution**: safe deletion using `cleanup.py`.
- **Outcome**: Reclaimed ~1.2MB space and decluttered library.

### [2025-12-21] Core Intelligence ("The Brain") | [Technical Details](./GEMINI--logs.md#log-20251221-core-intelligence)
- **Architecture**: Implemented SQLite database, Apple Vision OCR, and CLIP semantic search.
- **Features**: Search bar now finds photos by concept ("dog") and text content.
- **Integration**: Added Native Finder Tagging support.

### [2025-12-21] Phlook App Initialization (Phase 1 & 2) | [Technical Details](./GEMINI--logs.md#log-20251221-phlook-foundation)
- **Blueprint**: Created `PHLOOK_BLUEPRINT.md` outlining the Electron + React + Python architecture.
- **Frontend**: Scaffolding Electron/React app in `/app`.
- **Backend**: Created FastAPI backend in `/api` to scan library.
- **Integration**: Electron now automatically spawns the Python backend.
- **Status**: Basic "Super Micro Grid" is operational and displaying photos.
