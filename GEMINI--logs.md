# GEMINI Logs (The Vault)

This file contains a forensic ledger of all technical decisions and interactions.

---

<a name="log-20251221-phlook-foundation"></a>
## [2025-12-21] Phlook Foundation ("The Window")

**User Prompt:** Initialize the Electron/React project structure. Set up the Python FastAPI bridge. Prove the "Finder Tag" concept works from the App.

### Implementation Plan (Recovered Artifact)

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

### Walkthrough (Retrospective)

## Phase 1: Initialization (Completed)
We have successfully initialized the project with a hybrid architecture:
- **Frontend**: Electron + React + Vite (TypeScript).
- **Backend**: Python 3.13 + FastAPI + Uvicorn.

## Phase 2: The Foundation (Completed)
We encountered significant environment challenges resolving the Electron binary, but "The Window" is now open.

### Features Implemented
1.  **The Connector**:
    - `app/electron/main.js` now automatically spawns the Python backend on launch.
    - `api/main.py` serves a `/scan` endpoint that reads `~/Pictures/PHLOOK`.
    - **Status**: Verified via logs `[1] Starting Python process...`.

2.  **Basic Grid**:
    - React Component: `src/components/Grid.tsx`
    - Logic: Fetches JSON from Python, renders lazy-loaded images.
    - Style: Dark mode, responsive CSS Grid.

### Resolutions to Challenges
- **Python 3.13 Compatibility**: Downgraded to `pydantic==1.10.26` to avoid build errors.
- **Electron Binary Corruption**: The `npm install` process was masking the Electron binary with the system Node binary (`v22`). We resolved this by:
    1.  Cleanly re-installing Electron in `app/node_modules`.
    2.  Explicitly satisfying the `ELECTRON_RUN_AS_NODE` environment variable conflict.
    3.  Pointing `package.json` directly to the verified binary: `./node_modules/electron/dist/Electron.app/Contents/MacOS/Electron`.

---

<a name="log-20251221-core-intelligence"></a>
## [2025-12-21] Core Intelligence ("The Brain")

**User Prompt:** CARRY ON WORKING ON THIS, YOLO MODE. Keep running it, keep working on it, until you make it work. Develop PHLOOK.

### Implementation Plan

# implementation_plan.md - Phase 3: Core Intelligence

## Goal
Implement the "Brain" of Phlook: Persistent storage (SQLite), Text Recognition (OCR), and Semantic Search (CLIP).

## User Review Required
> [!IMPORTANT]
> **Safety First**: No file deletion logic will be implemented in this phase. We are strictly *reading* files to generate metadata.

## Proposed Changes

### 1. Data Layer (SQLite)
#### [NEW] [api/database.py](file:///Users/martinmana/Documents/GitHub/PhlookDev/api/database.py)
- **Library**: Use `sqlite3` (std lib) or `tortoise-orm`? Let's stick to `sqlite3` for simplicity and zero-dependency friction unless complexity grows.
- **Schema**:
    - `files`: path, hash, date_taken, size
    - `ocr_data`: file_id, text_content, confidence
    - `embeddings`: file_id, vector_blob (for CLIP)

### 2. OCR Pipeline
#### [NEW] [api/ocr.py](file:///Users/martinmana/Documents/GitHub/PhlookDev/api/ocr.py)
- **Engine**: Apple Vision Framework via `pyobjc` (Native, fast, no extra install) OR Tesseract.
    - *Decision*: Try `tesseract` first as it's standard, but if `pyobjc` is available on the mac, it's better. Given we can install whatever, let's try `pyobjc-framework-Vision` for "Pro" Mac integration.
    - *Fallback*: EasyOCR (Torch-based, since we need Torch for CLIP anyway).

### 3. CLIP Pipeline
#### [NEW] [api/clip_engine.py](file:///Users/martinmana/Documents/GitHub/PhlookDev/api/clip_engine.py)
- **Library**: `sentence-transformers` (HuggingFace).
- **Model**: `clip-ViT-B-32` (Good balance of speed/performance).
- **Logic**: Generate embeddings for images and text queries.

### 4. Integration
#### [MODIFY] [api/main.py](file:///Users/martinmana/Documents/GitHub/PhlookDev/api/main.py)
- Add `/search` endpoint.
- Add background task to index files on startup.

## Verification Plan
1.  **Database**: Verify `phlook.db` is created.
2.  **OCR**: Run script on sample image, check text output.
3.  **CLIP**: Run metadata generation, query "dog", check results.

### Walkthrough

## Phase 3: Core Intelligence (Completed)
We have implemented the "Brain" of Phlook to analyze and search your library.

### Features Implemented
1.  **SQLite Database**:
    - `api/database.py`: Stores file metadata, OCR text, and CLIP embeddings.
    - `phlook.db`: Automatically initialized on startup.

2.  **Text Recognition (OCR)**:
    - `api/ocr.py`: Uses **Apple Vision Framework** (via PyObjC) to natively extract text from images.
    - **Performance**: High fidelity, runs locally on macOS.

3.  **Semantic Search (CLIP)**:
    - `api/clip_engine.py`: Uses `openai/clip-ViT-B-32` (via `sentence-transformers`) to generate vector embeddings.
    - **Capability**: Allows searching for concepts like "dog on beach" or "sunset".

4.  **Finder Integration**:
    - `api/finder.py`: Enables reading and writing native Finder tags (e.g., "Yellow").
    - **Endpoint**: `POST /tag` exposed for frontend use.

## Usage
To run the full intelligent app:
```bash
cd app
npm run dev:electron
```
1.  The app will launch.
2.  The **Background Scanner** will immediately start indexing files, running OCR, and generating embeddings.
3.  Check the terminal logs to see progress.
4.  Use the Search Bar to find photos (Note: It may take some minutes for the first scan to complete).
