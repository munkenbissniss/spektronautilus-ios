/* Spektronautilus for iPhone/iPad: the glue between the website and the app.
   Loaded first on every page by scripts/sync_web.py. In a normal browser (no webkit.messageHandlers.spk) it does nothing at all.
   In the app it adds:
     window.SPK_IOS            the native helpers (files, converting with the phone's video chips, external screen, AI)
     navigator.requestMIDIAccess   Safari on iPhone has no Web MIDI; this stand-in is fed by CoreMIDI, so the mixers' MIDI works unchanged
     navigator.wakeLock        also keeps the screen on through the app (iOS can ignore the web version) */
(function () {
  var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.spk;
  if (!mh || window.SPK_IOS) return;

  var listeners = {};
  function on(name, fn) { (listeners[name] = listeners[name] || []).push(fn); return function () { listeners[name] = (listeners[name] || []).filter(function (f) { return f !== fn; }); }; }
  function call(m, a) { return mh.postMessage({ m: m, a: a || {} }); }
  window.__spk = { emit: function (ev) { (listeners[ev.n] || []).slice().forEach(function (f) { try { f(ev.d); } catch (e) { console.error(e); } }); } };

  var IOS = window.SPK_IOS = { native: true, call: call, on: on, platform: 'ios', features: { midi: true, files: true, transcode: true, display: true, upscale: false } };
  document.documentElement.classList.add('spk-ios-app');

  // ---------------------------------------------------------------- big files between page and app
  var CHUNK = 3 * 1024 * 1024;
  function toB64(blob) {
    return new Promise(function (res, rej) { var r = new FileReader(); r.onload = function () { var s = String(r.result); res(s.slice(s.indexOf(',') + 1)); }; r.onerror = function () { rej(r.error); }; r.readAsDataURL(blob); });
  }
  var seq = 0, sent = new WeakMap();
  /** sends a File to the app's temp folder; returns the name it got there. The same File is only sent once. */
  IOS.putFile = function (file, onProgress) {
    if (sent.has(file)) return sent.get(file);
    var name = 'in' + (++seq) + '_' + String(file.name || 'file').replace(/[^\w.-]+/g, '_').slice(-60);
    var p = (async function () {
      for (var off = 0; off < file.size || off === 0; off += CHUNK) {
        await call('files.put', { name: name, offset: off, b64: await toB64(file.slice(off, off + CHUNK)) });
        if (onProgress) onProgress(Math.min(1, (off + CHUNK) / Math.max(1, file.size)));
        if (file.size === 0) break;
      }
      return name;
    })();
    sent.set(file, p);
    p.catch(function () { sent.delete(file); });
    return p;
  };
  IOS.removeFile = function (name) { return call('files.remove', { name: name }).catch(function () {}); };
  IOS.fetchFile = async function (name) { var r = await fetch('/__tmp/' + encodeURIComponent(name)); if (!r.ok) throw new Error('Could not read the result from the app (' + r.status + ').'); return r.blob(); };
  IOS.share = function (name) { return call('files.share', { name: name }); };
  IOS.freeMB = function () { return call('files.free').then(function (r) { return r.freeMB; }).catch(function () { return null; }); };

  // ---------------------------------------------------------------- converting with the phone's video chips
  IOS.probe = async function (file) {
    var name = await IOS.putFile(file); var i = await call('transcode.probe', { file: name });
    return { width: i.width, height: i.height, duration: i.duration, fps: i.fps, hasAudio: !!i.hasAudio, codec: i.codec, isGif: false, alpha: false, nativeFile: name };
  };
  /** opts: width, height, fit, fps, codec ('h264'|'hevc'), bpp, keepAudio, start, duration, gop, onProgress. Returns a Blob (an mp4). */
  IOS.convert = async function (file, opts) {
    opts = opts || {}; var name = await IOS.putFile(file), out = 'out' + (++seq) + '.mp4';
    var off = opts.onProgress ? on('transcode.progress', function (d) { opts.onProgress(d.p); }) : null;
    try { await call('transcode.convert', { file: name, out: out, width: opts.width, height: opts.height, fit: opts.fit || 'keep', fps: opts.fps || 0, codec: opts.codec || 'h264', bpp: opts.bpp || 0.2, keepAudio: !!opts.keepAudio, start: opts.start || 0, duration: opts.duration || 0, gop: opts.gop || 30 }); }
    finally { if (off) off(); }
    try { return await IOS.fetchFile(out); } finally { IOS.removeFile(out); }
  };
  IOS.cancelConvert = function () { return call('transcode.cancel').catch(function () {}); };
  IOS.upscaleStatus = function () { return call('upscale.status').catch(function () { return { ok: false }; }); };

  // ---------------------------------------------------------------- external screen (projector, TV): the output of the VJ mixer, sent as pictures
  var disp = { running: false, timer: 0, busy: false, canvas: null, status: { available: false } };
  IOS.display = {
    status: function () { return call('display.status').then(function (s) { disp.status = s; return s; }); },
    onChange: function (fn) { return on('display.changed', function (s) { disp.status = s; fn(s); }); },
    /** shows the canvas on the external screen (about 30 pictures a second); returns false when no screen is connected */
    start: async function (canvas, opts) {
      opts = opts || {}; var s = await call('display.start').catch(function () { return null; }); if (!s) return false;
      disp.canvas = canvas; disp.running = true; clearInterval(disp.timer);
      var q = opts.quality || 0.72;
      disp.timer = setInterval(function () {
        if (disp.busy || !disp.running) return; disp.busy = true;
        canvas.toBlob(function (b) {
          if (!b) { disp.busy = false; return; }
          toB64(b).then(function (b64) { return call('display.frame', { b64: b64 }); }).catch(function () {}).then(function () { disp.busy = false; });
        }, 'image/jpeg', q);
      }, Math.round(1000 / (opts.fps || 30)));
      return true;
    },
    stop: function () { disp.running = false; clearInterval(disp.timer); return call('display.stop').catch(function () {}); },
    get running() { return disp.running; },
  };

  // ---------------------------------------------------------------- MIDI: a stand-in for Web MIDI, fed by CoreMIDI
  var midi = { inputs: new Map(), access: null };
  function MidiInput(d) {
    this.id = String(d.id); this.name = d.name; this.manufacturer = ''; this.type = 'input'; this.state = 'connected'; this.connection = 'open'; this.version = '1'; this.onmidimessage = null; this._l = [];
  }
  MidiInput.prototype.addEventListener = function (t, fn) { if (t === 'midimessage') this._l.push(fn); };
  MidiInput.prototype.removeEventListener = function (t, fn) { this._l = this._l.filter(function (f) { return f !== fn; }); };
  MidiInput.prototype._fire = function (bytes) {
    var ev = { type: 'midimessage', data: new Uint8Array(bytes), target: this, timeStamp: performance.now() };
    if (this.onmidimessage) this.onmidimessage(ev); this._l.forEach(function (f) { f(ev); });
  };
  function sync(list) {
    var ids = {}; list.forEach(function (d) { ids[d.id] = 1; if (!midi.inputs.has(String(d.id))) midi.inputs.set(String(d.id), new MidiInput(d)); });
    Array.from(midi.inputs.keys()).forEach(function (k) { if (!ids[k]) midi.inputs.delete(k); });
    if (midi.access && midi.access.onstatechange) midi.access.onstatechange({ type: 'statechange', target: midi.access });
  }
  on('midi.devices', sync);
  on('midi.messages', function (msgs) { var first = midi.inputs.values().next().value; msgs.forEach(function (m) { if (first) first._fire(m); }); });
  navigator.requestMIDIAccess = async function () {
    sync(await call('midi.start'));
    midi.access = { inputs: midi.inputs, outputs: new Map(), onstatechange: null, sysexEnabled: false, addEventListener: function () {}, removeEventListener: function () {} };
    return midi.access;
  };
  // (the first connected device receives everything; with two controllers at once both feed the first one's handler, which is what the mixers' "learn" expects)

  // ---------------------------------------------------------------- keep the screen on
  var lock = 0;
  navigator.wakeLock = {
    request: async function () {
      lock++; call('app.keepAwake', { on: true });
      var released = false, s = { released: false, type: 'screen', addEventListener: function () {}, release: async function () { if (released) return; released = true; s.released = true; if (--lock <= 0) { lock = 0; call('app.keepAwake', { on: false }); } } };
      return s;
    },
  };
})();
