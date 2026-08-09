import UIKit

/// UISearchController treats a hardware Escape press as Cancel and clears the
/// query before responder-chain key commands run. Catch that one press at the
/// window boundary so the app can move focus while preserving the filter.
final class SnippetWindow: UIWindow {
    var onEscapePress: (() -> Bool)?

    private var isConsumingEscapePress = false

    override func sendEvent(_ event: UIEvent) {
        guard let pressesEvent = event as? UIPressesEvent,
              let escapePress = pressesEvent.allPresses.first(where: {
                  $0.key?.keyCode == .keyboardEscape
              }) else {
            super.sendEvent(event)
            return
        }

        if isConsumingEscapePress {
            if escapePress.phase == .ended || escapePress.phase == .cancelled {
                isConsumingEscapePress = false
            }
            return
        }

        if escapePress.phase == .began, onEscapePress?() == true {
            isConsumingEscapePress = true
            return
        }

        super.sendEvent(event)
    }
}

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
        let window = SnippetWindow(windowScene: windowScene)
        window.onEscapePress = { [weak root] in
            root?.handleEscapeBeforeSystemSearch() == true
        }
        window.tintColor = AppTheme.tint
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        rootController = root
        appDelegate.environment.start()

        if CommandLine.arguments.contains("--ui-testing-reset"),
           CommandLine.arguments.contains("--ui-testing-show-shortcuts") {
            DispatchQueue.main.async {
                root.shortcutsCommand()
            }
        }

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
