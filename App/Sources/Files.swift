import Foundation

/// The folder the web pages and the plugins share for big files (loops going in, finished videos coming out).
/// The web side reaches it through spektro://app/__tmp/<name>. Names are plain file names: no folders, no "..".
enum Files {
    static let dir: URL = {
        let u = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("spk", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func clean(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.count > 120 || n.contains("/") || n.contains("\\") || n.contains("..") || n.hasPrefix(".") { return nil }
        return n
    }

    static func url(_ name: String) -> URL? {
        guard let n = clean(name) else { return nil }
        return dir.appendingPathComponent(n)
    }

    static func cleanTemp(olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(d) > seconds { try? fm.removeItem(at: u) }
        }
    }
}
