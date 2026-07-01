import os
import shutil
import pathlib

# --- CONFIGURATION ---
SOURCE_ROOT = pathlib.Path("/Users/martinmana/Pictures/PHLOOK")
ORIGINALS_DIR = SOURCE_ROOT / "originals"

def get_unique_path(destination_dir: pathlib.Path, filename: str) -> pathlib.Path:
    """
    Generates a unique path by appending _1, _2, etc. if collision occurs.
    """
    stem = pathlib.Path(filename).stem
    suffix = pathlib.Path(filename).suffix
    
    candidate = destination_dir / filename
    counter = 1
    
    while candidate.exists():
        new_name = f"{stem}_{counter}{suffix}"
        candidate = destination_dir / new_name
        counter += 1
        
    return candidate

def flatten_library(dry_run=True):
    """
    Moves all files from subdirectories of ORIGINALS_DIR to ORIGINALS_DIR root.
    """
    print(f"--- 🚜 Flattening Library (Dry Run: {dry_run}) ---")
    print(f"Target: {ORIGINALS_DIR}\n")

    if not ORIGINALS_DIR.exists():
        print(f"❌ Error: Originals directory does not exist: {ORIGINALS_DIR}")
        return

    moved_count = 0
    collisions_count = 0
    
    # Walk bottom-up to handle sub-sub-folders correctly if any
    for root, dirs, files in os.walk(ORIGINALS_DIR):
        # Skip the root folder itself (we only want to move FROM subfolders)
        if pathlib.Path(root) == ORIGINALS_DIR:
            continue
            
        for file in files:
            source_path = pathlib.Path(root) / file
            
            # Skip .DS_Store
            if file.startswith('.'):
                continue
            
            # Determine unique destination in the root ORIGINALS_DIR
            dest_path = get_unique_path(ORIGINALS_DIR, file)
            
            is_collision = dest_path.name != file
            if is_collision:
                collisions_count += 1

            if dry_run:
                arrow = "->" if not is_collision else "-> (Collision Renamed)"
                print(f"[DRY RUN] {file} {arrow} {dest_path.name}")
            else:
                try:
                    shutil.move(str(source_path), str(dest_path))
                    moved_count += 1
                    # print(f"Moved: {file}") # reduce spam for 14k files
                    if moved_count % 1000 == 0:
                        print(f"Moved {moved_count} files...", end='\r')
                except Exception as e:
                    print(f"❌ Error moving {file}: {e}")

    # Cleanup Empty Directories
    if not dry_run:
        print("\n--- 🧹 Cleaning up empty directories ---")
        for root, dirs, files in os.walk(ORIGINALS_DIR, topdown=False):
            for name in dirs:
                d = os.path.join(root, name)
                try:
                    os.rmdir(d)
                except OSError:
                    pass

    print(f"\n\n--- ✅ Flattening Complete ---")
    print(f"Files Moved: {moved_count}")
    print(f"Collisions Handled: {collisions_count}")

if __name__ == "__main__":
    print("WARNING: This will flatten all subfolders into the root 'originals' folder.")
    response = input("Type 'run' to execute in ACTUAL mode, or anything else for DRY RUN: ")
    
    is_dry_run = response.strip().lower() != 'run'
    flatten_library(dry_run=is_dry_run)
