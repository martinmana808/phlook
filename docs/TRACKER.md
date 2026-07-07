# PHLOOK Feature Tracker (#1–#14)

The working checklist. `ROADMAP.md` holds descriptions; this file holds truth about progress.
States: ☐ queued · 🔨 in progress · ✅ shipped (merged to main) · 🧪 built, awaiting human smoke.

| # | Feature | State | Spec | Notes |
|---|---------|-------|------|-------|
| 1 | Incremental scan (fast launch) | ☐ | wave2 §1 | migration user_version 4 |
| 2 | Thumbnail memory cap | ☐ | wave2 §2 | |
| 3 | Grid densities (micro/medium/large) | ☐ | wave2 §3 | |
| 4 | Timeline scrubber rail | ☐ | wave2 §4 | Grok-style right edge |
| 5 | Hover-scrub video previews | ☐ | wave2 §5 | |
| 6 | Left sidebar (sections + date range) | ☐ | sidebar-hidden spec | includes Screenshots/Selfies detection |
| 7 | Hidden (Photos-style, auth-gated) | ☐ | sidebar-hidden spec | LocalAuthentication (Touch ID / password) to open Hidden |
| 8 | Device browser (phone thumbnails, NEW vs imported) | ☐ | — | folds in per-item import selection (#9) |
| 9 | Import selection | ☐ | — | subset of #8 |
| 10 | Live poster-frame picker | ☐ | — | first file-writing feature; own safety design |
| 11 | Vision categories (local ML) | ☐ | — | feeds sidebar sections |
| 12 | Quick Look (space bar) | ☐ | — | small |
| 13 | Drag-out to Finder/FCP | ☐ | — | small |
| 14 | Dedup finder | ☐ | — | content-hash + review UI |

Build order (user-approved 2026-07-07): **#1–5 → #6+7 → rest later.**

## Shipped so far (context)

Foundation · migration (3,021 out of Photos) · phlook-ingest CLI · viewer wave · video metadata backfill · Import from iPhone (memory, cancel, diagnostics) · Live Photos (2,511 pairs) · selection + pair-aware Move to Trash.
