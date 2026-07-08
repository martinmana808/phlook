# PHLOOK — Vision Scene Categories — Design Spec

**Date:** 2026-07-08 · **Status:** Approved (YOLO queue #11). Fully local, offline; extends the KindDetector/sidebar pattern.

## Goal

Auto-categorize the library by scene content using Apple's on-device Vision framework, surfacing a set of curated categories as sidebar sections (Nature, Food, Documents, Animals, Vehicles, Beach, etc.) — like Photos' auto-categories, but computed locally over your plain files, nothing leaves the Mac.

## Approach

- **`SceneClassifier` (PhlookCore)**: `classify(imageAt: URL) -> Set<SceneCategory>` using `VNClassifyImageRequest` (returns ~1000 scene/object labels with confidence). Map the raw VN identifiers to a curated `SceneCategory` enum via a static lookup table (identifier substrings → category), keeping only labels above a confidence threshold (~0.35). A curated ~12-category set: nature, beach, food, document, animal, vehicle, plant, sky, water, building, art, text. (Screenshots/selfies already exist via KindDetector — Vision is additive.)
- **Storage**: migration `user_version = 6` adds `scene_flags INTEGER NOT NULL DEFAULT 0` (bitmask, up to 63 categories) + `-1` unknown sentinel for pre-v6 image rows (videos = 0). Reuse the exact detectKinds pattern: `scenesNeedingClassification()` query (`scene_flags = -1 AND file_type = 'image'`), `IndexingService.classifyScenes() async -> Int` background pass, wired into `load()` after detectKinds; new scans classify at extraction (fold into imageMeta's single CGImageSource open where feasible, else a second pass — Vision needs a CGImage, so classify off the already-decoded thumbnail-scale image to keep it cheap).
- **Performance**: Vision over ~10.5k images is the heavy one-time cost. Classify off a downsampled image (e.g. 512px) not the full-res original — Vision is scale-tolerant and this keeps it fast. Sentinel-resumable across launches like the kinds pass. Runs on a detached task; UI stays responsive; refresh sidebar counts when the pass makes progress (throttled, e.g. every 200 processed).
- **Sidebar**: a new "Categories" section listing only categories with count > 0, each driving a `LibraryScope` case (extend the scope enum + matches to test scene_flags bits). Ordered by count desc, or a fixed curated order.

## Non-goals
- No people/face recognition (explicitly cut from the project).
- No custom/trainable models — VNClassifyImageRequest's built-in taxonomy only.
- No per-photo category editing in v1.

## Testing
- `SceneClassifier` identifier→category mapping is pure and tested (feed known VN identifier strings → expected categories; threshold filtering). The VNClassifyImageRequest call itself over a real fixture image is a light integration test (classify a synthesized solid/known image, assert it returns *something* without crashing) — Vision results aren't deterministic enough to assert specific categories, so test the mapping layer thoroughly and the pipeline (sentinel → classify → flags set → idempotent) with an injected/mocked classifier or the real one tolerantly.
- Migration v6 (flags default, -1 sentinel, videos 0), scope matching for scene bits, idempotent classification pass.
- Human smoke: after the one-time pass, Categories section populates; clicking Nature/Food/etc. filters sensibly.
