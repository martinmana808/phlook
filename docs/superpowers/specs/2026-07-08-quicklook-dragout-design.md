# PHLOOK — Quick Look + Drag-Out — Design Spec

**Date:** 2026-07-08 · **Status:** Approved (user: "go with 8,10,11,12,13,14, YOLO"). Tracker #12 + #13. Small pair, ship together.

## #12 Quick Look (space bar)

- Space bar in the grid (All mode, viewer closed) opens the native macOS Quick Look panel for the current selection (or the single item under focus). Space again / Esc closes it.
- Mechanism: `QLPreviewPanel.shared()` with a data source (`QLPreviewPanelDataSource`) returning the selected items' file URLs as `QLPreviewItem` (NSURL conforms). A small AppKit responder/coordinator (`QuickLookController`) owns the panel, provides `numberOfPreviewItems` + `previewItemAt`, and is toggled from the grid's key handler.
- Selection semantics: if items are selected, preview the selection (arrow keys inside QL cycle them); if nothing selected, preview the item the space was pressed over — v1 simplest: require a selection (space with empty selection does nothing) OR preview all visibleItems starting at 0. Choose: preview the current selection; if empty, no-op with a subtle NSSound.beep suppressed (just no-op).
- Space bar wired through the existing `GridKeyCatcher` (keyCode 49), respecting its suspension guards (dialogs/modals), All-mode + viewer-closed only.
- In the viewer, space could also QL the current item (nice-to-have; v1 grid-only is fine).

## #13 Drag-out

- Dragging a grid cell (or a multi-selection) OUT of the app provides the file URLs to the drop target (Finder, Final Cut, Mail, Messages) — a real file copy/reference, originals untouched.
- Mechanism: `.onDrag { NSItemProvider(contentsOf: URL) }` on `ThumbCell` for a single item; for multi-selection drag, `.draggable`/`onDrag` with multiple providers isn't natively simple in SwiftUI — v1: dragging a cell that IS part of a multi-selection provides ALL selected URLs (use `.onDrag` returning one provider but register the primary; for true multi-item use an AppKit `NSDraggingSource` if needed). Pragmatic v1: `.onDrag` per cell providing that cell's file URL (single-item drag-out). Multi-item drag = follow-up. Document the limitation.
- Live pairs: dragging a live still provides the still's URL (v1); optionally both halves — v1 still only, documented.
- The drag image = the cell's thumbnail (SwiftUI uses the view snapshot automatically).
- Must not interfere with the existing single-click selection / double-click open / context menu; `.onDrag` composes with those (drag requires movement threshold).

## Testing

Both features are AppKit/SwiftUI interaction — no unit tests. `QuickLookController` panel data-source logic (count, item-at-index over a URL list) can be a tiny pure-ish helper if it factors cleanly. Human smoke: space opens QL on selection and cycles; drag a photo to Finder/desktop copies the file; drag a video into Final Cut; multi-select then drag (verify v1 single-item behavior is at least not broken).
