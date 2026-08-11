import UIKit

@MainActor
protocol SnippetsRootController: AnyObject {
    func open(_ url: URL)
    func handleEscapeBeforeSystemBehavior() -> Bool
    func handleReturnBeforeSystemBehavior() -> Bool
}

extension SnippetsRootController {
    func handleEscapeBeforeSystemBehavior() -> Bool { false }
    func handleReturnBeforeSystemBehavior() -> Bool { false }
}

/// UISearchController and UITableView can consume unmodified hardware keys before
/// responder-chain commands run. Catch Escape and Return at the window boundary
/// so their Mac-style list behavior remains reliable.
final class SnippetWindow: UIWindow {
    var onEscapePress: (() -> Bool)?
    var onReturnPress: (() -> Bool)?

    private var isConsumingEscapePress = false
    private var isConsumingReturnPress = false

    override func sendEvent(_ event: UIEvent) {
        guard let pressesEvent = event as? UIPressesEvent else {
            super.sendEvent(event)
            return
        }

        if let escapePress = pressesEvent.allPresses.first(where: {
            $0.key?.keyCode == .keyboardEscape
        }) {
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
        }

        let appModifiers: UIKeyModifierFlags = [.command, .alternate, .control, .shift]
        if let returnPress = pressesEvent.allPresses.first(where: {
            $0.key?.keyCode == .keyboardReturnOrEnter
                || $0.key?.keyCode == .keypadEnter
        }) {
            if isConsumingReturnPress {
                if returnPress.phase == .ended || returnPress.phase == .cancelled {
                    isConsumingReturnPress = false
                }
                return
            }

            if pressesEvent.modifierFlags.intersection(appModifiers).isEmpty,
               returnPress.phase == .began,
               onReturnPress?() == true {
                isConsumingReturnPress = true
                return
            }
        }

        super.sendEvent(event)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    let environment = AppEnvironment()

    nonisolated static func allowsExtensionPoint(_ identifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        // UIKit has no public per-text-view switch for third-party keyboards. Secure
        // snippet bodies are editable plaintext after authentication, so allowing a
        // keyboard extension would hand every keystroke to another process. Apply the
        // platform-supported app-wide policy instead.
        identifier != .keyboard
    }

    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        Self.allowsExtensionPoint(extensionPointIdentifier)
    }

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

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        environment.receivedMemoryWarning()
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var rootController: (UIViewController & SnippetsRootController)?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

        let root: UIViewController & SnippetsRootController
        if windowScene.traitCollection.userInterfaceIdiom == .phone {
            root = PhoneRootViewController(environment: appDelegate.environment)
        } else {
            root = MainSplitViewController(environment: appDelegate.environment)
        }
        let window = SnippetWindow(windowScene: windowScene)
        window.onEscapePress = { [weak root] in
            root?.handleEscapeBeforeSystemBehavior() == true
        }
        window.onReturnPress = { [weak root] in
            root?.handleReturnBeforeSystemBehavior() == true
        }
        window.tintColor = AppTheme.tint
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        rootController = root
        appDelegate.environment.start()

        if CommandLine.arguments.contains("--ui-testing-reset"),
           CommandLine.arguments.contains("--ui-testing-show-shortcuts"),
           let splitRoot = root as? MainSplitViewController {
            DispatchQueue.main.async {
                splitRoot.shortcutsCommand()
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

extension MainSplitViewController: SnippetsRootController {}
