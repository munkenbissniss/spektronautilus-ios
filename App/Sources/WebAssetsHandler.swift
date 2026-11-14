import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the bundled website (App/www) and the shared temp folder under the address spektro://app/ .
/// A custom scheme is used, not file://, so the pages get a normal origin (localStorage, IndexedDB, fetch, WebAssembly all behave).
final class WebAssetsHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    private var stopped = Set<ObjectIdentifier>()
    private let lock = NSLock()

    override init() {
        root = Bundle.main.resourceURL!.appendingPathComponent("www", isDirectory: true)
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, 400) }
        var path = url.path
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        let file: URL
        if path.hasPrefix("/__tmp/") {
            guard let u = Files.url(String(path.dropFirst(7))) else { return fail(task, 400) }
            file = u
        } else {
            let rel = String(path.dropFirst()).removingPercentEncoding ?? ""
            if rel.contains("..") { return fail(task, 400) }
            file = root.appendingPathComponent(rel)
            if !file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) { return fail(task, 403) }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
              let fh = try? FileHandle(forReadingFrom: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else { return fail(task, 404) }
        defer { try? fh.close() }

        // optional byte range (video elements ask for ranges)
        var start: Int64 = 0, end: Int64 = max(0, size - 1), status = 200
        if let r = task.request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
            let p = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if p.count == 2, let a = Int64(p[0]) { start = a; if let b = Int64(p[1]) { end = min(b, size - 1) }; status = 206 }
        }
        if start > end || start >= size { return fail(task, 416) }
        let length = end - start + 1
        var headers = ["Content-Type": mime(file), "Content-Length": String(length), "Accept-Ranges": "bytes", "Cache-Control": "no-cache"]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        do {
            try fh.seek(toOffset: UInt64(start))
            var left = length
            while left > 0 {
                if isStopped(task) { return }
                let chunk = fh.readData(ofLength: Int(min(left, 1 << 20)))
                if chunk.isEmpty { break }
                task.didReceive(chunk); left -= Int64(chunk.count)
            }
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); stopped.insert(ObjectIdentifier(task as AnyObject)); lock.unlock()
    }
    private func isStopped(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }; return stopped.contains(ObjectIdentifier(task as AnyObject))
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        let r = HTTPURLResponse(url: task.request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        task.didReceive(r); task.didFinish()
    }

    private func mime(_ u: URL) -> String {
        switch u.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"            // needed so WebAssembly can be compiled while it downloads
        case "txt", "xml": return "text/plain; charset=utf-8"
        default: return UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
