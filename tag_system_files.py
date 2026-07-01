import os
import pathlib
import datetime
import subprocess
from PIL import Image, ExifTags
from hachoir.parser import createParser
from hachoir.metadata import extractMetadata
import pillow_heif

pillow_heif.register_heif_opener()

# --- CONFIGURATION ---
SOURCE_ROOT = pathlib.Path("/Users/martinmana/Pictures/PHLOOK")
ORIGINALS_DIR = SOURCE_ROOT / "originals"

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
        if hasattr(stat, 'st_birthtime'):
             timestamp = stat.st_birthtime
        else:
             timestamp = stat.st_mtime
        return datetime.datetime.fromtimestamp(timestamp), "System"
    except Exception:
        return datetime.datetime.now(), "ErrorFallback"

def apply_tag(path, tag_name="Yellow"):
    """Applies a Finder tag using the 'tag' CLI tool."""
    try:
        subprocess.run(['tag', '-a', tag_name, str(path)], check=True)
        return True
    except subprocess.CalledProcessError:
        return False

def tag_files():
    """
    Walks through ORIGINALS_DIR, finds 'System' source files, tags them Yellow.
    """
    print(f"--- 🏷️  Starting Tagger ---")
    print(f"Directory: {ORIGINALS_DIR}")
    print(f"Target Source: 'System'\n")

    if not ORIGINALS_DIR.exists():
        print(f"❌ Error: Originals directory does not exist.")
        return

    tagged_count = 0
    scanned_count = 0
    
    for root, dirs, files in os.walk(ORIGINALS_DIR):
        for file in files:
            # Skip junk
            if file.startswith('.') or file.lower().endswith('.aae'):
                continue
                
            file_path = pathlib.Path(root) / file
            scanned_count += 1
            
            try:
                date_taken, source = get_date_taken(file_path)
                
                if source == "System" or source == "ErrorFallback":
                    success = apply_tag(file_path, "Yellow")
                    if success:
                        print(f"🟡 Tagged: {file}")
                        tagged_count += 1
                    else:
                        print(f"❌ Failed to tag: {file}")
            
            except Exception as e:
                print(f"❌ Error processing {file}: {e}")
            
            if scanned_count % 500 == 0:
                print(f"Scanned {scanned_count} files...", end='\r')

    print(f"\n\n--- ✅ Tagging Complete ---")
    print(f"Total Files Scanned: {scanned_count}")
    print(f"Total Files Tagged Yellow: {tagged_count}")

if __name__ == "__main__":
    tag_files()
