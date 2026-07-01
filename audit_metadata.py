import os
import pathlib
import datetime
import csv
from PIL import Image, ExifTags
from hachoir.parser import createParser
from hachoir.metadata import extractMetadata
import pillow_heif

pillow_heif.register_heif_opener()

# --- CONFIGURATION ---
SOURCE_ROOT = pathlib.Path("/Users/martinmana/Pictures/PHLOOK")
ORIGINALS_DIR = SOURCE_ROOT / "originals"
CSV_REPORT_PATH = pathlib.Path("/Users/martinmana/Documents/GitHub/PhlookDev/metadata_audit.csv")

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

    # 3. Fallback: OS Birth Time or Modification Time
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

def audit_library():
    """
    Walks through ORIGINALS_DIR and writes metadata info to CSV.
    """
    print(f"--- 🕵️‍♀️ Starting Metadata Audit ---")
    print(f"Source: {ORIGINALS_DIR}")
    print(f"Report: {CSV_REPORT_PATH}\n")

    if not ORIGINALS_DIR.exists():
        print(f"❌ Error: Originals directory does not exist: {ORIGINALS_DIR}")
        return

    processed_count = 0
    
    with open(CSV_REPORT_PATH, 'w', newline='', encoding='utf-8') as csvfile:
        fieldnames = ['Original Filename', 'Date Taken', 'Source', 'Path']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()

        for root, dirs, files in os.walk(ORIGINALS_DIR):
            for file in files:
                # Skip known junk
                if file.startswith('.') or file.lower().endswith('.aae'):
                    continue
                    
                file_path = pathlib.Path(root) / file
                
                try:
                    date_taken, source = get_date_taken(file_path)
                    
                    writer.writerow({
                        'Original Filename': file,
                        'Date Taken': date_taken,
                        'Source': source,
                        'Path': str(file_path)
                    })
                    
                    processed_count += 1
                    if processed_count % 100 == 0:
                        print(f"Audited {processed_count} files...", end='\r')
                        
                except Exception as e:
                    print(f"❌ Error processing {file}: {e}")

    print(f"\n\n--- ✅ Audit Complete ---")
    print(f"Total Files Audited: {processed_count}")
    print(f"CSV generated at: {CSV_REPORT_PATH}")

if __name__ == "__main__":
    audit_library()
