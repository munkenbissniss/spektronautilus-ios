# Spektronautilus for iPhone & iPad

The native iOS app of **Spektronautilus – the magic video mixer**. The whole site (VJ Mixer, Magic Mixer, Video DJ, Tools, Loop Hospital …)
runs inside the app, offline, and a few heavy jobs use the phone's own hardware instead of the browser.

> **Status: untested on a device.** This repo was written without access to a Mac or Xcode. The Swift code has never been compiled.
> The web side (bridge shim, Tools fast path, external-screen button) is tested with a stand-in for the app (`tests/test_bridge.py`).
> The first CI run on macOS will probably need a few small compiler fixes. See "First build" below.

## What is native, what is web

| Part | How |
|---|---|
| All screens, mixers, tools | The website, bundled in `App/www`, served to a `WKWebView` through `spektro://app/` |
| Converting video (Tools → Convert) | **Native**: AVAssetReader/Writer, hardware H.264/HEVC. No ffmpeg.wasm, no memory copy |
| MIDI controllers | **Native**: CoreMIDI, shown to the mixers as normal Web MIDI (Safari has none) |
| External screen / projector | **Native**: VJ mixer output sent as pictures to a second `UIWindow` (experimental, ~30 fps) |
| Screen stays on, share sheet, save to Photos | Native |
| AI upscaling | Scaffold only: needs a Core ML model (`models/convert_realesrgan.py`, untested). Off until `Upscale.mlmodelc` is in the app |
| Everything else (filters, loops, Magic Mixer render, ffmpeg.wasm fallback) | Web, unchanged |

Not done: native rendering for Magic Mixer, a real shipped AI model.

## Layout

```
project.yml               XcodeGen project (iOS 16, bundle id no.spektronautilus.app)
App/Sources               Swift: shell, URL scheme handler, bridge, plugins
App/Resources             icons, launch colour, (Models/ for Core ML)
web-shim/ios-bridge.js    injected first on every page; does nothing outside the app
scripts/sync_web.py       copies the website into App/www and injects the shim
tests/test_bridge.py      Playwright tests with a mocked native side
.github/workflows/ios.yml CI: bridge tests (Linux) + simulator build (macOS)
docs/                     ARCHITECTURE.md, APPSTORE.md
```

## Set-up

This repository stands on its own: `web/docs` is a copy of the Spektronautilus web site that the app bundles.

```bash
python3 web/get-ffmpeg.py            # once: puts ffmpeg.wasm in the site (fallback engine for non-convert tools)
```

To bring in a newer web site later (optional): `python3 scripts/update_web.py /path/to/spektronautilus` (after running that repository's `build.py`).

## First build (Mac)

```bash
brew install xcodegen
python3 scripts/sync_web.py
xcodegen generate
open Spektronautilus.xcodeproj       # pick your Team under Signing, choose your iPhone, Run
```

If the compiler complains, the errors are small and local: fix and push; CI runs the same build on every push.

## Tests

```bash
python3 scripts/sync_web.py && python3 tests/test_bridge.py     # Linux/Mac, needs playwright
```

In the web repo: `python3 tests_ios_fastpath.py` (Tools fast path).
