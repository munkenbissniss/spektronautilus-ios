import Foundation
import WebKit

/// A plugin answers calls from the web page. `method` is the part after the dot in "files.put".
/// Results must be plain values (numbers, strings, arrays, dictionaries) so they can travel to JavaScript.
protocol Plugin: AnyObject {
    func call(_ method: String, _ args: [String: Any], done: @escaping (Any?) -> Void, fail: @escaping (String) -> Void)
}

/// Messages from the page arrive as  webkit.messageHandlers.spk.postMessage({ m: "files.put", a: {...} })  and are answered with a promise.
/// Events the other way (a MIDI note, a screen being plugged in) go through  window.__spk.emit(name, data) .
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var web: WKWebView?
    private var plugins: [String: Plugin] = [:]

    func register(_ name: String, _ p: Plugin) { plugins[name] = p }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let m = body["m"] as? String else { return replyHandler(nil, "Bad message") }
        let parts = m.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let plugin = plugins[parts[0]] else { return replyHandler(nil, "Unknown call \(m)") }
        let args = body["a"] as? [String: Any] ?? [:]
        plugin.call(parts[1], args, done: { result in
            DispatchQueue.main.async { replyHandler(result ?? NSNull(), nil) }
        }, fail: { error in
            DispatchQueue.main.async { replyHandler(nil, error) }
        })
    }

    func emit(_ name: String, _ data: Any) {
        guard let web = web,
              let json = try? JSONSerialization.data(withJSONObject: ["n": name, "d": data], options: [.fragmentsAllowed]),
              let s = String(data: json, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            web.evaluateJavaScript("window.__spk && window.__spk.emit(JSON.parse(\(Bridge.quote(s))))", completionHandler: nil)
        }
    }

    /// a JSON text as a JavaScript string literal
    private static func quote(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
