import os
import pathlib
import argparse

# --- CONFIGURATION ---
SOURCE_ROOT = pathlib.Path("/Users/martinmana/Pictures/PHLOOK")

def cleanup_aae(dry_run=True):
    """
    Scans SOURCE_ROOT for .AAE files and deletes them.
    """
    print(f"--- 🧹 AAE Cleanup Tool (Dry Run: {dry_run}) ---")
    print(f"Target: {SOURCE_ROOT}\n")

    if not SOURCE_ROOT.exists():
        print(f"❌ Error: Directory does not exist: {SOURCE_ROOT}")
        return

    found_count = 0
    deleted_count = 0
    size_reclaimed = 0

    for root, dirs, files in os.walk(SOURCE_ROOT):
        for file in files:
            if file.lower().endswith('.aae'):
                file_path = pathlib.Path(root) / file
                found_count += 1
                
                try:
                    file_size = file_path.stat().st_size
                    size_reclaimed += file_size
                except:
                    file_size = 0

                if dry_run:
                    print(f"[DRY RUN] Found: {file_path.name}")
                else:
                    try:
                        file_path.unlink()
                        print(f"🗑️  Deleted: {file_path.name}")
                        deleted_count += 1
                    except Exception as e:
                        print(f"❌ Error deleting {file_path.name}: {e}")

    print(f"\n--- ✨ Cleanup Complete ---")
    if dry_run:
        print(f"Found {found_count} .AAE files.")
        print(f"Potential space reclaimed: {size_reclaimed / 1024:.2f} KB")
        print("\nrun with '--execute' to actually delete these files.")
    else:
        print(f"Deleted {deleted_count} of {found_count} files.")
        print(f"Space reclaimed: {size_reclaimed / 1024:.2f} KB")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cleanup .AAE files")
    parser.add_argument("--execute", action="store_true", help="Actually delete files")
    args = parser.parse_args()
    
    cleanup_aae(dry_run=not args.execute)
