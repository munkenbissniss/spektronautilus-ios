# Architecture

**Why not Capacitor?** It was the plan, but the build machine could not reach the npm registry, and Capacitor would also bring a
dependency tree for something small. The shell is ~600 lines of Swift (UIKit + WKWebView) that we fully control. Capacitor can be swapped in later; the web side only talks to `window.SPK_IOS`.

## Shell
- `MainViewController` owns a `WKWebView` that loads `spektro://app/index.html`.
- `WebAssetsHandler` (`WKURLSchemeHandler`) serves `App/www` with correct MIME types and byte-range requests (needed for `<video>`), and `spektro://app/__tmp/<name>` from the temp folder (results of native jobs).
- Media capture (microphone for VJ sound sources) is granted for the `spektro` origin only.
- Downloads (`WKDownload`) open the share sheet.

## Bridge
JS → Swift: `webkit.messageHandlers.spk.postMessage({m:"plugin.method", a:{…}})` returns a Promise (WKScriptMessageHandlerWithReply).
Swift → JS: `window.__spk.emit({n:"event", d:{…}})`.
Plugins: `app`, `files`, `midi`, `transcode`, `display`, `upscale` (each a `Plugin` registered in `Bridge`).
Files move in 3 MB base64 chunks (`files.put`) into `NSTemporaryDirectory()/spk`; results are fetched via `/__tmp/…`. Temp is cleaned on start.

## Web side
`web-shim/ios-bridge.js` creates `window.SPK_IOS` only when the native handler exists. Features used by the site:
- `tools/app/app.js` `processOne`: plain *Convert* jobs → `SPK_IOS.convert` (fallback to ffmpeg.wasm on any non-cancel error).
- `vj-pad/app.js` `openOutput`: with `SPK_IOS.display`, the button toggles the external screen.
- MIDI and wake lock are stand-ins on `navigator`, so no site code changed.

## Known limits
- External display sends JPEG frames over the bridge: fine for a projector preview, not broadcast quality. A Metal/AVPlayer path would be better.
- With two MIDI controllers, all messages go to the first one's handler.
- Heavy web jobs (ffmpeg.wasm) are bound by WebKit's memory limit on iPhone; large files should use the native path.
