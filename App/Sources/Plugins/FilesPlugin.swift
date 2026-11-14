import UIKit

/// Big files between the page and the app. The page cannot hand a File to native code directly, so it sends it in pieces ("put"),
/// native code works on the file in the temp folder, and the result is read back by the page with fetch("/__tmp/<name>").
final class FilesPlugin: Plugin {
    private weak var presenter: UIViewController?
    init(presenter: UIViewController) { self.presenter = presenter }

    func call(_ method: String, _ args: [String: Any], done: @escaping (Any?) -> Void, fail: @escaping (String) -> Void) {
        switch method {
        case "put":      // { name, offset, b64 }   offset 0 starts a new file
            guard let name = args["name"] as? String, let u = Files.url(name), let b64 = args["b64"] as? String,
                  let data = Data(base64Encoded: b64) else { return fail("Bad file piece") }
            let offset = (args["offset"] as? NSNumber)?.uint64Value ?? 0
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if offset == 0 { FileManager.default.createFile(atPath: u.path, contents: nil) }
                    let fh = try FileHandle(forWritingTo: u); defer { try? fh.close() }
                    try fh.seek(toOffset: offset); try fh.write(contentsOf: data)
                    done(["size": Int(offset) + data.count])
                } catch { fail(error.localizedDescription) }
            }
        case "remove":
            if let name = args["name"] as? String, let u = Files.url(name) { try? FileManager.default.removeItem(at: u) }
            done(true)
        case "free":     // free disk space in MB, so the page can warn before a long job
            let v = try? URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            done(["freeMB": Int((v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000)])
        case "share":    // { name }
            guard let name = args["name"] as? String, let u = Files.url(name), FileManager.default.fileExists(atPath: u.path) else { return fail("No such file") }
            DispatchQueue.main.async { if let p = self.presenter { FilesPlugin.share(u, from: p) }; done(true) }
        default: fail("Unknown method files.\(method)")
        }
    }

    static func share(_ url: URL, from vc: UIViewController) {
        DispatchQueue.main.async {
            let a = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            a.popoverPresentationController?.sourceView = vc.view
            a.popoverPresentationController?.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
            vc.present(a, animated: true)
        }
    }
}
