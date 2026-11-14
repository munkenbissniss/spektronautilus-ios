import UIKit

/// Small things only the app can do: keep the screen on, open the share sheet.
final class AppPlugin: Plugin {
    private weak var presenter: UIViewController?
    init(presenter: UIViewController) { self.presenter = presenter }

    func call(_ method: String, _ args: [String: Any], done: @escaping (Any?) -> Void, fail: @escaping (String) -> Void) {
        switch method {
        case "keepAwake":
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = (args["on"] as? Bool) ?? false; done(true) }
        case "info":
            let b = Bundle.main
            done(["version": b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                  "build": b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                  "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
                  "memoryMB": Int(ProcessInfo.processInfo.physicalMemory / 1_000_000),
                  "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled])
        default: fail("Unknown method app.\(method)")
        }
    }
}
