import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let environment = AppEnvironment()

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var rootController: MainSplitViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

        let root = MainSplitViewController(environment: appDelegate.environment)
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = AppTheme.tint
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        rootController = root
        appDelegate.environment.start()

        for context in connectionOptions.urlContexts {
            root.open(context.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            rootController?.open(context.url)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.environment.becameActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.environment.enteredBackground()
    }
}
