import Foundation
import SwiftUI

@main
struct MadeiraApp: App {
    /// The external display's scene (ExternalDisplay.swift).
    @UIApplicationDelegateAdaptor(MadeiraAppDelegate.self) private var appDelegate
    init() {
        ImageCache.configure()   // MABD local: before any artwork loads
        // madeira-bcd: the Metal Performance HUD's performance insights (the
        // notes that stack up left of its panel: shader compiles, similar render
        // passes, blit encoders) cover the game. Off unless madeira.cfg says
        // env.MTL_HUD_INSIGHTS_ENABLED = 1, which is exported later and wins.
        setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0)
        // ml1172: read the screen on the main thread; library entries, whose
        // default Resolution comes from it, are also made on other threads.
        _ = ResolutionChoices.screen
        // The new library grid builds its first page before any view's onAppear, so the account's cached library and
        // playtime are read now: its cards carry their played lines from the first page.
        if LibraryGridArm.enabled, SteamOwnedLibrary.enabled { SteamOwnedLibrary.shared.start() }
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(InteractionFrameRateInstaller())   // touch frame-rate request (New library grid)
                .modifier(ClaimGamepadEvents())
                .onAppear {
                    GamepadInput.shared.start()
                    HardwareInput.shared.start()
                    JITNetworkShortcut.shared.restoreLeftover()   // also starts its network path monitor
                    ExternalDrive.shared.restore()   // games on an external drive (C:\External)
                    RemotePadServer.shared.restore() // Wi-Fi controllers (RemotePads.swift)
                    ExternalDisplay.shared.startDiagnostics()
                    SessionDoctor.shared.checkPreviousSession()
                    AppRelaunch.clear()
                }
                // madeira://jit-network/... (the Madeira JIT shortcut returning, JITNetwork.swift),
                // else madeira://play?exe=... (Home Screen shortcuts, SavesAndShortcuts.swift).
                .onOpenURL { url in if !JITNetworkShortcut.shared.handle(url) { ShortcutRouter.shared.handle(url) } }
        }
        // MABD local: tracks whether a close would be unexpected (AppRelaunch.wantedKey).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { AppRelaunch.scene(active: true) }
            else if phase == .background { AppRelaunch.scene(active: false) }
        }
    }
}
