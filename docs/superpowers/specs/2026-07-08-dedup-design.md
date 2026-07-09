# PHLOOK — Duplicate Finder — Design Spec

**Date:** 2026-07-08 · **Status:** Approved (YOLO queue #14).

## Goal

Find exact-duplicate files in the library and let the user review groups and trash the redundant copies — recoverable, originals-first.

## Approach

- **Exact-content dedup only** (v1): group files by a full-file content hash. The existing `quickHash` (SHA256 of first 1 MB + size) is a strong *candidate* signal but can theoretically collide; for a destructive review UI, compute a **full SHA256** on candidates that share a quickHash before declaring them duplicates. Two-stage: group by (fileSize, quickHash) → within each multi-member group, confirm by full SHA256 → real duplicate set.
- **Core**: `DuplicateFinder.groups(items:fullHash:)` pure over `[MediaItem]` + an injectable `fullHash: (String) -> String?` (so it's testable without real files); returns `[[MediaItem]]` (each inner array = 2+ confirmed duplicates, sorted with a suggested "keeper" first — keeper = the one whose name matches the library convention / oldest lastScanned / shortest path). No new schema (quickHash + fileSize already stored).
- **Service**: `IndexingService.duplicateGroups() async -> [[MediaItem]]` — pulls candidates sharing (size, quickHash) from the index (a cheap SQL GROUP BY HAVING count > 1), then full-hashes only those files off-main, returns confirmed groups.
- **UI**: a "Duplicates" affordance — simplest v1: a toolbar/menu button "Find Duplicates" that opens a sheet/overlay listing groups: each group shows thumbnails, the suggested keeper marked, checkboxes on the others (pre-checked), and "Move N Selected to Trash" (routes through the existing `LibraryTrasher`, pair-aware). Live-pair note: never split a live pair — treat the still+motion as a unit (dedup operates on stills; if a still is a dup, its motion goes with it).
- Empty result → "No duplicates found."

## Non-goals
- No perceptual/near-duplicate (similar-but-not-identical) matching — that's a much bigger ML feature; v1 is exact bytes only.
- No auto-delete; user reviews and confirms every trash.

## Testing
- `DuplicateFinder.groups`: size+quickHash grouping, full-hash confirmation splits a false quickHash collision into separate groups, keeper selection order, singletons excluded, empty input. All pure via injected `fullHash`.
- Service integration: real temp files with genuine byte-duplicates → one group; distinct files → none.
- Human smoke: run Find Duplicates on the real library, review a group, trash extras, verify Trash + grid update.
