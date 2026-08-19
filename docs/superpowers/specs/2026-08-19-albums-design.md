# PHLOOK — Albums — Design

Date: 2026-08-19
Status: design agreed in conversation; ready to turn into an implementation plan.

## Problem

The user wants **albums** — arbitrary named collections of photos/videos —
that behave "like Finder tags" in *feel* (lightweight, one right-click to add)
but are **PHLOOK-only**: stored in PHLOOK's database, never written to the files
or the macOS filesystem. No actual Finder tags are touched.

## Core model

- An **album** is a named collection stored in the DB.
- **Many-to-many:** a photo can be in many albums; an album has many photos.
- Membership is **PHLOOK-only durable intent** — like `hidden`/`protected`/
  `curated`, it lives only in the DB and cannot be rebuilt from the files. (This
  makes it part of the "versioned DB copy on the SSD" durability story from the
  vault design — albums must survive a laptop rebuild.)
- Deleting an album deletes the **grouping only**, never the photos.

## The user's flow (verbatim intent)

1. Create album **"party"**.
2. Right-click a photo → **Add to album → party**.
3. The photo appears under **party** in the sidebar.

## Data model (migration v11)

```sql
CREATE TABLE albums (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE(name COLLATE NOCASE)          -- case-insensitive unique names
);
CREATE TABLE album_items (
    album_id  INTEGER NOT NULL,
    file_path TEXT NOT NULL,             -- PHLOOK's file identity (files.path)
    added_at  TEXT NOT NULL,
    PRIMARY KEY (album_id, file_path),
    FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE
);
CREATE INDEX idx_album_items_path ON album_items(file_path);
```

- Membership is keyed by **`file_path`** (the identity PHLOOK already uses
  everywhere; `files.path` is UNIQUE). A reclaimed item keeps its row and path,
  so album membership survives reclaim. (A future refinement could re-key by
  content hash to survive renames; out of scope for v1.)
- `ON DELETE CASCADE` so deleting an album drops its memberships.

## Core API (`MediaIndex`)

Pure, unit-tested:
- `func createAlbum(name: String) throws -> Int64` — creates (or returns the
  existing id for a case-insensitive name match); trims whitespace; rejects empty.
- `func renameAlbum(id: Int64, to name: String) throws`
- `func deleteAlbum(id: Int64) throws` — cascades memberships.
- `func addToAlbum(_ albumID: Int64, paths: [String]) throws` — idempotent
  (INSERT OR IGNORE), chunked like `setHidden`.
- `func removeFromAlbum(_ albumID: Int64, paths: [String]) throws` — chunked.
- `func albums() throws -> [Album]` where
  `struct Album: Identifiable, Equatable { let id: Int64; let name: String; let count: Int }`
  (count via a LEFT JOIN / subquery on `album_items`).
- `func albumMemberPaths(_ albumID: Int64) throws -> Set<String>` — for grid
  filtering.
- `func albumIDs(forPath path: String) throws -> [Int64]` — to show which
  albums an item is already in (for the context menu checkmarks).

## UI

### Sidebar — an "Albums" section
- A section below the storage/kinds sections listing each album (icon
  `rectangle.stack`) with its count, via the existing `row`/`countText` sidebar
  pattern — but albums are **data-driven**, not `LibraryScope` enum cases, so the
  selection model needs a parallel path (see below).
- A **"+"** / "New Album…" affordance at the section header to create one.
- Right-click an album row → **Rename…**, **Delete**.

### Selection model
`LibraryScope` is a fixed enum with pure predicates; albums are dynamic. Add a
parallel selection to `LibraryViewModel`:
- `@Published var selectedAlbumID: Int64?` — when set, it takes precedence over
  `scope` for what the grid shows.
- When an album is selected, `visibleItems` = items whose `path` is in
  `albumMemberPaths(selectedAlbumID)` (loaded into a `Set<String>` on selection),
  still respecting the date-range filter. Selecting a normal scope clears
  `selectedAlbumID`, and vice-versa.

### Grid / viewer actions
- Right-click item(s) → **Add to Album ▸** submenu: the list of albums (a
  checkmark next to ones the item is already in, from `albumIDs(forPath:)`) plus
  **"New Album…"** (prompts for a name, creates, adds).
- Right-click → **Remove from Album** (shown when viewing inside an album, or as
  a submenu of albums the item belongs to).
- Multi-select supported (add/remove the whole selection).

### Creating an album
"New Album…" opens a small text-field prompt (sheet/alert) for the name; on
confirm, `createAlbum` + `addToAlbum` the current selection.

## Edge cases

- **Duplicate name** — case-insensitive unique; "New Album" with an existing
  name returns/uses the existing album rather than erroring.
- **Empty / whitespace name** — rejected (no-op).
- **Deleted file** — if a path is pruned from `files` (a genuine non-archived
  deletion), its `album_items` rows should be cleaned up; the periodic
  `deleteMissing` path (or an album-side prune) removes orphaned memberships.
  Archived rows are never pruned, so their memberships persist correctly.
- **An item in zero albums** — normal; no album section membership.

## Out of scope (v1)

- Nested albums / folders of albums.
- Smart/auto albums (rules).
- Re-keying membership by content hash on rename.
- Sharing/exporting an album as a folder of files (could come later — it's just
  a copy of the member files, fully compatible with the filesystem-first model).

## Testing

Pure-core units (`MediaIndex`): create/rename/delete (cascade), add/remove
(idempotent, chunked), `albums()` counts, `albumMemberPaths`, `albumIDs(forPath:)`,
migration v11 schema. UI wired thin over the tested core (build + manual smoke).
