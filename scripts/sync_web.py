#!/usr/bin/env python3
"""Copies the built web site (docs/ of the spektronautilus repo) into App/www and injects the iOS bridge.

Source: ./web/docs, the copy of the web site that lives in this repository (or $WEB_DOCS, to try another build).
The video engine (docs/tools/app/vendor, ffmpeg.wasm) must exist in the source for Tools to work offline;
run  python3 web/get-ffmpeg.py  once first."""
import os, re, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "App" / "www"
TAG = '<script src="/ios-bridge.js"></script>'
SKIP_DIRS = {"logos", "__pycache__"}


def find_src():
    for c in (os.environ.get("WEB_DOCS"), ROOT / "web" / "docs"):
        if c and Path(c).is_dir():
            return Path(c)
    sys.exit("Could not find the web site in web/docs. It is part of this repository; check out the whole repository.")


def main():
    src = find_src()
    if OUT.exists():
        shutil.rmtree(OUT)
    n = 0
    for p in src.rglob("*"):
        rel = p.relative_to(src)
        if p.is_dir() or SKIP_DIRS & set(rel.parts) or p.suffix == ".map":
            continue
        dst = OUT / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if p.suffix == ".html":
            h = p.read_text(encoding="utf-8")
            if TAG not in h:
                h, k = re.subn(r"(<head[^>]*>)", lambda m: m.group(1) + TAG, h, count=1, flags=re.I)
                if not k:
                    h = TAG + h
            dst.write_text(h, encoding="utf-8")
        else:
            shutil.copy2(p, dst)
        n += 1
    shutil.copy2(ROOT / "web-shim" / "ios-bridge.js", OUT / "ios-bridge.js")
    vend = OUT / "tools" / "app" / "vendor"
    print(f"{n} files from {src} -> {OUT}")
    if not vend.exists():
        print("WARNING: tools/app/vendor (ffmpeg.wasm) is missing; the Tools page will not work offline.")


if __name__ == "__main__":
    main()
