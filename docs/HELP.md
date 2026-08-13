# PHLOOK — User Guide

> A window into your existing folder of photos and videos. The familiar
> grid-and-viewer of Apple Photos — but every file stays a plain file in a real
> folder on your disk. No proprietary library, no lock-in.

This guide explains every part of the app: what each control does, how the
features work, and — for the newer SSD archive workflow — *why* you'd use it and
how to stay safe.

---

## Contents

1. [The big idea](#1-the-big-idea)
2. [Getting started](#2-getting-started)
3. [The main window](#3-the-main-window)
4. [Browsing your library](#4-browsing-your-library)
5. [The viewer](#5-the-viewer)
6. [Importing from your iPhone](#6-importing-from-your-iphone)
7. [Organizing: hide, duplicates, poster frames, trash](#7-organizing)
8. [SSD Archive & Shrink — keep a 10% library locally](#8-ssd-archive--shrink)
9. [Keyboard shortcuts](#9-keyboard-shortcuts)
10. [FAQ & safety notes](#10-faq--safety-notes)

---

## 1. The big idea

PHLOOK reads the folder at **`~/Pictures/PHLOOK`**. Everything you see is a real
file there — named `YYYY-MM-DD_HH-MM-SS_Name.ext` by capture date. PHLOOK builds
a fast local index (a rebuildable cache) so it can show tens of thousands of
items instantly, but **the files and their metadata are the source of truth**.
Delete PHLOOK tomorrow and your photos are exactly where they always were.

Three things PHLOOK never does: lock your media in a database, upload anything to
the cloud, or modify your originals without telling you.

---

## 2. Getting started

- **Your library lives at `~/Pictures/PHLOOK`.** Put media there (or use Import,
  §6). PHLOOK scans it on launch.
- **First launch** indexes the library ("Indexing your library…"). Later
  launches only re-read what changed, so they're fast. A background re-scan shows
  an "Updating…" chip in the corner.
- **Videos** get their dates, durations, and dimensions filled in by a background
  pass after the first scan.

---

## 3. The main window

The window has two parts, plus a full-screen viewer that opens on top:

- **Sidebar** (left) — filter your library by kind, category, or date (§4).
- **Grid** (center) — your thumbnails, plus a filter bar at the top (§4).
- **Viewer** (overlay) — opens when you double-click an item (§5).

---

## 4. Browsing your library

### The filter bar (top of the grid)

- **Density picker** (three grid icons) — switches thumbnail size:
  **micro → medium → large**. Also change it with **⌘+ / ⌘−**. Your choice is
  remembered between launches.
- **Time mode** (Years / Months / All):
  - **All** — every item in one scrollable grid.
  - **Months** — one card per month, each slowly cycling through its photos.
    Click a card to jump into that month.
  - **Years** — one card per year. Click to drill into that year's months.
- **Find Duplicates** — scans for identical and edited-pair copies (§7).
- **Reclaim Space** — opens the SSD Archive & Shrink panel (§8).

### The sidebar scopes

Click a scope to filter the grid. Each shows a live count.

- **Library:** All · Photos · Videos · Live Photos
- **Kinds:** Screenshots · Selfies *(detected automatically from metadata)*
- **Categories:** Nature, Food, Documents, Animals, Vehicles, Plants, Water,
  Buildings, Sky, Art, Text, Beach — *scene tags recognized on-device by Apple
  Vision. They appear only once the classifier has tagged some photos.*
- **Hidden** — locked by default (see below).

**Date Range** (bottom of the sidebar, appears once you have a couple of months
of photos): two month sliders (**From** / **To**) narrow the grid to a span.
**Reset** clears it. It shows "N items in range."

### The timeline rail

In the **All** grid, a faint scrubber runs down the right edge with year ticks.
Hover it to see a month bubble; **drag and release** to jump the grid to that
point in time.

### Hidden items

The **Hidden** scope is protected. Clicking it prompts for **Touch ID / your
password**. Hidden items are excluded from every other scope and every count —
they only appear here, once unlocked. Leaving the scope re-locks it. Hiding never
moves or deletes files; it's just an index flag. Toggle with **⌘H** or the
right-click menu.

---

## 5. The viewer

**Double-click** any item (or right-click → **Open**) to open the viewer. It
grows out of the thumbnail; press **Esc**, click the **✕**, or double-click the
background to close.

### Moving around

- **← / →** — previous / next.
- **Two-finger swipe** (trackpad) — previous / next (when not zoomed in).
- **On-screen chevrons** — left/right edges.

### Zooming (photos)

- **Pinch**, the **zoom slider**, or **⌘+scroll** to zoom. **1×** resets.
- **Click-drag** to pan when zoomed (the cursor becomes a hand).
- Past a threshold, PHLOOK re-decodes the photo at higher resolution for a
  sharper close-up.

### Live Photos

Items shot as Live Photos show a **LIVE** badge. In the viewer, the **LIVE**
button plays the motion clip. **Set Poster…** lets you choose the still frame
(§7).

### Details & actions

- **ⓘ** (or **⌘I**) — toggle the Details sidebar: date, dimensions, duration,
  size, kind, full path, plus **Copy Path** and **Show in Finder**. For Live
  Photos it also reveals the paired motion file.
- **Right-click → Copy** — copies the file (paste into Finder, Mail, Final Cut…).
- **Right-click → Copy Image** — copies the decoded image data (for editors).
- **Delete** — moves the item to the Trash (with confirmation).

### Quick Look

Select an item in the grid and press **Space** for the native macOS Quick Look
panel. Space again closes it.

---

## 6. Importing from your iPhone

Plug in your iPhone and unlock it. The **import bar** appears in the filter area:

- **Import N new from [iPhone]** — one click imports every photo/video that
  isn't already in your library. Files are renamed by capture date and never
  overwrite existing ones.
- **Browse…** — opens the **Device Browser**: a thumbnail grid split into
  **New** (pre-selected, choose which to import) and **Already imported**
  (dimmed, tagged "Imported"). Use **Select All / Select None**, then
  **Import N selected**.
- The bar also tells you **"…and N items still need archiving"** when you have
  local files not yet backed up to your SSD (§8).

After an import you get a summary; **CLEAN** means every file transferred
successfully and it's safe to delete them from the phone.

---

## 7. Organizing

- **Hide / Unhide** — right-click → **Hide** (or **⌘H**). Hidden items live in
  the locked Hidden scope. Files never move.
- **Move to Trash** — select items and press **Delete**, or right-click → **Move
  to Trash**. Recoverable from the macOS Trash. Trashing a Live Photo removes its
  motion file too. Selection is smart: plain-click selects one, **⌘-click**
  toggles, **Shift-click** selects a range, **⌘A** selects all.
- **Find Duplicates** — two kinds:
  - **Identical files** — exact byte-for-byte copies.
  - **Edited versions** — an original and its edited twin (`IMG_1234` +
    `IMG_E1234`).
  Each group keeps the first item (badged **Keep**); the rest are pre-checked as
  trash candidates you can toggle. **Move N Selected to Trash** when ready. A
  keeper can never be accidentally trashed.
- **Set Poster… (Live Photos)** — pick the still frame shown for a Live Photo by
  scrubbing the motion clip. **Non-destructive** — it stores a time offset, never
  rewrites the file. **Reset to Original** undoes it.

---

## 8. SSD Archive & Shrink

*This is the newest and most important workflow, so it gets the fullest
explanation.*

### Why

A large library (photos + video) can be hundreds of GB — too big to keep on a
laptop. PHLOOK's answer: **keep the full-resolution masters on an external SSD,
and keep a browsable ~10%-size version of everything on your laptop.** You still
see and scroll your whole library locally; when you need a real original, you
grab it from the SSD.

Each item has three independent facts:

| Fact | Meaning |
|------|---------|
| **On the SSD?** | A verified, byte-perfect master exists on the drive. |
| **Has a 10% version?** | A small local stand-in has been made. |
| **Local original still here?** | The full file is still on the laptop (until reclaimed). |

### The one safety rule (why you can trust it)

> **PHLOOK deletes a local original only *after* it has (a) copied it to the SSD
> and read it back to confirm it's byte-perfect, *and* (b) made the local 10%
> version.** Deletion is always the last step, one file at a time. If anything
> fails, your original stays put.

"Delete" here means **Move to Trash** — recoverable. Nothing frees disk space
until you empty the Trash, which is the only irreversible step and entirely up to
you.

### Requirements

- An **external SSD** (any drive). PHLOOK marks it with a tiny hidden
  `.phlook_archive` file so it only ever writes to *your* archive drive, even if
  you rename the volume.
- **ffmpeg** installed (`brew install ffmpeg`) — used to shrink videos to ~10% at
  watchable quality. Photos use built-in macOS encoding.

### The Reclaim Space panel

Open it with **Reclaim Space** in the filter bar. Controls:

- **Subtitle line** — either **"Connect PHLOOK_SSD to archive"** (drive not
  found) or **"N not yet archived · X.X GB reclaimable."**
- **"N have 10% versions"** — how many items already have a local stand-in.
- **Set up archive drive…** *(shown when no drive is connected)* — pick your
  SSD's top-level volume once. PHLOOK writes the marker and creates a `PHLOOK/`
  folder on it.
- **Archive & shrink** — the main action. Enabled only when the SSD is connected
  and there's something to archive. For each file it: copies/verifies it to the
  SSD → makes the 10% version → moves the original to the Trash.
- **Cancel** — stops the run. It finishes the current file first (so nothing is
  half-done), then stops.
- **Report line** after a run — "Archived N · shrunk N · reclaimed N", plus any
  skipped name-collisions (never overwritten) and any failures (originals always
  kept).

### Adopting an existing backup

If masters are already on the SSD (e.g. a previous backup), PHLOOK **adopts**
them: it hashes the local file and the one on the SSD, and if they're identical
it marks the item archived **without re-copying** — a fast verify pass instead of
a slow transfer. Only files not already on the drive get copied.

### Getting an original back

Right-click a reclaimed item → **Show original on SSD**. Finder opens with the
master selected on the drive, ready to drag into Final Cut, an email, etc. PHLOOK
doesn't copy it back automatically — you take what you need. (Disabled if the item
isn't archived or the drive isn't connected.)

### Stop and resume freely

Each file is atomic — fully done or not started. You can **Cancel**, quit the
app, even lose power, and simply run **Archive & shrink** again later: it picks up
where it left off and never re-does finished files. That's the intended way to
work through a big video library across several sessions.

### Tips for a big first run

- Keep the SSD plugged in and stop your Mac from sleeping (it's a long transcode
  job — video is the slow part; already-backed-up files adopt instantly).
- It's fine to run it overnight and finish another night if needed.
- Empty the Trash only after you've confirmed everything looks right — that's when
  the space is actually reclaimed.

---

## 9. Keyboard shortcuts

### In the grid

| Key | Action |
|-----|--------|
| **Double-click** | Open the viewer |
| **Space** | Quick Look the selection |
| **⌘A** | Select all |
| **⌘-click** | Add/remove from selection |
| **Shift-click** | Select a range |
| **⌘+ / ⌘−** | Larger / smaller thumbnails |
| **⌘H** | Hide / unhide the selection |
| **Delete** | Move selection to Trash |
| **Esc** | Clear selection |

### In the viewer

| Key | Action |
|-----|--------|
| **← / →** | Previous / next |
| **⌘+scroll** | Zoom in / out |
| **⌘I** | Toggle details |
| **Delete** | Move to Trash |
| **Esc** | Close the viewer |

---

## 10. FAQ & safety notes

**Will PHLOOK change my original files?**
No — with two clearly-labeled exceptions you trigger yourself: moving items to the
Trash, and the SSD reclaim (which trashes a local original only after a verified
SSD copy + 10% version exist). Poster frames and Hide are index-only and never
touch files.

**What if my index breaks?**
It's a rebuildable cache. Your files and their metadata are the truth; PHLOOK
re-scans and rebuilds.

**Is the SSD a backup?**
In the archive workflow the SSD holds the **only** full-resolution copy once you
reclaim local space. Treat the drive with care — a second backup drive is wise if
your masters are irreplaceable.

**Nothing was uploaded anywhere?**
Correct. All indexing, scene recognition (Apple Vision), and shrinking happen
locally on your Mac.

---

*PHLOOK is free and open source. Source: <https://github.com/martinmana808/phlook>*
