// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// A TV or monitor (USB-C/HDMI, or AirPlay screen mirroring) shows the game full
// screen, at its own shape, instead of a mirror of the phone with black bars.
// iOS gives the app a scene for the external screen (Info.plist,
// UIWindowSceneSessionRoleExternalDisplayNonInteractive); its window takes the
// one presented layer, MetalHostView.shared, and MetalBackedView lays it out
// there (Fit) instead of on the phone. The phone keeps the touch controls and
// touch-as-mouse, mapped as before. Disconnecting moves the layer back.
// Settings › External display turns it off (madeiraExternalDisplay), which
// leaves iOS's own mirroring. Log tag: [external-display].

final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()
    static let enabledKey = "madeiraExternalDisplay"

    /// The external screen's window while one is connected.
    @Published private(set) var window: UIWindow?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            MetalBackedView.refreshDisplayMode(reason: "external-setting")
        }
    }

    /// Where the game goes: the external screen's view when one is connected and
    /// the setting is on.
    var hostView: UIView? { enabled ? window?.rootViewController?.view : nil }

    /// Logs every scene and screen iOS reports, so a log shows whether iOS
    /// offered the external screen to the app at all. Called once at launch.
    private var observers: [NSObjectProtocol] = []
    func startDiagnostics() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            let role = (note.object as? UIScene)?.session.role.rawValue ?? "?"
            LogStore.shared.log("[external-display] scene connecting role=\(role)")
        })
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                LogStore.shared.log("[external-display] \(note.name.rawValue) screens=\(UIScreen.screens.count) mirrored=\((note.object as? UIScreen)?.mirrored != nil ? 1 : 0)")
            })
        }
        let roles = UIApplication.shared.openSessions.map(\.role.rawValue).joined(separator: ",")
        LogStore.shared.log("[external-display] launch screens=\(UIScreen.screens.count) sessions=\(roles)")
    }

    fileprivate func connect(_ window: UIWindow) {
        self.window = window
        let size = window.screen.nativeBounds.size
        LogStore.shared.log("[external-display] connected \(Int(size.width))x\(Int(size.height)) enabled=\(enabled ? 1 : 0)")
        MetalBackedView.refreshDisplayMode(reason: "external-connect")
    }

    fileprivate func disconnect() {
        window = nil
        LogStore.shared.log("[external-display] disconnected")
        MetalBackedView.refreshDisplayMode(reason: "external-disconnect")
    }
}

/// Gives iOS the external screen's scene. A SwiftUI app's Info.plist scene
/// configurations are not consulted for it, so without this iOS only mirrors
/// the phone. Every other role gets a configuration with no delegate class,
/// which SwiftUI fills with its own (the app's WindowGroup).
final class MadeiraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = ExternalDisplaySceneDelegate.self
            LogStore.shared.log("[external-display] scene requested")
        }
        return config
    }
}

/// The external screen's scene (MadeiraAppDelegate).
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.connect(window)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        ExternalDisplay.shared.disconnect()
    }
}

/// Settings › External display.
struct ExternalDisplaySettingsSection: View {
    @ObservedObject private var display = ExternalDisplay.shared

    var body: some View {
        Section {
            Toggle("Game on the external display", isOn: Binding(get: { display.enabled }, set: { display.enabled = $0 }))
            if let window = display.window {
                let size = window.screen.nativeBounds.size
                LabeledContent("Connected", value: "\(Int(size.width)) × \(Int(size.height))")
            }
        } header: { Text("External display") } footer: {
            Text("With a TV or monitor connected by cable, or by AirPlay screen mirroring, the game fills that screen and this iPhone keeps the touch controls. Off: the screen shows a mirror of the iPhone.")
        }
    }
}
