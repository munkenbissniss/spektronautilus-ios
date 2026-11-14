import UIKit

/// A projector or TV on the other end of a cable (or AirPlay): the page sends pictures of its output, this shows them full screen there.
/// EXPERIMENTAL: written against the classic external-screen API and not yet tried on real hardware.
final class DisplayPlugin: Plugin {
    private weak var bridge: Bridge?
    private var window: UIWindow?
    private let imageView = UIImageView()
    private var decoding = false

    init(bridge: Bridge) {
        self.bridge = bridge
        NotificationCenter.default.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { [weak self] _ in self?.changed() }
        NotificationCenter.default.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { [weak self] _ in self?.changed(gone: true) }
    }

    private var external: UIScreen? { UIScreen.screens.first { $0 != UIScreen.main } }

    private func status() -> [String: Any] {
        guard let s = external else { return ["available": false, "active": window != nil] }
        return ["available": true, "active": window != nil, "width": Int(s.bounds.width * s.scale), "height": Int(s.bounds.height * s.scale)]
    }

    private func changed(gone: Bool = false) {
        if gone && external == nil { window?.isHidden = true; window = nil }
        bridge?.emit("display.changed", status())
    }

    func call(_ method: String, _ args: [String: Any], done: @escaping (Any?) -> Void, fail: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            switch method {
            case "status": done(self.status())
            case "start":
                guard let s = self.external else { return fail("No external screen") }
                let w = UIWindow(frame: s.bounds)
                w.screen = s
                w.backgroundColor = .black
                self.imageView.frame = w.bounds
                self.imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.imageView.contentMode = .scaleAspectFit
                self.imageView.backgroundColor = .black
                w.addSubview(self.imageView)
                w.isHidden = false
                self.window = w
                done(self.status())
            case "frame":       // { b64: "<jpeg>" }
                guard self.window != nil, !self.decoding, let b64 = args["b64"] as? String else { return done(false) }
                self.decoding = true
                DispatchQueue.global(qos: .userInteractive).async {
                    let img = Data(base64Encoded: b64).flatMap { UIImage(data: $0) }
                    DispatchQueue.main.async { if let img = img { self.imageView.image = img }; self.decoding = false; done(true) }
                }
            case "stop":
                self.window?.isHidden = true; self.window = nil; self.imageView.image = nil; done(self.status())
            default: fail("Unknown method display.\(method)")
            }
        }
    }
}
