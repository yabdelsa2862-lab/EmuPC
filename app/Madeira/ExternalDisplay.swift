// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Combine
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
            syncAccessory()
            winios_set_external_host(hostView)
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
        registerAccessory(attempt: 0)
    }

    /// iOS 27: an app built with the iOS 27 SDK no longer gets the external
    /// screen's scene on its own (AirPlay and cables just mirrored the phone, no
    /// `scene requested` line). It has to register a scene accessory on a view
    /// controller; iOS then connects ExternalDisplaySceneDelegate's scene while
    /// that controller is on screen and a display is there.
    private var registration: AnyObject?
    private weak var registeredOn: UIViewController?
    private func registerAccessory(attempt: Int) {
        guard #available(iOS 27.0, *) else { return }
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        guard let root else {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.registerAccessory(attempt: attempt + 1) } }
            else { LogStore.shared.log("[external-display] accessory: no main window to register on") }
            return
        }
        guard registeredOn !== root else { return }
        let config = UISceneConfiguration(name: "External display", sessionRole: .windowExternalDisplayNonInteractive)
        config.delegateClass = ExternalDisplaySceneDelegate.self
        let reg = root.registerSceneAccessory(.externalNonInteractive(sceneConfiguration: config))
        reg.isEnabled = enabled
        registration = reg; registeredOn = root
        LogStore.shared.log("[external-display] accessory registered on \(type(of: root)) available=\(reg.isAvailable ? 1 : 0) enabled=\(reg.isEnabled ? 1 : 0)")
    }

    private func syncAccessory() {
        guard #available(iOS 27.0, *), let reg = registration as? UISceneAccessoryRegistration else { return }
        reg.isEnabled = enabled
    }

    fileprivate func connect(_ window: UIWindow) {
        // A 4K AirPlay stream held games at 30 FPS: offer the TV 1080p when it has it
        // (MADEIRA_TV_4K=1 keeps the TV's own mode).
        let screen = window.screen
        let modes = screen.availableModes.map { "\(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: ",")
        LogStore.shared.log("[external-display] modes=\(modes) current=\(screen.currentMode.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "?")")
        if !MadeiraConfig.flag("MADEIRA_TV_4K", fallback: false),
           let hd = screen.availableModes.first(where: { Int($0.size.width) == 1920 && Int($0.size.height) == 1080 }),
           screen.currentMode != hd {
            screen.currentMode = hd
            LogStore.shared.log("[external-display] mode set to 1920x1080")
        }
        self.window = window
        let size = window.screen.nativeBounds.size
        LogStore.shared.log("[external-display] connected \(Int(size.width))x\(Int(size.height)) enabled=\(enabled ? 1 : 0)")
        // Desktop sessions draw every window into Winios' compositor: it moves too.
        winios_set_external_host(hostView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak window] in
            guard let window else { return }
            let scene = window.windowScene
            LogStore.shared.log("[external-display] window bounds=\(window.bounds.size) scale=\(window.screen.scale) maxFPS=\(window.screen.maximumFramesPerSecond) hidden=\(window.isHidden ? 1 : 0) " +
                "alpha=\(window.alpha) scene=\(scene?.activationState.rawValue ?? -1) subviews=\(window.rootViewController?.view.subviews.count ?? -1) " +
                "screenMirrored=\(window.screen.mirrored != nil ? 1 : 0)")
        }
        MetalBackedView.refreshDisplayMode(reason: "external-connect")
    }

    fileprivate func disconnect() {
        window = nil
        LogStore.shared.log("[external-display] disconnected")
        winios_set_external_host(nil)
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
        let root = TVRootController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        // Between games the TV shows the controller home (TVCompanion.swift).
        if TVCompanionModel.enabled {
            let home = UIHostingController(rootView: TVHome())
            home.view.backgroundColor = .clear
            root.home = home
            root.addChild(home)
            root.view.addSubview(home.view)
            home.didMove(toParent: root)
            self.home = home
            let library = LibraryModel.shared
            idle = library.$current.combineLatest(library.$preparing).receive(on: DispatchQueue.main)
                .sink { [weak self] current, preparing in self?.placeHome(idle: current == nil && preparing == nil) }
        }
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.connect(window)
    }

    private var home: UIViewController?
    private var idle: AnyCancellable?

    /// The home screen above the game's views between games (Winios' compositor
    /// stays on the TV with a black backdrop), behind them while one runs.
    private func placeHome(idle: Bool) {
        (window?.rootViewController as? TVRootController)?.homeIdle = idle
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        idle = nil
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

/// The TV window's root: keeps the home screen laid out at a 1280-wide
/// (720p-like) size and scaled up to the screen. A TV reports 3840x2160 points
/// at 1x, so at its own size the phone-sized home screen was tiny; the size is
/// read at layout, since the view still had the phone's size when the scene connected.
final class TVRootController: UIViewController {
    weak var home: UIViewController?
    private var laidOut = CGSize.zero
    /// No game running: the home screen goes above everything.
    var homeIdle = true { didSet { (view as? TVRootView)?.order() } }

    override func loadView() {
        let v = TVRootView()
        v.controller = self
        view = v
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let full = view.bounds
        guard let homeView = home?.view, full.size != laidOut, full.width > 0 else { return }
        laidOut = full.size
        let scale = max(1, full.width / 1280)
        homeView.transform = .identity
        homeView.bounds = CGRect(x: 0, y: 0, width: full.width / scale, height: full.height / scale)
        homeView.center = CGPoint(x: full.midX, y: full.midY)
        homeView.transform = CGAffineTransform(scaleX: scale, y: scale)
        LogStore.shared.log("[external-display] home screen at \(Int(full.width / scale))x\(Int(full.height / scale)) pt, scaled \(String(format: "%.2f", scale))x")
    }
}

/// Keeps the TV's views in order whatever adds them when: the game view
/// (MetalHostView, black) at the back, Winios' compositor above it, the home
/// screen on top between games. The game view arriving after the compositor
/// covered the whole TV in black.
final class TVRootView: UIView {
    weak var controller: TVRootController?

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        order()
    }

    func order() {
        let homeView = controller?.home?.view
        let idle = controller?.homeIdle ?? true
        if let homeView, homeView.superview === self, !idle { sendSubviewToBack(homeView) }
        if MetalHostView.shared.superview === self { sendSubviewToBack(MetalHostView.shared) }
        if let homeView, homeView.superview === self, idle { bringSubviewToFront(homeView) }
    }
}
