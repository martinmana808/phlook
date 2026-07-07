# PHLOOK Roadmap — everything discussed, and where it stands

Updated: 2026-07-07. Shipped = on main or the current branch, reviewed & tested.

## ✅ Shipped

Foundation (grid/index/thumbnails, instant launch) · Photos.app migration (3,021 out, verified) · phlook-ingest CLI · viewer (playback, nav, sidebar, details modal, filters, copy) · video metadata backfill (duration/dates, ~6.5k) · Import from iPhone (persistent import memory, counts, cancel, disconnect-safety, diagnostics) · Live Photos (2,511 pairs, LIVE badge, motion playback) · selection + Move to Trash (pair-aware, recoverable).

## 📐 Specced, awaiting build

| # | Feature | Spec | Size |
|---|---------|------|------|
| 1 | Incremental scan (launch: minutes → seconds; only changed files re-read) | wave2 spec §1 | M |
| 2 | Thumbnail memory cap (NSCache; no unbounded growth when scrolling 17k) | wave2 spec §2 | S |
| 3 | Grid densities — micro/medium/large, ⌘+/⌘−, persisted | wave2 spec §3 | S |
| 4 | Timeline scrubber rail (Grok-style right-edge ticks; hover month bubble; drag to jump) | wave2 spec §4 | M |
| 5 | Hover-scrub video previews (muted inline loop on hover) | wave2 spec §5 | M |

## 💬 Discussed, needs a design pass (roughly in user-priority order)

| # | Feature | How it would work | Size |
|---|---------|-------------------|------|
| 6 | **Left sidebar** | Persistent source list: All / Photos / Videos / Live / Screenshots / Selfies (detectable from metadata at index time) / Hidden; plus a FROM–TO date-range slider (dual anchors) filtering the grid | M–L |
| 7 | **Hidden items (Photos parity)** | Right-click → Hide (⌘H): index-level flag (new column), excluded everywhere except a Hidden sidebar section; Unhide reverses; files never move | S–M |
| 8 | Device browser | Plug in iPhone → thumbnail grid of the phone's camera roll, sectioned NEW vs already-imported (ICC provides thumbnails); per-item selection for import | L |
| 9 | Import selection | Lighter alternative/subset of #8: choose which of the N new items to import | M |
| 10 | Live poster-frame picker | Choose the still frame from the motion clip; FIRST file-writing feature (re-renders the HEIC) — needs its own safety design | M |
| 11 | Vision categories | Local ML (Apple Vision) for scene tags ("illustrations", etc.) feeding sidebar sections; fully offline | L |
| 12 | Quick Look (space bar) | Native QL panel from grid selection | S |
| 13 | Drag-out | Drag from grid to Finder/Final Cut/Mail (NSItemProvider file URLs) | S–M |
| 14 | Dedup finder | Content-hash pass (full-file), review UI for duplicate groups, keep-best suggestion | L |
| 15 | Folder tree view | Browse the PHLOOK folder hierarchy (currently flat, so low value until subfolders happen) | M |
| 16 | Finder tags integration | Read/write macOS tags as albums-substitute | M |
| 17 | Search (filename now; OCR/semantic later) | Filename search = S; OCR/semantic = XL, local-only | S→XL |
| 18 | Compression, smart stacking, audio search, "context radar" | Original braindump; undesigned | XL |

## 🔧 Known polish debt (small, batched into any wave)

Viewer delete advances instead of closing · empty-grid-click clears selection · NOT-CLEAN import warning styled red/bold again · hover-visible viewer chrome · import-result sheet suspends grid keys · watchdog progress re-arm uses byte deltas · stale-epoch refetch off main thread · "N files waiting in staging" affordance · deferred test gaps (TIFF fallback, fractional-second parse, portrait fixture).
