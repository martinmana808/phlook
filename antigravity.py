import os
import shutil
import pathlib
import datetime
from PIL import Image, ExifTags
from hachoir.parser import createParser
from hachoir.metadata import extractMetadata
# from hachoir.core.error import HachoirError
import pillow_heif

pillow_heif.register_heif_opener()

# --- CONFIGURATION ---
# Hardcoded based on user requirements and verification
SOURCE_ROOT = pathlib.Path("/Users/martinmana/Pictures/PHLOOK")
ORIGINALS_DIR = SOURCE_ROOT / "originals"

# Extensions to process
IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.heic', '.webp', '.tiff', '.bmp', '.gif'}
VIDEO_EXTENSIONS = {'.mp4', '.mov', '.avi', '.mkv', '.wmv', '.flv'}

def get_hachoir_metadata(file_path):
    """Extracts metadata using hachoir for videos."""
    parser = None
    try:
        parser = createParser(str(file_path))
        if not parser:
            return None
        metadata = extractMetadata(parser)
        if not metadata:
            return None
        return metadata
    except Exception:
        return None
    finally:
        if parser:
            parser.close()

def get_date_taken(file_path: pathlib.Path):
    """
    Extracts the best possible creation date.
    Priority:
    1. EXIF 'DateTimeOriginal' (Images)
    2. Metadata 'creation_date' (Videos)
    3. File creation timestamp (Fallback)
    Returns: (datetime, source_string)
    """
    ext = file_path.suffix.lower()
    
    # 1. Try Image EXIF
    if ext in IMAGE_EXTENSIONS:
        try:
            with Image.open(file_path) as img:
                # 1. Try Standard _getexif (JPEG)
                try:
                    exif = img._getexif()
                    if exif:
                        for tag, value in exif.items():
                            decoded = ExifTags.TAGS.get(tag, tag)
                            if decoded == 'DateTimeOriginal':
                                return datetime.datetime.strptime(value, "%Y:%m:%d %H:%M:%S"), "EXIF"
                except Exception:
                    pass

                # 2. Try Raw getexif (HEIC / PNG)
                try:
                    raw_exif = img.getexif()
                    if raw_exif:
                        # Check Top Level
                        if 36867 in raw_exif: # DateTimeOriginal
                             val = raw_exif[36867]
                             return datetime.datetime.strptime(val, "%Y:%m:%d %H:%M:%S"), "EXIF_Raw"
                        
                        # Check Nested ExifOffset (0x8769 / 34665)
                        if 34665 in raw_exif:
                            nested = raw_exif.get_ifd(34665)
                            if 36867 in nested:
                                val = nested[36867]
                                return datetime.datetime.strptime(val, "%Y:%m:%d %H:%M:%S"), "EXIF_Nested"
                except Exception:
                    pass
        except Exception:
            pass # Fallback

    # 2. Try Video Metadata
    if ext in VIDEO_EXTENSIONS:
        try:
            metadata = get_hachoir_metadata(file_path)
            if metadata and metadata.has("creation_date"):
                    return metadata.get("creation_date"), "VideoMeta"
        except Exception:
            pass # Fallback

    try:
        stat = file_path.stat()
        # On Unix, st_birthtime is creation time, st_mtime is modification.
        # We prefer birthtime if available.
        if hasattr(stat, 'st_birthtime'):
             timestamp = stat.st_birthtime
        else:
             timestamp = stat.st_mtime
        return datetime.datetime.fromtimestamp(timestamp), "System"
    except Exception:
        # Absolute fallback if stat fails for some reason
        return datetime.datetime.now(), "ErrorFallback"

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

def process_library(dry_run=True):
    """
    Walks through ORIGINALS_DIR, moves and renames files to SOURCE_ROOT.
    """
    print(f"--- 🚀 Starting Migration (Dry Run: {dry_run}) ---")
    print(f"Source: {ORIGINALS_DIR}")
    print(f"Target: {SOURCE_ROOT}\n")

    if not ORIGINALS_DIR.exists():
        print(f"❌ Error: Originals directory does not exist: {ORIGINALS_DIR}")
        return

    moved_count = 0
    errors = []

    # Walk bottom-up so we can clean up empty dirs easily if needed (though we'll do clean up separately)
    for root, dirs, files in os.walk(ORIGINALS_DIR):
        for file in files:
            file_path = pathlib.Path(root) / file
            
            # Skip .DS_Store and other hidden files
            if file.startswith('.'):
                continue
                
            try:
                # 1. Get Date
                date_taken, source = get_date_taken(file_path)
                
                # 2. Formulate New Name
                # YYYY-MM-DD_HH-MM-SS_OriginalName.ext
                date_str = date_taken.strftime("%Y-%m-%d_%H-%M-%S")
                new_filename = f"{date_str}_{file}"
                
                # 3. Determine Destination
                destination_path = get_unique_path(SOURCE_ROOT, new_filename)
                
                # 4. Action
                if dry_run:
                    print(f"[DRY RUN] [{source}] {file_path.name} -> {destination_path.name}")
                else:
                    shutil.move(str(file_path), str(destination_path))
                    print(f"✅ Moved: {file_path.name} -> {destination_path.name}")
                
                moved_count += 1
                
            except Exception as e:
                error_msg = f"Failed to process {file_path}: {e}"
                print(f"❌ {error_msg}")
                errors.append(error_msg)

    # Cleanup Empty Directories
    if not dry_run:
        print("\n--- 🧹 Cleaning up empty directories ---")
        # remove_empty_dirs
        for root, dirs, files in os.walk(ORIGINALS_DIR, topdown=False):
            for name in dirs:
                d = os.path.join(root, name)
                try:
                    os.rmdir(d) # os.rmdir only removes if empty
                    print(f"Removed empty dir: {d}")
                except OSError:
                    pass # Directory not empty

    print(f"\n--- ✨ Complete ---")
    print(f"Processed: {moved_count} files")
    if errors:
        print(f"Errors encountered: {len(errors)}")
        for e in errors:
            print(e)

if __name__ == "__main__":
    # Safety Check
    print("WARNING: This script will move and rename files.")
    response = input("Type 'run' to execute in ACTUAL mode, or anything else for DRY RUN: ")
    
    is_dry_run = response.strip().lower() != 'run'
    process_library(dry_run=is_dry_run)
