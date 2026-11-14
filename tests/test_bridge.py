"""Bridge tests: the web shim and the web wiring, with a mocked native side (no Mac needed).
Run:  python3 scripts/sync_web.py && python3 tests/test_bridge.py"""
import http.server, threading, functools, sys, json
from pathlib import Path
from playwright.sync_api import sync_playwright

WWW = Path(__file__).resolve().parent.parent / "App" / "www"
MOCK = """
window.__log = [];
window.webkit = { messageHandlers: { spk: { postMessage: async (msg) => {
  window.__log.push(msg);
  switch (msg.m) {
    case 'midi.start': return [{ id: 1, name: 'Mock Pad' }];
    case 'display.start': return { ok: true };
    case 'transcode.probe': return { width: 1920, height: 1080, duration: 4, fps: 30, hasAudio: false, codec: 'h264' };
    default: return {};
  } } } } };
"""
PASS = FAIL = 0
def check(name, ok, extra=""):
    global PASS, FAIL
    print(("PASS " if ok else "FAIL ") + name + (" " + str(extra) if not ok else ""))
    PASS += ok; FAIL += (not ok)

def serve():
    h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(WWW))
    h.log_message = lambda *a, **k: None
    s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), h); threading.Thread(target=s.serve_forever, daemon=True).start()
    return s, s.server_address[1]

srv, port = serve(); base = f"http://127.0.0.1:{port}"
with sync_playwright() as p:
    b = p.chromium.launch()
    # 1. normal browser: the shim does nothing
    pg = b.new_page(); pg.goto(base + "/vj-pad/index.html")
    check("shim is a no-op outside the app", pg.evaluate("typeof window.SPK_IOS") == "undefined")
    check("shim script is in the page", "ios-bridge.js" in (WWW / "vj-pad" / "index.html").read_text())
    pg.close()
    # 2. inside the app (mocked)
    ctx = b.new_context(); ctx.add_init_script(MOCK); pg = ctx.new_page()
    errs = []; pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(base + "/vj-pad/index.html"); pg.wait_for_function("window.SPK && window.SPK_IOS", timeout=15000)
    check("SPK_IOS exists in the app", pg.evaluate("SPK_IOS.platform") == "ios")
    # MIDI
    pg.evaluate("document.querySelector('#midiOn').click()"); pg.wait_for_timeout(500)
    pg.evaluate("__spk.emit({n:'midi.messages', d:[[144,60,100]]})"); pg.wait_for_timeout(200)
    check("MIDI from CoreMIDI reaches the mixer", "#60" in pg.text_content("#midiLast"), pg.text_content("#midiLast"))
    # external screen
    pg.evaluate("document.querySelector('#openOut').click()"); pg.wait_for_timeout(800)
    log = pg.evaluate("__log.map(m=>m.m)")
    check("output button starts the external display", "display.start" in log, log)
    check("frames are sent to the display", "display.frame" in log, log)
    pg.evaluate("document.querySelector('#openOut').click()"); pg.wait_for_timeout(300)
    check("second tap stops it", "display.stop" in pg.evaluate("__log.map(m=>m.m)"))
    # files in chunks + probe
    r = pg.evaluate("""async()=>{ const f=new File([new Uint8Array(7*1024*1024)],'a b.mp4'); const i=await SPK_IOS.probe(f);
        return {i, puts: __log.filter(m=>m.m==='files.put').map(m=>m.a.offset)} }""")
    check("7 MB file goes in 3 chunks", r["puts"] == [0, 3145728, 6291456], r["puts"])
    check("probe returns native size", r["i"]["width"] == 1920 and r["i"]["nativeFile"].startswith("in"), r["i"])
    check("no page errors", not errs, errs)
    b.close()
print(f"{PASS} passed, {FAIL} failed"); sys.exit(1 if FAIL else 0)
