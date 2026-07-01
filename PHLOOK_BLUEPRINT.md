# PHLOOK Master Blueprint

> "A window into your existing folder structure. Simple, Smart, Professional."

## 1. Project Philosophy & Vision
**Core Tenet:** Respect the User's Data.
- **Non-Destructive:** We view, index, and organize. We do not lock files into a proprietary database.
- **Filesystem First:** "Albums" are Finder Tags. Structure is Folder-based.
- **Local Intelligence:** All AI (OCR, CLIP, Whisper) runs locally. No cloud uploads.

## 2. Architecture Stack
To achieve "VS Code" performance with "Native Mac" integration and "Python AI" power:

*   **Frontend (The View):**
    *   **Framework:** React + Vite (Fast, modular).
    *   **Styling:** Vanilla CSS (per user preference for "Rich Aesthetics" & "Premium Feel").
    *   **Container:** Electron (Allows native file system access, shell commands, and "VS Code-like" UI construction).
*   **Backend (The Brain):**
    *   **Language:** Python 3.11+.
    *   **API Layer:** FastAPI (Connecting Electron IPC to Python Logic).
    *   **AI Engine:** PyTorch (CLIP), OpenAI Whisper (local), Tesseract/Apple Vision (OCR), FFmpeg (Video processing).
*   **Data Layer:**
    *   **Index:** SQLite (For caching OCR text, vectors, and thumbnails). *Note: This is a cache, not a source of truth. Re-buildable from files.*
    *   **Source of Truth:** The Metadata directly in the files (Exif/XMP) and the macOS Filesystem (Tags).

---

## 3. Phased Roadmap

### Phase 1: The Foundation ("The Window")
**Goal:** A beautiful, usable file viewer that feels faster than Finder.
*   **Deliverables:**
    *   [ ] Electron + React Scaffolding.
    *   [ ] "The Connector": Python backend that scans `~/Pictures/PHLOOK`.
    *   [ ] **Super Micro Grid**: Virtualized grid capable of rendering 50k items smoothly.
    *   [ ] **Normal Listing**: Detailed view with lazy-loading thumbnails.
    *   [ ] **Quick Look**: Spacebar integration for full-size preview.
    *   [ ] **Finder Tag Integration**: Read/Write tags directly to files.

### Phase 2: Core Intelligence ("The Brain")
**Goal:** Make the library searchable by concept and content.
*   **Deliverables:**
    *   [ ] **Universal OCR:** Pipeline to index text within images.
    *   [ ] **Semantic Search:** Implement local CLIP model for "blue car in rain" queries.
    *   [ ] **VS Code Timeline:** Generate the sidebar heatmap from date histograms.
    *   [ ] **Context Radar (v1):** Basic sidebar showing "On This Day" and "Map".

### Phase 3: Media Professional ("The Polish")
**Goal:** Video handling and high-end UX.
*   **Deliverables:**
    *   [ ] **Hover Scrub:** FFmpeg pipeline to generate sprite sheets for instant scrubbing.
    *   [ ] **Audio Search:** Whisper integration for video transcription.
    *   [ ] **Compression Slider:** UI for FFmpeg CRF transcoding.

### Phase 4: The Cleaner ("The Janitor")
**Goal:** Library hygiene and organization.
*   **Deliverables:**
    *   [ ] **Smart Stacking:** Algorithms for Time Proximity & Visual Similarity.
    *   [ ] **Quality Culling:** Blur/Exposure analysis pipeline (Green/Yellow/Red).
    *   [ ] **Duplicate & Frenzy Finder:** UI for resolving conflicts and choosing "Hero" shots.

---

## 4. Implementation Details & Checkpoints

### 4.1 Checkpoint Alpha: "Hello Grid"
- **Task:** Get the app running, scanning a folder, and showing images.
- **Success Criteria:**
    - App opens.
    - User selects `~/Pictures/PHLOOK`.
    - Infinite scroll grid displays thousands of placeholders/thumbnails.
    - Tags are visible.

### 4.2 Checkpoint Beta: "Search & See"
- **Task:** Plug in the Brain.
- **Success Criteria:**
    - Search bar accepts "text in image" (OCR) or "concept" (CLIP).
    - Results filter instantly.
    - Sidebar timeline allows jumping years.

### 4.3 Checkpoint Charlie: "Motion & Audio"
- **Task:** Video features.
- **Success Criteria:**
    - Hovering a video scrub-previews it.
    - Searching for spoken words finds the exact timestamp in a video.

---

## 5. Technical Requirements (The "Must-Haves")
- **FFmpeg**: Must be available in path (or bundled).
- **Python Venv**: Manage dependencies (pytorch, pillow, etc.) cleanly.
- **Node/NPM**: For the frontend build.

## 6. Next Immediate Steps (Manager's Orders)
1.  Initialize the Electron/React project structure.
2.  Set up the Python FastAPI bridge.
3.  Prove the "Finder Tag" concept works from the App.
