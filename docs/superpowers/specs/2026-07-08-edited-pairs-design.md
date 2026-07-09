# PHLOOK — Edited/Original Pair Finder — Design Spec

**Date:** 2026-07-08 · **Status:** Approved (user: real case — IMG_8624.MOV + IMG_E8624.MOV). Complements the exact-content dedup.

## Problem

iOS keeps BOTH the original and the edited version of a photo/video after you edit it: `IMG_8624.MOV` (original) + `IMG_E8624.MOV` (edited, `E` inserted after `IMG_`). They're visually the same but NOT byte-identical (different sizes/hashes), so the content-hash Duplicate Finder misses them entirely. Library has ~158 such pairs (157 video, 1 photo).

## Detection (name-pattern, no hashing)

Two library items form an **edited pair** when, after stripping the ingest timestamp prefix (`YYYY-MM-DD_HH-MM-SS_`):
- same extension (case-insensitive), AND
- same capture timestamp prefix, AND
- one basename is `IMG_<digits>` and the other is `IMG_E<digits>` with the SAME `<digits>` (the only difference is the inserted `E`).

Group = both (edited + original), keeper-first where **keeper = the EDITED version** (`IMG_E…` — the user's deliberate edit, what Photos shows), original as the removable one. Skip any path in `livePairs.hiddenVideoPaths` (live-motion `_3.mov` clips never match this pattern anyway, but exclude defensively).

## Components

- **Core**: `EditedPairFinder.pairs(items: [MediaItem]) -> [[MediaItem]]` — pure, name-based, no file I/O. Parses each basename; groups by (timestamp, normalized-number, ext); emits groups that contain at least one edited + one original; edited-first. Tested.
- **App**: `LibraryViewModel.findDuplicates()` (already async) ALSO computes `editedPairs = EditedPairFinder.pairs(items: items).map { drop hiddenVideoPaths }.filter { >= 2 }`. Store both result sets. The Duplicates sheet (`DuplicatesView`) shows TWO sections: **"Identical files"** (existing content groups) and **"Edited versions (original + edited)"** — same review-and-trash UI, keeper marked "Keep · Edited", the original pre-checked for Trash, user-adjustable. Trash routes through the same `vm.trashPaths` (recoverable, pair-aware).
- If both sections are empty → "No duplicates found." If one is empty, hide that section header.

## Safety
- Recoverable Trash only (never removeItem); keeper can't be trashed (same structural guard as content dedup — only non-keeper cells are selectable).
- The default suggests trashing the ORIGINAL and keeping the EDITED, but every checkbox is user-controlled; nothing auto-deletes.

## Testing
- `EditedPairFinder.pairs`: IMG_8624 + IMG_E8624 same stamp+ext → one pair, edited-first; different timestamps → no pair; different numbers → no pair; different ext → no pair; IMG_E present without its original → no group; photos (HEIC) pair too; live-motion `_3.mov` names don't match.
- Keep all 171 tests green; new EditedPairFinderTests.
- Human smoke: Find Duplicates → "Edited versions" section lists the ~158 pairs, trash the originals, verify Trash + grid update, edited versions remain.
