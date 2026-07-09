<p align="right"><a href="README.md">English</a> · <a href="README.es.md">Español</a></p>

# PHLOOK

**The Photos.app experience you know — but your media stays as plain files in real folders on disk. No proprietary library blob.**

PHLOOK is a native macOS photo & video viewer. It reads and displays the media that lives in `~/Pictures/PHLOOK` as ordinary files — always yours, always movable, readable by any other tool, backup-able with a simple copy. PHLOOK just indexes and shows them; it never locks your photos inside a database.

## The problem it solves

Apple Photos keeps your library inside a giant proprietary `.photoslibrary` bundle. Your photos aren't really *files* anymore — they're entombed in a blob you can only fully use through Photos itself. PHLOOK escapes that prison: the same familiar grid-and-viewer experience, but every photo and video is a plain file you own outright.

## What it does

- **Browse** — a dense, fast grid with three zoom densities and a full-window viewer (pinch / slider / ⌘-scroll zoom, click-drag pan, arrow-key & swipe navigation, a Photos-style open/close animation).
- **Navigate time** — a right-edge scrubber with year labels, and **Years / Months / All** views with auto-cycling cover photos.
- **Organize** — a sidebar with Library (All · Photos · Videos · Live Photos), auto-detected **Screenshots** and **Selfies**, on-device **Vision categories** (Nature, Food, Animals…), a **date-range** filter, and **Hidden** (protected by Touch ID / your Mac password).
- **Live Photos** — paired automatically, played on demand, with a non-destructive **poster-frame picker** (choose any frame from the motion clip; your originals are never rewritten).
- **Clean up** — **duplicate finder** (byte-identical files *and* iOS original/edited `IMG` ↔ `IMG_E` pairs) with a safe review-and-Trash flow.
- **Bring media in** — import straight from an iPhone (browse the camera roll, pick what's new), or drop files into a staging folder and run one command.
- **Interoperate** — Quick Look (space bar), drag photos out to Finder / Final Cut / Mail, "Show in Finder", copy.

## How to use it

### 1. Install
Build the app and copy it to `/Applications`:
```bash
make app
cp -R Phlook.app /Applications/
```
Then launch **Phlook** from Launchpad or Spotlight. On first launch it indexes your library (subsequent launches are near-instant).

### 2. Get your media into the library
Your photos live in `~/Pictures/PHLOOK`, named `YYYY-MM-DD_HH-MM-SS_OriginalName.ext`. Three ways to add more:

- **From an iPhone (in-app):** plug in the phone → click **Import N new** (or **Browse…** to pick individual items). PHLOOK remembers what it already imported, so it never re-offers the same photo.
- **From a staging folder:** drop any files (Image Capture, AirDrop, downloads) into `~/Pictures/PHLOOK_staging`, then run:
  ```bash
  make ingest
  ```
  It renames each file from its capture metadata, refuses to overwrite, skips duplicates, and reports a **CLEAN / NOT CLEAN** verdict — CLEAN means it's safe to delete the originals from your phone.
- **Manually:** copy files straight into `~/Pictures/PHLOOK`. They'll be indexed on the next launch.

> **Excluding a folder:** any subfolder whose name starts with `_` is kept inside the library folder but **not indexed** — perfect for dropping in an archive you don't want mixed into the grid.

### 3. Everyday use
- **Double-click** a photo to open the viewer; **space** for Quick Look; **drag** a photo out to another app.
- **Click** to select, **⌘-click** to add, **⌘A** for all, **right-click → Move to Trash** (recoverable via Finder's Trash).
- **⌘H** to Hide the selection; open **Hidden** in the sidebar and authenticate to view it.
- **Find Duplicates** (toolbar) to review and clean up redundant copies.

## Backing up

Two independent things, two backups:

- **The library (your photos + `phlook.db`)** → mirror to an external drive:
  ```bash
  rsync -a --delete --exclude='.phlook' ~/Pictures/PHLOOK/  /Volumes/YourDrive/PHLOOK/
  ```
  Run it again anytime — it copies only what changed. The `.phlook` thumbnail cache is skipped (it regenerates). The database is worth keeping: it holds Hidden flags, poster picks and import history, which can't be rebuilt from files alone.
- **The app itself** → `git push` (the source lives in this repository).

## Under the hood

Native macOS, SwiftUI + AppKit, Swift Package Manager (no Xcode required — builds with Command Line Tools). SQLite index via GRDB. Media stays untouched on disk; PHLOOK only ever reads your originals and writes its own small index.

## Philosophy

Your photos are yours. They should be plain files, in real folders, readable forever by any tool — not hostages of one app's database. PHLOOK gives you the polish of Photos without the prison.
