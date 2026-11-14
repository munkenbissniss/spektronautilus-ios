import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = MainViewController()
        w.makeKeyAndVisible()
        window = w
        Files.cleanTemp(olderThan: 6 * 3600)   // leftovers from an earlier session
        return true
    }
}
