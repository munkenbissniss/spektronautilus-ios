#!/usr/bin/env python3
"""Optional: copies a newer build of the Spektronautilus web site into web/ (docs and get-ffmpeg.py). This repository works without it.
   python3 scripts/update_web.py /path/to/spektronautilus     (run that repository's build.py first)"""
import shutil, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2: sys.exit(__doc__)
SRC = Path(sys.argv[1]).resolve()
if not (SRC / "docs" / "index.html").exists(): sys.exit(f"No built web site in {SRC / 'docs'}")
vendor = ROOT / "web" / "docs" / "tools" / "app" / "vendor"; keep = None
if vendor.exists() and not (SRC / "docs" / "tools" / "app" / "vendor").exists():   # keep an ffmpeg.wasm that was already fetched
    keep = ROOT / "web" / ".vendor-keep"; shutil.rmtree(keep, ignore_errors=True); shutil.move(str(vendor), keep)
shutil.rmtree(ROOT / "web" / "docs", ignore_errors=True)
shutil.copytree(SRC / "docs", ROOT / "web" / "docs", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
if keep: shutil.move(str(keep), vendor)
shutil.copy2(SRC / "get-ffmpeg.py", ROOT / "web" / "get-ffmpeg.py")
print("web/ updated from", SRC)
