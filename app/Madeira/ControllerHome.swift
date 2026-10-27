// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import GameController
import SwiftUI

// Two front ends over the same library: the touch library (LibraryView, cards,
// tabs, search) and a console-style home for playing with a controller
// (ControllerHome: the focused game's artwork full screen, a row of covers,
// button hints). Settings › Interface chooses; Automatic shows the controller
// home while a game controller is connected. Navigation comes from
// LibraryController's commands (player 1's pad), so it needs no focus engine.
// Log tag: [interface].

enum InterfaceMode: String, CaseIterable, Identifiable {
    case automatic, touch, controller
    var id: String { rawValue }
    static let key = "madeiraInterface"
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .touch: return "Touch"
        case .controller: return "Controller"
        }
    }
}

/// Which front end shows now: the setting, and whether a controller is connected.
final class InterfaceState: ObservableObject {
    static let shared = InterfaceState()
    @Published private(set) var controllerConnected = !GCController.controllers().isEmpty
    /// Menu in the controller home opens the touch library until a controller
    /// connects again or the setting changes.
    @Published var showTouchForNow = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let connected = !GCController.controllers().isEmpty
                if name == .GCControllerDidConnect { showTouchForNow = false }
                if connected != controllerConnected {
                    controllerConnected = connected
                    LogStore.shared.log("[interface] controller \(connected ? "connected" : "disconnected")")
                }
            })
        }
    }

    func usesControllerHome(_ mode: InterfaceMode) -> Bool {
        switch mode {
        case .touch: return false
        case .controller: return !showTouchForNow
        case .automatic: return controllerConnected && !showTouchForNow
        }
    }
}

/// The front end ContentView shows when no game is running.
struct MadeiraHome: View {
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    var startDock: (DockGame, Bool) -> Void
    @AppStorage(InterfaceMode.key) private var mode = InterfaceMode.automatic.rawValue
    @ObservedObject private var state = InterfaceState.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var theme = ThemeSettings.shared
    /// The startup animation, once per app run, over the controller home only.
    private static var startupPlayed = false
    @State private var booting = !MadeiraHome.startupPlayed

    var body: some View {
        let controllerHome = state.usesControllerHome(InterfaceMode(rawValue: mode) ?? .automatic)
        Group {
            if controllerHome {
                ControllerHome(play: play, enableJIT: enableJIT, openLibrary: { state.showTouchForNow = true })
                    .navigationBarHidden(true)
                    .transition(.opacity)
            } else {
                LibraryView(play: play, enableJIT: enableJIT, startDock: startDock)
                    .transition(.opacity)
            }
        }
        .overlay {
            if booting && controllerHome && theme.startup {
                StartupAnimation { booting = false; Self.startupPlayed = true }
                    .ignoresSafeArea().statusBarHidden(true)
            }
        }
        .onAppear {
            if !controllerHome || !theme.startup { booting = false; Self.startupPlayed = true }
        }
        .animation(.easeInOut(duration: 0.25), value: controllerHome)
        .modifier(SessionDoctorAlert())
        // Setup over either interface: on the touch library it closed itself as the
        // controller home replaced it at launch, and opened again every start.
        .fullScreenCover(isPresented: $onboarding.presented) { OnboardingView() }
        .onAppear { onboarding.presentIfNeeded() }
        .modifier(GameDeleteDialog())
        // ☰ in the touch library returns to the controller home when it applies.
        .onReceive(LibraryController.shared.commands) { command in
            if command == "menu", !controllerHome, state.showTouchForNow { state.showTouchForNow = false }
        }
        .onChange(of: mode) { _, _ in state.showTouchForNow = false }
    }
}

// MARK: - The controller home

/// The console-style front end: Games, Download and Settings, switched with
/// LB/RB and driven entirely by the controller (A select, B back, Y details,
/// D-pad or left stick to move). ☰ opens the touch library as a last resort.
struct ControllerHome: View {
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void = {}
    var openLibrary: () -> Void

    enum Section: Int, CaseIterable {
        case games, download, settings
        var title: String { ["Home", "Store", "Settings"][rawValue] }
    }

    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var steam = SteamGamesModel.shared
    @ObservedObject private var store = SteamOwnedLibrary.shared
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var theme = ThemeSettings.shared
    @AppStorage(SessionDoctor.thermalKey) private var thermalGuard = true
    /// MABD local: the Home / Store / Settings tabs across the top, switched with
    /// the shoulder buttons. Off by default: the Xbox button's guide moves
    /// between them instead.
    @AppStorage("madeiraShowTabs") private var showTabs = false
    /// The game page's Delete game, waiting for A (delete) or B (keep).
    @State private var confirmDelete: LibraryEntry?
    @ObservedObject private var pads = RemotePadServer.shared
    @ObservedObject private var display = ExternalDisplay.shared
    @AppStorage(InterfaceMode.key) private var interface = InterfaceMode.automatic.rawValue

    @State private var section = Section.games
    @State private var focused: UUID?
    @State private var downloadFocus = 0
    @State private var settingsFocus = 0
    /// Settings: the focused category, and whether focus is in its options.
    @State private var settingsCategory = 0
    @State private var inOptions = false
    /// Bumped after a setting changes, so values re-read madeira.cfg.
    @State private var settingsRevision = 0
    @ObservedObject private var jitState = LibraryJITState.shared
    @ObservedObject private var inputSettings = InputSettings.shared
    /// The game page (Y on a game): its entry and the focused row.
    @State private var page: LibraryEntry?
    @State private var pageFocus = 0
    /// The download page (Y on a game in Download) and its focused row.
    @State private var downloadPage: StoreItem?
    @State private var downloadPageFocus = 0
    /// The guide (View+Menu): open, and its focused row.
    @State private var guide = false
    @ObservedObject private var layoutEditor = LayoutEditor.shared
    /// The profile page (the avatar, or Profile in the guide).
    @State private var profilePage = false
    @ObservedObject private var profile = ProfileSettings.shared
    @State private var guideFocus = 0
    @State private var pendingLibrary: UUID?
    /// The full-screen picture viewer: its pictures and the shown one.
    @State private var viewerURLs: [URL] = []
    @State private var viewerIndex = 0
    /// On a store page: the focused screenshot (nil while focus is on the buttons).
    @State private var shotFocus: Int?
    /// Room for a download, read when Download shows (statfs for the drive).
    @State private var freeOnPhone: Int64?
    @ObservedObject private var compat = GameCompatibility.shared
    @ObservedObject private var importer = GameImporter.shared
    @ObservedObject private var drive = ExternalDrive.shared
    /// The side margin the content keeps (Dynamic Island + 20 pt); the cover rows
    /// scroll edge to edge and indent their first cover by it.
    @State private var side: CGFloat = 40
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Installed Steam games and the games you added, most recently played first.
    /// Built in reload(), not on every redraw: a Steam game without a saved entry
    /// gets a fresh entry (and a disk read for its size) each time it is made.
    @State private var games: [LibraryEntry] = []
    /// A stable id for each Steam game that has no saved entry yet, so focus holds.
    @State private var steamIDs: [Int: UUID] = [:]

    private func reload() {
        let local = model.entries.filter { $0.desktop != true && $0.steamAppID == nil }
        let steamGames = steam.games.filter(\.installed).map { game -> LibraryEntry in
            var entry = model.steamEntry(game, title: game.name)
            if !model.entries.contains(where: { $0.id == entry.id }) {
                let id = steamIDs[game.id] ?? entry.id
                steamIDs[game.id] = id
                entry.id = id
            }
            return entry
        }
        games = (steamGames + local).sorted {
            if $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        if focused == nil || !games.contains(where: { $0.id == focused }) { focused = games.first?.id }
    }

    private var current: LibraryEntry? { games.first { $0.id == focused } ?? games.first }

    /// Owned Steam games that are not installed (DLC and tools left out).
    private var downloadable: [SteamOwnedGame] {
        let installed = Set(steam.games.filter(\.installed).map(\.id))
        return store.owned.filter { !installed.contains($0.id) && $0.parentID == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Store: Steam games, then GOG games, that are not installed.
    private enum StoreItem: Hashable { case steam(Int), gog(Int), epic(String) }
    private var storeItems: [StoreItem] {
        downloadable.map { .steam($0.id) } + (gog.signedIn ? gog.notInstalled.map { .gog($0.id) } : [])
            + (epic.signedIn ? epic.notInstalled.map { .epic($0.appName) } : [])
    }
    private var focusedStore: StoreItem? {
        let items = filteredStore
        return items.isEmpty ? nil : items[min(downloadFocus, items.count - 1)]
    }

    /// The Store's sidebar, as the console store has one.
    private enum StoreFilter: Int, CaseIterable {
        case all, steam, gog, epic, ready, offline, downloading
        var title: String { ["All games", "Steam", "GOG", "Epic Games", "Ready to play", "Offline only", "Downloading"][rawValue] }
        var symbol: String { ["square.grid.2x2.fill", "cloud.fill", "shippingbox.fill", "bolt.shield.fill", "checkmark.circle.fill", "wifi.slash", "arrow.down.circle.fill"][rawValue] }
    }
    @State private var storeFilter = StoreFilter.all
    /// Focus is in the sidebar (else in the grid).
    @State private var storeInSidebar = false
    @State private var storeColumns = 3
    @ObservedObject private var storeCompat = StoreCompatibilityModel.shared

    private func verdict(_ item: StoreItem) -> GameCompatibility.Verdict? {
        switch item {
        case .steam(let id): return compat.reports[id]?.verdict
        case .gog(let id): return storeCompat.reports["gog:\(id)"]?.verdict
        case .epic(let app): return storeCompat.reports["epic:\(app)"]?.verdict
        }
    }
    private func isDownloading(_ item: StoreItem) -> Bool {
        switch item {
        case .steam(let id): return store.downloads[id] != nil
        case .gog(let id): return gog.downloads[id] != nil
        case .epic(let app): return epic.downloads[app] != nil
        }
    }
    private var filteredStore: [StoreItem] {
        storeItems.filter { item in
            switch storeFilter {
            case .all: return true
            case .steam: if case .steam = item { return true }; return false
            case .gog: if case .gog = item { return true }; return false
            case .epic: if case .epic = item { return true }; return false
            case .ready: return [.tested, .likely].contains(verdict(item))
            case .offline: return verdict(item) == .offlineOnly
            case .downloading: return isDownloading(item)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            // The page spans the full width (the reader ignores the horizontal safe
            // area) and keeps clear of the Dynamic Island on its side only: iOS
            // reports an inset on both sides in landscape, and adding both (on top
            // of the safe area) left wide empty margins.
            let (lead, trail) = IslandMargins.current()
            let side = max(lead, trail)
            let _ = DispatchQueue.main.async { if self.side != side { self.side = side } }
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    switch section {
                    case .games: gamesSection(height: geo.size.height)
                    case .download: downloadSection(height: geo.size.height)
                    case .settings: settingsSection
                    }
                    hints.padding(.vertical, 14)
                }
                .padding(.leading, lead).padding(.trailing, trail)
                .padding(.top, 10)
                if let entry = page {
                    gamePage(entry).transition(.opacity)
                }
                if let item = downloadPage {
                    downloadDetail(item).transition(.opacity)
                }
                if guide { guidePanel.zIndex(6) }
                if profilePage { ProfilePage { profilePage = false }.transition(.opacity).zIndex(7) }
                if layoutEditor.open { LayoutEditorView().transition(.opacity).zIndex(8) }
                if !viewerURLs.isEmpty {
                    FullScreenImages(urls: viewerURLs, index: $viewerIndex) { viewerURLs = [] }
                        .transition(.opacity).zIndex(5)
                }
                if let entry = confirmDelete {
                    deleteConfirmation(entry).transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        // The art fills the whole screen, edge to edge, sized by its own reader: a
        // scaled-to-fill image otherwise reports a larger size and widens the page,
        // and centring it inside the safe area left a black strip at the bottom.
        .background {
            GeometryReader { full in
                backdrop.frame(width: full.size.width, height: full.size.height).clipped()
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.2), value: section)
        .animation(.easeInOut(duration: 0.2), value: page?.id)
        .onReceive(clock) { now = $0 }
        .onReceive(LibraryController.shared.commands) { handle($0) }
        .onAppear {
            reload()
            steam.refresh()
            LogStore.shared.log("[interface] controller home games=\(games.count)")
        }
        .onReceive(model.$entries) { _ in DispatchQueue.main.async { reload() } }
        .onReceive(steam.$games) { _ in DispatchQueue.main.async { reload() } }
        .onChange(of: model.current) { _, current in if current != nil { page = nil } }
    }

    // MARK: Chrome

    private var backdrop: some View {
        ZStack {
            if theme.background != .gameArt || section == .settings
                || (section == .games && current == nil) || (section == .download && focusedStore == nil) {
                ThemeBackdrop()
            } else if section == .games, let game = current {
                LibraryArtwork(entry: game, backdrop: true).blur(radius: 2).id(game.id).transition(.opacity)
            } else if section == .download, let item = focusedStore {
                switch item {
                case .steam(let id):
                    AsyncImage(url: SteamCatalog.hero(id)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .blur(radius: 2).id(item).transition(.opacity)
                case .gog(let id):
                    AsyncImage(url: gog.owned.first { $0.id == id }?.image.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .blur(radius: 6).id(item).transition(.opacity)
                case .epic(let app):
                    AsyncImage(url: epic.owned.first { $0.appName == app }?.banner) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .blur(radius: 4).id(item).transition(.opacity)
                }
            }
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.55), .black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .leading, endPoint: .center)
        }
        .animation(.easeInOut(duration: 0.35), value: current?.id)
        .animation(.easeInOut(duration: 0.35), value: downloadFocus)
    }

    // The full bar in landscape; in portrait (or any narrow screen) a compact one
    // without the bumper glyphs and controller icon, so no label ever wraps.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarContent(compact: false)
            topBarContent(compact: true)
        }
        .foregroundStyle(.white)
    }

    private func topBarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 18) {
            // The profile, as consoles show it.
            ProfileAvatar(size: compact ? 30 : 38)
                .onTapGesture { profilePage = true }
            if !compact {
                Text(ProfileSettings.shared.displayName).font(.headline).lineLimit(1).fixedSize()
                    .onTapGesture { profilePage = true }
            }
            if showTabs && !compact {
                Image(systemName: "l1.rectangle.roundedbottom").font(.title3).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(showTabs ? Section.allCases : [], id: \.self) { item in
                Text(item.title)
                    .font((compact ? Font.subheadline : .title3).weight(item == section ? .heavy : .semibold))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(item == section ? theme.accent.onAccent : .white.opacity(0.7))
                    .padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 6 : 7)
                    .background(item == section ? theme.accent.color : Color.clear, in: Capsule())
                    .onTapGesture { section = item }
            }
            if showTabs && !compact {
                Image(systemName: "r1.rectangle.roundedbottom").font(.title3).foregroundStyle(.white.opacity(0.6))
            }
            if !showTabs && section != .games {
                Text(section.title).font(.title3.weight(.heavy)).lineLimit(1).fixedSize().padding(.leading, 6)
            }
            Spacer(minLength: compact ? 6 : 12)
            if !pads.players.isEmpty {
                Label("\(pads.players.count + 1)", systemImage: "person.2.fill").font(.headline).lineLimit(1).fixedSize()
            }
            BatteryIndicator(compact: compact)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font((compact ? Font.subheadline : .headline).monospacedDigit())
                .lineLimit(1).fixedSize()
        }
    }

    private var hints: some View {
        ViewThatFits(in: .horizontal) {
            hintsContent(compact: false)
            hintsContent(compact: true)
        }
    }

    private func hintsContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 16 : 26) {
            switch section {
            case .games where current != nil:
                ButtonHint(glyph: "a.circle.fill", label: "Play")
                ButtonHint(glyph: "y.circle.fill", label: compact ? "Options" : "Game options")
            case .download where focusedStore != nil:
                ButtonHint(glyph: "a.circle.fill", label: "Details")
                switch focusedStore! {
                case .steam(let id):
                    ButtonHint(glyph: "y.circle.fill", label: downloadAction(id).label)
                case .gog(let id):
                    ButtonHint(glyph: "y.circle.fill", label: gogAction(id).label)
                case .epic(let app):
                    ButtonHint(glyph: "y.circle.fill", label: epicAction(app).label)
                }
            case .settings:
                ButtonHint(glyph: "a.circle.fill", label: inOptions ? "Change" : "Open")
                if inOptions { ButtonHint(glyph: "b.circle.fill", label: compact ? "Back" : "Categories") }
            default:
                EmptyView()
            }
            if page != nil || downloadPage != nil { ButtonHint(glyph: "b.circle.fill", label: "Back") }
            Spacer(minLength: 8)
            ButtonHint(glyph: "line.3.horizontal.circle.fill", label: compact ? "Touch" : "Touch library")
                .onTapGesture { openLibrary() }
        }
    }

    // MARK: Games

    @ViewBuilder private func gamesSection(height: CGFloat) -> some View {
        Spacer(minLength: 8)
        if let game = current {
            VStack(alignment: .leading, spacing: 8) {
                Text(game.title).font(.system(size: 44, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    .foregroundStyle(.white).shadow(radius: 12)
                HStack(spacing: 10) {
                    Label(game.steamAppID != nil ? "Steam" : "PC game", systemImage: game.steamAppID != nil ? "cloud" : "desktopcomputer")
                    if let played = game.lastPlayed { Text("Played \(played.formatted(.relative(presentation: .named)))") }
                    if let bytes = game.folderBytes, bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                }
                .font(.headline).foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: 640, alignment: .leading)
            Spacer(minLength: 12)
            shelf(ids: games.map(\.id), focusedID: current?.id, height: min(height * 0.36, 250),
                  wideID: games.first?.lastPlayed != nil ? games.first.map { AnyHashable($0.id) } : nil) { id in
                if let game = games.first(where: { AnyHashable($0.id) == id }) {
                    if game.id == games.first?.id, game.lastPlayed != nil {
                        // "Jump back in": the last game played, wide, with its name.
                        LibraryArtwork(entry: game, backdrop: true)
                            .overlay(alignment: .bottomLeading) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("JUMP BACK IN").font(.caption.weight(.heavy)).foregroundStyle(theme.accent.color)
                                    Text(game.title).font(.headline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                            }
                    } else {
                        LibraryArtwork(entry: game)
                    }
                }
            } tapped: { id in
                guard let uuid = id.base as? UUID else { return }
                if uuid == current?.id, let game = current { play(game) } else { focused = uuid }
            }
        } else {
            message("No games installed yet", detail: "Press RB to go to Download and get one.", symbol: "gamecontroller")
            Spacer()
        }
    }

    // A row of covers; the focused one larger, outlined and centred.
    private func shelf<Art: View>(ids: [AnyHashable], focusedID: AnyHashable?, height: CGFloat,
                                  wideID: AnyHashable? = nil,
                                  @ViewBuilder art: @escaping (AnyHashable) -> Art,
                                  tapped: @escaping (AnyHashable) -> Void) -> some View {
        let width = height * 2 / 3
        return ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 22) {
                    ForEach(ids, id: \.self) { id in
                        let on = id == focusedID
                        art(id)
                            .frame(width: id == wideID ? height * 16 / 9 : width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.accent.color, lineWidth: on ? 4 : 0))
                            .shadow(color: .black.opacity(on ? 0.6 : 0.3), radius: on ? 18 : 6, y: 8)
                            .scaleEffect(on ? 1.08 : 0.94)
                            .opacity(on ? 1 : 0.75)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: on)
                            .id(id)
                            .onTapGesture { tapped(id) }
                    }
                }
                .padding(.horizontal, side).padding(.vertical, height * 0.08)
            }
            .padding(.horizontal, -side)
            .frame(height: height * 1.2)
            .onAppear { if let focusedID { reader.scrollTo(focusedID, anchor: .center) } }
            .onChange(of: focusedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { reader.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Game page

    private struct Row {
        let title: String
        let value: String?
        let action: (Int) -> Void   // +1 next / -1 previous / 0 select
    }

    private func pageRows(_ entry: LibraryEntry) -> [Row] {
        func update(_ change: (inout LibraryEntry) -> Void) {
            var e = entry; change(&e); model.save(e); page = e
        }
        let fx: [Double?] = [nil, 1.5, 2]
        let fxIndex = fx.firstIndex { $0 == entry.metalFXUpscale } ?? 0
        let fps = [3, 4, 1, 0]
        let fpsNames = [3: "30 FPS", 4: "40 FPS", 1: "60 FPS", 0: "Display maximum", 2: "Uncapped"]
        let fpsIndex = fps.firstIndex(of: entry.fpsMode) ?? 2
        let sizes = ResolutionChoices.groups().flatMap(\.choices)
        let sizeIndex = sizes.firstIndex { $0.value == entry.resolution } ?? 0
        return [
            Row(title: "Play", value: nil) { _ in page = nil; play(entry) },
            Row(title: "Graphics preset", value: GraphicsPreset.current(entry)?.label ?? "Custom") { d in
                update { GraphicsPreset.next(after: $0, d).apply(to: &$0) }
            },
            Row(title: "MetalFX upscaling", value: entry.metalFXUpscale.map { $0 == 2 ? "2×" : "1.5×" } ?? "Off") { d in
                update { $0.metalFXUpscale = fx[(fxIndex + (d < 0 ? fx.count - 1 : 1)) % fx.count] }
            },
            Row(title: "FPS limit", value: fpsNames[entry.fpsMode] ?? "60 FPS") { d in
                update { $0.fpsMode = fps[(fpsIndex + (d < 0 ? fps.count - 1 : 1)) % fps.count] }
            },
            Row(title: "Resolution", value: sizes.indices.contains(sizeIndex) ? sizes[sizeIndex].label : entry.resolution) { d in
                guard !sizes.isEmpty else { return }
                update { $0.resolution = sizes[(sizeIndex + (d < 0 ? sizes.count - 1 : 1)) % sizes.count].value }
            },
            Row(title: "Fast CPU mode", value: entry.fastCPU == true ? "On" : "Off") { _ in
                update { $0.fastCPU = $0.fastCPU == true ? nil : true }
            },
        ] + buttonRows(entry, update: update) + (UnrealFix.isUnreal(entry) ? [
            Row(title: "Unreal Engine: DirectX 11", value: UnrealFix.enabled(entry) ? "On" : "Off") { _ in
                update { UnrealFix.toggle(&$0) }
            },
        ] : []) + [
            Row(title: "Delete game", value: nil) { _ in confirmDelete = entry },
        ]
    }

    /// MABD local: the game's controller layout: the global one, or its own
    /// (starting from the global one), then one row per button while it is its own.
    private func buttonRows(_ entry: LibraryEntry, update: @escaping ((inout LibraryEntry) -> Void) -> Void) -> [Row] {
        [Row(title: "Controller layout", value: entry.buttonLayout == nil ? "Global" : "This game") { _ in
            LayoutEditor.shared.show(game: entry) { edited in
                update { $0.buttonLayout = edited.buttonLayout }
            }
        }]
    }

    private func gamePage(_ entry: LibraryEntry) -> some View {
        let rows = pageRows(entry)
        return DetailPanel(side: side, close: { page = nil },
                           hints: [("a.circle.fill", pageFocus == 0 ? "Play" : "Change"), ("b.circle.fill", "Back")]) {
            LibraryArtwork(entry: entry)
        } backdrop: {
            LibraryArtwork(entry: entry, backdrop: true)
        } content: {
                    Text(entry.title).font(.largeTitle.weight(.heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    ForEach(rows.indices, id: \.self) { i in
                        optionRow(rows[i].title, value: rows[i].value, focused: i == pageFocus, prominent: i == 0)
                            .onTapGesture { pageFocus = i; rows[i].action(i == 0 ? 0 : 1) }
                    }
                    Text("Left and right change a setting. B to go back.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func optionRow(_ title: String, value: String?, focused: Bool, prominent: Bool = false) -> some View {
        HStack {
            Text(title).font(.headline.weight(prominent ? .heavy : .semibold))
            Spacer()
            if let value {
                HStack(spacing: 8) {
                    if focused { Image(systemName: "chevron.left").font(.caption.weight(.bold)) }
                    Text(value).font(.headline)
                    if focused { Image(systemName: "chevron.right").font(.caption.weight(.bold)) }
                }
                .foregroundStyle(focused ? theme.accent.onAccent.opacity(0.8) : .white.opacity(0.7))
            }
        }
        .foregroundStyle(focused ? theme.accent.onAccent : .white)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(focused ? theme.accent.color : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: Download

    private func downloadAction(_ appID: Int) -> (label: String, state: String?) {
        guard store.signedIn else { return ("Sign in first", "Sign in to Steam in the touch library (☰), then come back.") }
        if let d = store.downloads[appID] {
            switch d.state {
            case .active: return ("Pause", "Downloading \(Int(d.progress.fraction * 100))%")
            case .queued: return ("Pause", "Waiting to download")
            case .paused: return ("Resume", "Paused at \(Int(d.progress.fraction * 100))%")
            case .failed(let why): return ("Try again", "Failed: \(why)")
            }
        }
        return ("Download", nil)
    }

    /// A GOG game's A action and its state line.
    private func gogAction(_ id: Int) -> (label: String, state: String?) {
        if let d = gog.downloads[id] {
            switch d.state {
            case .active: return ("Pause", d.total > 0 ? "Downloading \(Int(d.fraction * 100))%" : "Preparing…")
            case .queued: return ("Pause", "Waiting to download")
            case .paused: return ("Resume", "Paused at \(Int(d.fraction * 100))%")
            case .failed(let why): return ("Try again", "Failed: \(why)")
            }
        }
        return ("Download", nil)
    }

    private func epicAction(_ app: String) -> (label: String, state: String?) {
        if let d = epic.downloads[app] {
            switch d.state {
            case .active: return ("Pause", d.total > 0 ? "Downloading \(Int(d.fraction * 100))%" : "Preparing…")
            case .queued: return ("Pause", "Waiting to download")
            case .paused: return ("Resume", "Paused at \(Int(d.fraction * 100))%")
            case .failed(let why): return ("Try again", "Failed: \(why)")
            }
        }
        return ("Download", nil)
    }

    private func runStoreAction(_ item: StoreItem) {
        switch item {
        case .epic(let app):
            if let d = epic.downloads[app], d.state == .active || d.state == .queued { epic.pause(app) } else { epic.install(app) }
        case .steam(let id): runDownloadAction(id)
        case .gog(let id):
            if let d = gog.downloads[id], d.state == .active || d.state == .queued { gog.pause(id) } else { gog.install(id) }
        }
    }

    private func storeTileInfo(_ item: StoreItem) -> (title: String, source: String, image: URL?, fraction: Double?) {
        switch item {
        case .steam(let id):
            let g = downloadable.first { $0.id == id }
            return (g?.name ?? "", "STEAM", SteamCatalog.hero(id), store.downloads[id].map { $0.progress.fraction })
        case .gog(let id):
            let g = gog.owned.first { $0.id == id }
            return (g?.title ?? "", "GOG", g?.image.flatMap(URL.init(string:)), gog.downloads[id].map(\.fraction))
        case .epic(let app):
            let g = epic.owned.first { $0.appName == app }
            return (g?.title ?? "", "EPIC", g?.banner, epic.downloads[app].map(\.fraction))
        }
    }

    private func requestInfo(_ item: StoreItem) {
        // The page's About too, so it is usually ready before the page opens.
        switch item {
        case .steam(let id): compat.request(id); StoreDetailsModel.shared.requestSteam(id)
        case .gog(let id): storeCompat.requestGOG(id); gog.requestSize(id); StoreDetailsModel.shared.requestGOG(id)
        case .epic(let app):
            epic.requestSize(app)
            if let g = epic.owned.first(where: { $0.appName == app }) {
                SteamTitleMatch.shared.request(g.title)
                storeCompat.requestEpic(g)
                StoreDetailsModel.shared.requestEpic(g)
            }
        }
    }

    /// The Store: a sidebar of filters and a grid of wide tiles (landscape), or
    /// filter pills over the grid (portrait).
    @ViewBuilder private func downloadSection(height: CGFloat) -> some View {
        GeometryReader { geo in
            let portrait = geo.size.width < geo.size.height
            let sidebar: CGFloat = min(190, geo.size.width * 0.24)
            let gridWidth = portrait ? geo.size.width : geo.size.width - sidebar - 16
            let columns = max(2, min(4, Int(gridWidth / 210)))
            let _ = DispatchQueue.main.async { if storeColumns != columns { storeColumns = columns } }
            if portrait {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(StoreFilter.allCases, id: \.self) { filterPill($0) } }
                    }
                    storeGrid(columns: columns)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(StoreFilter.allCases, id: \.self) { filterRow($0) }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(width: sidebar)
                    storeGrid(columns: columns)
                }
            }
        }
        .padding(.top, 12)
    }

    private func filterRow(_ filter: StoreFilter) -> some View {
        let selected = filter == storeFilter
        let focused = selected && storeInSidebar
        return Label(filter.title, systemImage: filter.symbol)
            .font(.subheadline.weight(selected ? .bold : .medium))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(focused ? theme.accent.onAccent : .white.opacity(selected ? 1 : 0.7))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? theme.accent.color : (selected ? Color.white.opacity(0.14) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                if selected && !focused { Capsule().fill(theme.accent.color).frame(width: 4, height: 22).offset(x: -2) }
            }
            .contentShape(Rectangle())
            .onTapGesture { storeFilter = filter; downloadFocus = 0; storeInSidebar = false }
    }

    private func filterPill(_ filter: StoreFilter) -> some View {
        let selected = filter == storeFilter
        return Text(filter.title).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(selected ? theme.accent.onAccent : .white.opacity(0.8))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? theme.accent.color : Color.white.opacity(0.12), in: Capsule())
            .onTapGesture { storeFilter = filter; downloadFocus = 0 }
    }

    @ViewBuilder private func storeGrid(columns: Int) -> some View {
        let items = filteredStore
        if items.isEmpty {
            VStack {
                Spacer()
                message(storeFilter == .all ? (store.signedIn || gog.signedIn || epic.signedIn ? "Everything you own is installed" : "Sign in to a store")
                                            : "Nothing here",
                        detail: storeFilter == .all ? "Sign in to Steam, GOG or Epic in the touch library (☰ › Download games)."
                                                    : "Pick another filter on the left.",
                        symbol: "bag")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element) { index, item in
                            storeTile(item, focused: !storeInSidebar && index == min(downloadFocus, items.count - 1))
                                .id(item)
                                .onTapGesture {
                                    if index == downloadFocus && !storeInSidebar { downloadPageFocus = 0; downloadPage = item }
                                    else { downloadFocus = index; storeInSidebar = false }
                                }
                                .onAppear { requestInfo(item) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: downloadFocus) { _, i in
                    guard items.indices.contains(i) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { reader.scrollTo(items[i], anchor: .center) }
                }
            }
        }
    }

    private func storeTile(_ item: StoreItem, focused: Bool) -> some View {
        let info = storeTileInfo(item)
        let v = verdict(item)
        // A fixed 16:9 box; the art fills it and is cropped to it.
        return Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: info.image) { $0.resizable().scaledToFill() } placeholder: {
                    ZStack { Color.white.opacity(0.08); Image(systemName: "gamecontroller.fill").font(.title).foregroundStyle(.white.opacity(0.3)) }
                }
            }
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(info.source).font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                        if let v { Image(systemName: v.symbol).font(.caption.weight(.bold)).foregroundStyle(v.color) }
                    }
                    Text(info.title).font(.caption.weight(.bold)).lineLimit(2)
                    if let f = info.fraction { ProgressView(value: f).tint(theme.accent.color) }
                }
                .foregroundStyle(.white)
                .padding(8)
            }
            .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(focused ? theme.accent.color : .clear, lineWidth: 4))
        .scaleEffect(focused ? 1.04 : 1)
        .shadow(color: .black.opacity(focused ? 0.6 : 0.2), radius: focused ? 14 : 4, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)
    }

    private func storeTitle(_ name: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(theme.accent.color)
            Text(name).font(.system(size: 40, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                .foregroundStyle(.white).shadow(radius: 12)
        }
    }

    private func bytesText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// The compatibility estimate (anti-cheat, Steam's minimum requirements) and its first reason.
    private func compatibilityLine(_ appID: Int) -> some View {
        compatibilityContent(appID).task(id: appID) { compat.request(appID) }
    }

    @ViewBuilder private func compatibilityContent(_ appID: Int) -> some View {
        if let report = compat.reports[appID] {
            HStack(spacing: 8) {
                Image(systemName: report.verdict.symbol).foregroundStyle(report.verdict.color)
                Text(report.verdict.title).foregroundStyle(report.verdict.color)
                if let reason = report.reasons.first { Text(reason).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            }
            .font(.headline)
        } else {
            HStack(spacing: 8) { ProgressView().tint(.white); Text("Checking compatibility…").foregroundStyle(.white.opacity(0.7)) }
                .font(.headline)
        }
    }

    private var installsExternally: Bool { importer.toExternal && drive.configured }

    /// Where it installs, the room there, and a warning when it does not fit.
    @ViewBuilder private func spaceLine(_ game: SteamOwnedGame) -> some View {
        let room = installsExternally ? drive.freeBytes : freeOnPhone
        let need = game.diskBytes ?? game.downloadBytes64
        HStack(spacing: 8) {
            Image(systemName: installsExternally ? "externaldrive.fill" : "iphone")
            Text("Installs to \(installsExternally ? (drive.name ?? "the external drive") : "this iPhone")")
            if let room { Text("· \(bytesText(room)) free") }
            if let need, let room, need > room {
                Text("· not enough space").foregroundStyle(.red)
            }
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
        .onAppear {
            freeOnPhone = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
    }

    private func downloadRows(_ item: StoreItem) -> [Row] {
        let label: String
        switch item {
        case .steam(let id): label = downloadAction(id).label
        case .gog(let id): label = gogAction(id).label
        case .epic(let app): label = epicAction(app).label
        }
        var rows = [Row(title: label, value: nil) { _ in runStoreAction(item) }]

        if drive.configured {
            rows.append(Row(title: "Install to", value: importer.toExternal ? (drive.name ?? "External drive") : "This iPhone") { _ in
                importer.toExternal.toggle()
            })
        }
        return rows
    }

    /// Y on a game in the Store: its store page, as a console shows one.
    private func downloadDetail(_ item: StoreItem) -> some View {
        let rows = downloadRows(item)
        let info: (title: String, source: String, poster: URL?, hero: URL?, key: String, size: StoreSize?) = {
            switch item {
            case .steam(let id):
                let g = store.owned.first { $0.id == id }
                let size = g.flatMap { g in g.downloadBytes64.map { StoreSize(download: $0, disk: g.diskBytes ?? $0) } }
                return (g?.name ?? "Game", "Steam", SteamCatalog.cover(id), SteamCatalog.hero(id), "steam:\(id)", size)
            case .gog(let id):
                let g = gog.owned.first { $0.id == id }
                let image = g?.image.flatMap(URL.init(string:))
                return (g?.title ?? "Game", "GOG", image, image, "gog:\(id)", gog.sizes[id])
            case .epic(let app):
                let g = epic.owned.first { $0.appName == app }
                return (g?.title ?? "Game", "Epic Games", g?.poster, g?.banner, "epic:\(app)", epic.sizes[app])
            }
        }()
        let report: GameCompatibility.Report? = {
            switch item {
            case .steam(let id): return compat.reports[id]
            default: return StoreCompatibilityModel.shared.reports[info.key]
            }
        }()
        return DetailPanel(side: side, close: { downloadPage = nil; shotFocus = nil },
                           hints: [("a.circle.fill", shotFocus != nil ? "View" : (downloadPageFocus == 0 ? rows[0].title : "Change")),
                                   ("b.circle.fill", "Back")],
                           scrollTo: shotFocus != nil ? "store-shots" : nil) {
            PosterImage(poster: info.poster, fallback: info.hero)
                .contentShape(Rectangle())
                .onTapGesture { openViewer(info.key, hero: info.hero, at: 0) }
        } backdrop: {
            AsyncImage(url: info.hero) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        } content: {
            Text(info.source.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(theme.accent.color)
            Text(info.title).font(.largeTitle.weight(.heavy)).lineLimit(2).minimumScaleFactor(0.6)
            ForEach(rows.indices, id: \.self) { i in
                optionRow(rows[i].title, value: rows[i].value, focused: i == downloadPageFocus, prominent: i == 0)
                    .onTapGesture { downloadPageFocus = i; rows[i].action(1) }
            }
            switch item {
            case .steam(let id): if let download = store.downloads[id] { downloadProgress(download) }
            case .gog(let id):
                if let d = gog.downloads[id], d.total > 0 { ProgressView(value: d.fraction).tint(theme.accent.color) }
            case .epic(let app):
                if let d = epic.downloads[app], d.total > 0 { ProgressView(value: d.fraction).tint(theme.accent.color) }
            }
            // One size before downloading (the space it needs); while it downloads,
            // only the progress, whose total is what is really being fetched.
            let downloading: Bool = {
                switch item {
                case .steam(let id): return store.downloads[id] != nil
                case .gog(let id): return gog.downloads[id] != nil
                case .epic(let a): return epic.downloads[a] != nil
                }
            }()
            if let size = info.size, !downloading {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label("Needs \(bytesText(size.disk)) of space", systemImage: "internaldrive")
                        .font(.headline).foregroundStyle(.white.opacity(0.9))
                    Text("\(bytesText(size.download)) download").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                }
            }
            if let report {
                Label(report.verdict.title, systemImage: report.verdict.symbol)
                    .font(.title3.weight(.bold)).foregroundStyle(report.verdict.color)
                ForEach(report.reasons, id: \.self) {
                    Text("• " + $0).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if case .steam(let id) = item {
                compatibilityLine(id)
            }
            Text("ABOUT").font(.caption.weight(.heavy)).foregroundStyle(.white.opacity(0.6)).padding(.top, 6)
            StoreAboutSection(info: StoreDetailsModel.shared.info[info.key], onDark: true, open: { i in
                openViewer(info.key, hero: info.hero, at: i + (info.hero == nil ? 0 : 1))
            }, focused: shotFocus, accent: theme.accent.color)
                .task(id: info.key) {
                    switch item {
                    case .steam(let id): StoreDetailsModel.shared.requestSteam(id)
                    case .gog(let id): StoreDetailsModel.shared.requestGOG(id); gog.requestSize(id); StoreCompatibilityModel.shared.requestGOG(id)
                    case .epic(let app):
                        epic.requestSize(app)
                        if let g = epic.owned.first(where: { $0.appName == app }) {
                            StoreDetailsModel.shared.requestEpic(g); StoreCompatibilityModel.shared.requestEpic(g)
                        }
                    }
                }
        }
    }

    /// The download's state, a bar, and the bytes and speed while it runs.
    @ViewBuilder private func downloadProgress(_ download: SteamOwnedLibrary.Download) -> some View {
        let p = download.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch download.state {
                case .queued: Text("Waiting to download")
                case .active: Text(p.phase == .preparing ? "Preparing…" : p.phase == .finishing ? "Finishing…" : "Downloading \(Int(p.fraction * 100))%")
                case .paused: Text("Paused at \(Int(p.fraction * 100))%")
                case .failed(let reason): Text("Failed: \(reason)").lineLimit(2)
                }
                Spacer()
                if download.state == .active, p.bytesPerSecond > 0 {
                    Text("\(bytesText(Int64(p.bytesPerSecond)))/s").monospacedDigit()
                }
            }
            .font(.headline)
            ProgressView(value: p.fraction).tint(download.state == .active ? .green : .white.opacity(0.6))
            if p.totalBytes > 0 {
                HStack {
                    Text("\(bytesText(Int64(p.doneBytes))) of \(bytesText(Int64(p.totalBytes)))")
                    Spacer()
                    if download.state == .active, p.bytesPerSecond > 0, p.totalBytes > p.doneBytes {
                        let seconds = Double(p.totalBytes - p.doneBytes) / p.bytesPerSecond
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) + " left")
                    }
                }
                .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
    }

    /// Delete game's confirmation: A deletes, B keeps it.
    private func deleteConfirmation(_ entry: LibraryEntry) -> some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea().onTapGesture { confirmDelete = nil }
            VStack(spacing: 18) {
                Image(systemName: "trash.fill").font(.system(size: 44)).foregroundStyle(.red)
                Text("Delete \(entry.title)?").font(.title.weight(.heavy)).multilineTextAlignment(.center).lineLimit(2)
                Text(GameDeletion.shared.summary(entry)).font(.headline).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 30) {
                    ButtonHint(glyph: "a.circle.fill", label: "Delete").onTapGesture {
                        GameDeletion.shared.delete(entry); confirmDelete = nil; page = nil; focused = nil
                    }
                    ButtonHint(glyph: "b.circle.fill", label: "Keep").onTapGesture { confirmDelete = nil }
                }
                .padding(.top, 6)
            }
            .padding(32)
            .frame(maxWidth: 520)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(side)
        }
        .foregroundStyle(.white)
    }

    private func runDownloadAction(_ appID: Int) {
        guard store.signedIn else { return }
        if let d = store.downloads[appID], d.state == .active || d.state == .queued { store.pause(appID) }
        else { store.install(appID) }
    }

    // MARK: Settings

    /// One controller-editable setting: its value as shown, how it changes
    /// (+1 next, -1 previous) and what it does.
    private struct Setting {
        let title: String
        let value: String?
        var note = ""
        let change: (Int) -> Void
    }

    private struct SettingsCategory {
        let title: String
        let symbol: String
        let items: [Setting]
    }

    private func cycle<T: Equatable>(_ list: [T], _ value: T, _ d: Int) -> T {
        let i = list.firstIndex(of: value) ?? 0
        return list[(i + (d < 0 ? list.count - 1 : 1)) % list.count]
    }

    private func setConfig(_ key: String, _ value: String?) {
        MadeiraConfig.set(key, value)
        LogStore.shared.log("[controller-settings] \(key) = \(value ?? "(default)")")
        settingsRevision += 1
    }

    private func settingsCategories() -> [SettingsCategory] {
        _ = settingsRevision
        func mb(_ v: Int, zero: String) -> String { v == 0 ? zero : v >= 1024 ? RuntimeMemorySyncSettings.gb(v) : "\(v) MB" }
        let modes = InterfaceMode.allCases
        let mode = InterfaceMode(rawValue: interface) ?? .automatic
        let promote = MadeiraConfig.flag("MADEIRA_PROMOTE", fallback: false)
        let general = SettingsCategory(title: "General", symbol: "gearshape.fill", items: [
            Setting(title: "Interface", value: mode.label,
                    note: "Automatic shows this screen while a controller is connected; Touch always shows the touch library.") { d in
                interface = cycle(modes, mode, d).rawValue
            },
            Setting(title: "Wi-Fi controllers", value: pads.running ? "On" : "Off",
                    note: "Other phones on your Wi-Fi join as players 2–4 by scanning the code.") { _ in pads.setEnabled(!pads.running) },
            Setting(title: "Game on TV / external display", value: display.enabled ? "On" : "Off",
                    note: "With a TV connected, the game fills it and this phone keeps the controls.") { _ in display.enabled.toggle() },
            Setting(title: "Hold the display at its maximum rate", value: promote ? "On" : "Off",
                    note: "Keeps a 120 Hz panel at 120 Hz in the 60 FPS limit. Uses more power.") { _ in
                setConfig("env.MADEIRA_PROMOTE", promote ? nil : "1")
            },
            Setting(title: "Low-memory profile", value: LowMemoryDevice.active ? "On" : "Off",
                    note: "For devices with 4 GB of RAM: 512 MB JIT pool, 1 GB video memory, a 2 GB swap file and 30 FPS for new games. On by itself on such devices. Applies to the next game.") { _ in
                LowMemoryDevice.set(!LowMemoryDevice.active); settingsRevision += 1
            },
            Setting(title: "Tabs across the top", value: showTabs ? "On" : "Off",
                    note: "Home, Store and Settings tabs, switched with LB and RB. Off: press the Xbox button (or View + Menu) for the guide.") { _ in
                showTabs.toggle()
            },
            Setting(title: "Keep my music playing", value: MusicNow.mix ? "On" : "Off",
                    note: "Game sound plays alongside your music instead of stopping it. The guide (Xbox button) has play, pause and skip for Apple Music.") { _ in
                MusicNow.mix.toggle(); settingsRevision += 1
            },
            Setting(title: "Heat guard", value: thermalGuard ? "On" : "Off",
                    note: "When the phone gets hot, games run at 30 FPS until it cools down, instead of stuttering.") { _ in
                thermalGuard.toggle()
            },
            Setting(title: "Extended logging", value: inputSettings.diagnostics ? "On" : "Off",
                    note: "More detail in the logs for fixing problems. Slower.") { _ in inputSettings.diagnostics.toggle() },
        ])
        let pool = RuntimeMemorySyncSettings.intKey("pool"), vram = RuntimeMemorySyncSettings.intKey("vram-mb")
        let swap = RuntimeMemorySyncSettings.intKey("swap-mb"), coverage = RuntimeMemorySyncSettings.currentCoverage()
        let coverages = RuntimeMemorySyncSettings.coverageChoices
        let engine = SyncEngine.current, eco = MadeiraConfig.bool("eco", default: false)
        let memory = SettingsCategory(title: "Memory & speed", symbol: "memorychip.fill", items: [
            Setting(title: "JIT pool", value: mb(pool, zero: "Standard (896 MB)"),
                    note: "Memory reserved for translated game code. Applies after restarting EmuPC.") { d in
                let v = cycle(RuntimeMemorySyncSettings.poolChoices, pool, d); setConfig("pool", v > 0 ? String(v) : nil)
            },
            Setting(title: "Video memory", value: mb(vram, zero: "Automatic"),
                    note: "How much graphics memory games are told they have. Applies after a restart.") { d in
                let v = cycle(RuntimeMemorySyncSettings.vramChoices, vram, d); setConfig("vram-mb", v > 0 ? String(v) : nil)
            },
            Setting(title: "Swap tier", value: mb(swap, zero: "Off"),
                    note: "Moves game data to storage when memory runs short, so big games crash less. Applies after a restart.") { d in
                let v = cycle(RuntimeMemorySyncSettings.swapChoices, swap, d); setConfig("swap-mb", v > 0 ? String(v) : nil)
            },
            Setting(title: "Swap coverage", value: coverages.first { $0.0 == coverage }?.1 ?? "Large allocations",
                    note: "What the swap tier moves. Broad saves the most memory but can break some games (Gang Beasts).") { d in
                let v = cycle(coverages.map(\.0), coverage, d)
                setConfig("env.MADEIRA_SWAP_COVERAGE", v.isEmpty ? (RuntimeMemorySyncSettings.swapModeBroad ? "classic" : nil) : v)
            },
            Setting(title: "Sync engine", value: engine.label, note: "How games' threads wait on each other. Fastsync is the default.") { d in
                SyncEngine.apply(cycle(SyncEngine.allCases, engine, d)); settingsRevision += 1
            },
            Setting(title: "Eco mode", value: eco ? "On" : "Off", note: "Games start at a low priority: less power, slower.") { _ in
                setConfig("eco", eco ? nil : "1")
            },
        ])
        let jit = SettingsCategory(title: "JIT", symbol: "bolt.fill", items: [
            Setting(title: "JIT", value: jitState.enabled ? "Enabled" : "Not enabled",
                    note: "Games need JIT. Press A to enable it with your StikDebug or built-in pairing (LocalDevVPN on).") { _ in
                if !jitState.enabled { enableJIT() }
            },
        ])
        // Every titled option from Settings › All settings, by its category.
        let values = MadeiraConfig.all()
        let catalog = ConfigCatalog.categories.compactMap { category -> SettingsCategory? in
            let items = ConfigCatalog.generated.filter { $0.category == category && !$0.title.isEmpty && $0.kind != .text }
                .map { option -> Setting in
                    let current = values[option.key] ?? option.defaultValue
                    switch option.kind {
                    case .bool:
                        let on = !["0", "", "false", "off", "no"].contains(current.lowercased())
                        return Setting(title: option.displayTitle, value: on ? "On" : "Off", note: option.note) { _ in
                            setConfig(option.key, on ? "0" : "1")
                        }
                    case .choice:
                        let label = option.choices.first { $0.value == (values[option.key] ?? "") }?.label ?? current
                        return Setting(title: option.displayTitle, value: label.isEmpty ? "Default" : label, note: option.note) { d in
                            guard !option.choices.isEmpty else { return }
                            let next = cycle(option.choices.map(\.value), values[option.key] ?? "", d)
                            setConfig(option.key, next.isEmpty ? nil : next)
                        }
                    default:
                        let n = Int(current) ?? 0
                        let step = abs(n) >= 1024 ? 256 : abs(n) >= 64 ? 16 : 1
                        return Setting(title: option.displayTitle, value: values[option.key] == nil ? "Default (\(current))" : current,
                                       note: option.note) { d in
                            setConfig(option.key, String(max(0, n + (d < 0 ? -step : step))))
                        }
                    }
                }
            return items.isEmpty ? nil : SettingsCategory(title: category, symbol: "slider.horizontal.3", items: items)
        }
        let more = SettingsCategory(title: "More", symbol: "ellipsis.circle.fill", items: [
            Setting(title: "Steam sign-in and everything else", value: nil,
                    note: "Opens the touch library's Settings, for things that need typing.") { _ in openLibrary() },
        ])
        let themeCategory = SettingsCategory(title: "Theme", symbol: "paintpalette.fill", items: [
            Setting(title: "Accent colour", value: theme.accent.label,
                    note: "The colour of focus and selection.") { d in theme.cycleAccent(d) },
            Setting(title: "Background", value: theme.background.label,
                    note: "Behind the home: the focused game's art, a moving aurora, a glow in your accent colour, or plain dark.") { d in theme.cycleBackground(d) },
            Setting(title: "Startup animation", value: theme.startup ? "On" : "Off",
                    note: "Plays when EmuPC opens with a controller.") { _ in theme.startup.toggle() },
        ])
        // MABD local: the global controller layout (GameTuning.swift ButtonLayout).
        let layout = ButtonLayout.global
        let controls = SettingsCategory(title: "Controls", symbol: "gamecontroller.fill", items: [
            Setting(title: "Edit button layout", value: layout.isEmpty ? "Default" : "\(layout.count) changed",
                    note: "The controller with every button around it: pick one and choose what it does in games. A game can have its own layout from its page.") { _ in
                LayoutEditor.shared.show()
            },
            Setting(title: "Reset to default", value: nil,
                    note: "Every button does what it says again.") { _ in ButtonLayout.global = [:]; settingsRevision += 1 },
        ])
        return [general, controls, themeCategory, memory, jit] + catalog + [more]
    }

    private var settingsSection: some View {
        let categories = settingsCategories()
        let category = categories[min(settingsCategory, categories.count - 1)]
        let items = category.items
        let focus = min(settingsFocus, max(items.count - 1, 0))
        return HStack(alignment: .top, spacing: 24) {
            // Categories.
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(categories.indices, id: \.self) { i in
                            let on = i == settingsCategory
                            Label(categories[i].title, systemImage: categories[i].symbol)
                                .font(.headline)
                                .foregroundStyle(on && !inOptions ? .black : .white.opacity(on ? 1 : 0.7))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(on ? (inOptions ? Color.white.opacity(0.15) : .white) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .id(i)
                                .onTapGesture { settingsCategory = i; settingsFocus = 0; inOptions = true }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: settingsCategory) { _, i in withAnimation { reader.scrollTo(i, anchor: .center) } }
            }
            .frame(width: 250)
            // The category's settings, and the focused one's explanation.
            VStack(alignment: .leading, spacing: 10) {
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items.indices, id: \.self) { i in
                                optionRow(items[i].title, value: items[i].value, focused: inOptions && i == focus)
                                    .id(i)
                                    .onTapGesture { inOptions = true; settingsFocus = i; items[i].change(1) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: settingsFocus) { _, i in withAnimation { reader.scrollTo(i, anchor: .center) } }
                }
                if inOptions, items.indices.contains(focus), !items[focus].note.isEmpty {
                    Text(items[focus].note).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true).lineLimit(4)
                }
                // The Wi-Fi controllers' join code next to its setting.
                if category.title == "General", inOptions, focus == 1, pads.running,
                   let url = pads.joinURL, let qr = RemotePadServer.qrImage(url.absoluteString) {
                    HStack(spacing: 14) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 110, height: 110)
                            .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scan with a phone's Camera to join").font(.headline)
                            ForEach(pads.players) { Text("Player \($0.slot + 1): \($0.name)").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Shared

    private func message(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 52))
            Text(title).font(.title2.weight(.bold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white).frame(maxWidth: .infinity)
    }

    private func openViewer(_ key: String, hero: URL?, at index: Int) {
        let urls = [hero].compactMap { $0 } + (StoreDetailsModel.shared.info[key]?.fullScreenshots ?? [])
        guard !urls.isEmpty else { return }
        viewerIndex = min(max(index, 0), urls.count - 1)
        viewerURLs = urls
    }

    private struct GuideItem { let title: String; let symbol: String; var music = false; let action: () -> Void }
    private var guideItems: [GuideItem] {
        [GuideItem(title: "Profile", symbol: "person.crop.circle.fill") { profilePage = true },
         GuideItem(title: "Home", symbol: "house.fill") { section = .games; page = nil; downloadPage = nil },
         GuideItem(title: "Store", symbol: "bag.fill") { section = .download; page = nil; downloadPage = nil },
         GuideItem(title: "Settings", symbol: "gearshape.fill") { section = .settings; page = nil; downloadPage = nil },
         GuideItem(title: "Music", symbol: "music.note", music: true) { MusicNow.shared.toggle() },
         GuideItem(title: "Touch library", symbol: "hand.tap.fill") { openLibrary() },
         GuideItem(title: pads.running ? "Wi-Fi controllers: on" : "Wi-Fi controllers: off", symbol: "iphone.radiowaves.left.and.right") { pads.setEnabled(!pads.running) },
         GuideItem(title: "Restart EmuPC", symbol: "arrow.clockwise") { AppRelaunch.closeAndOffer("guide") },
         GuideItem(title: "Close EmuPC", symbol: "power") { AppRelaunch.close() }]
    }

    /// The guide, sliding in from the left like a console's.
    private var guidePanel: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { guide = false }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ProfileAvatar(size: 44)
                    VStack(alignment: .leading) {
                        Text(ProfileSettings.shared.displayName).font(.headline)
                        HStack(spacing: 10) {
                            Text(now.formatted(date: .omitted, time: .shortened))
                            BatteryIndicator(compact: true)
                        }
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.bottom, 8)
                // The rows scroll (and follow the focus) so the panel fits the
                // landscape height instead of spilling past the top and bottom.
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(guideItems.indices, id: \.self) { i in
                                let item = guideItems[i]
                                Group {
                                    if item.music { MusicGuideRow(focused: i == guideFocus) }
                                    else { Label(item.title, systemImage: item.symbol).font(.headline) }
                                }
                                    .foregroundStyle(i == guideFocus ? theme.accent.onAccent : .white)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(i == guideFocus ? theme.accent.color : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .contentShape(Rectangle())
                                    .onTapGesture { guideFocus = i; if !item.music { guide = false }; item.action() }
                                    .id(i)
                            }
                        }
                    }
                    .onChange(of: guideFocus) { _, i in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) } }
                }
                HStack(spacing: 18) {
                    ButtonHint(glyph: "a.circle.fill", label: "Select")
                    ButtonHint(glyph: "b.circle.fill", label: "Close")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 14)
            .padding(.leading, IslandMargins.current().leading)
            .frame(width: 320 + IslandMargins.current().leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                ZStack { Color.black.opacity(0.6); Rectangle().fill(.ultraThinMaterial.opacity(0.95)) }.ignoresSafeArea()
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func handle(_ command: String) {
        // The photo picker is up: the pad would act on the page behind it.
        if PhotoPick.showing { return }
        // The layout editor has the pad while it is open (B closes it).
        if layoutEditor.open { layoutEditor.command(command); return }
        if command == "guide" {
            pendingLibrary = nil
            withAnimation(.easeOut(duration: 0.2)) { guide.toggle() }
            guideFocus = 0
            return
        }
        if profilePage {
            // Typing the name: the keyboard has the input.
            if ProfilePageModel.shared.editingName { if command == "back" { ProfilePageModel.shared.editingName = false }; return }
            ProfilePageModel.shared.command(command, profile: profile) { profilePage = false }
            return
        }
        if guide {
            let items = guideItems
            switch command {
            case "up": guideFocus = max(guideFocus - 1, 0)
            case "down": guideFocus = min(guideFocus + 1, items.count - 1)
            case "left", "right": if items[guideFocus].music { MusicNow.shared.skip(command == "left" ? -1 : 1) }
            // Music plays or pauses and the guide stays open.
            case "accept" where items[guideFocus].music: items[guideFocus].action()
            case "accept": withAnimation { guide = false }; items[guideFocus].action()
            case "back", "menu": withAnimation { guide = false }
            default: break
            }
            return
        }
        if !viewerURLs.isEmpty {
            switch command {
            case "left": viewerIndex = max(viewerIndex - 1, 0)
            case "right": viewerIndex = min(viewerIndex + 1, viewerURLs.count - 1)
            case "back", "accept", "add": viewerURLs = []
            default: break
            }
            return
        }
        if let entry = confirmDelete {
            switch command {
            case "accept":
                GameDeletion.shared.delete(entry)
                confirmDelete = nil; page = nil; focused = nil
            case "back", "add": confirmDelete = nil
            default: break
            }
            return
        }
        if let item = downloadPage {
            let rows = downloadRows(item)
            let key: String = { switch item { case .steam(let id): return "steam:\(id)"; case .gog(let id): return "gog:\(id)"; case .epic(let a): return "epic:\(a)" } }()
            let shots = StoreDetailsModel.shared.info[key]?.screenshots.count ?? 0
            // The screenshot row: left/right between pictures, A opens one, up returns.
            if let i = shotFocus {
                switch command {
                case "left": shotFocus = max(i - 1, 0)
                case "right": shotFocus = min(i + 1, max(shots - 1, 0))
                case "up": shotFocus = nil
                case "accept":
                    let hero: URL? = { switch item {
                        case .steam(let id): return SteamCatalog.hero(id)
                        case .gog(let id): return gog.owned.first { $0.id == id }?.image.flatMap(URL.init(string:))
                        case .epic(let a): return epic.owned.first { $0.appName == a }?.banner } }()
                    openViewer(key, hero: hero, at: i + (hero == nil ? 0 : 1))
                case "back": shotFocus = nil; downloadPage = nil
                default: break
                }
                return
            }
            if command == "down", downloadPageFocus == rows.count - 1, shots > 0 { shotFocus = 0; return }
            switch command {
            case "up": downloadPageFocus = max(downloadPageFocus - 1, 0)
            case "down": downloadPageFocus = min(downloadPageFocus + 1, rows.count - 1)
            case "left", "right": if downloadPageFocus > 0 { rows[downloadPageFocus].action(1) }
            case "accept": rows[downloadPageFocus].action(1)
            case "back", "add": downloadPage = nil
            default: break
            }
            return
        }
        if let entry = page {
            let rows = pageRows(entry)
            switch command {
            case "up": pageFocus = max(pageFocus - 1, 0)
            case "down": pageFocus = min(pageFocus + 1, rows.count - 1)
            case "left": if pageFocus > 0 { rows[pageFocus].action(-1) }
            case "right": if pageFocus > 0 { rows[pageFocus].action(1) }
            case "accept": rows[pageFocus].action(pageFocus == 0 ? 0 : 1)
            case "back", "add": page = nil
            default: break
            }
            return
        }
        switch command {
        case "tab" where showTabs: section = Section(rawValue: (section.rawValue + 1) % 3) ?? .games
        case "tabBack" where showTabs: section = Section(rawValue: (section.rawValue + 2) % 3) ?? .games
        // Menu alone opens the touch library, a moment later, so pressing View
        // with it opens the guide instead.
        case "menu":
            let token = UUID(); pendingLibrary = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if pendingLibrary == token { pendingLibrary = nil; openLibrary() } }
        default: break
        }
        switch section {
        case .games:
            switch command {
            case "left", "right":
                guard !games.isEmpty else { return }
                let i = games.firstIndex { $0.id == current?.id } ?? 0
                focused = games[command == "left" ? max(i - 1, 0) : min(i + 1, games.count - 1)].id
            case "accept": if let game = current { play(game) }
            case "add": if let game = current { pageFocus = 0; page = game }
            default: break
            }
        case .download:
            let list = filteredStore
            let cols = max(storeColumns, 1)
            let i = min(downloadFocus, max(list.count - 1, 0))
            if storeInSidebar {
                let filters = StoreFilter.allCases
                switch command {
                case "up": storeFilter = filters[max(storeFilter.rawValue - 1, 0)]; downloadFocus = 0
                case "down": storeFilter = filters[min(storeFilter.rawValue + 1, filters.count - 1)]; downloadFocus = 0
                case "right", "accept": if !list.isEmpty { storeInSidebar = false }
                default: break
                }
            } else {
                switch command {
                case "left": if i % cols == 0 { storeInSidebar = true } else { downloadFocus = i - 1 }
                case "right": downloadFocus = min(i + 1, max(list.count - 1, 0))
                case "up": if i - cols >= 0 { downloadFocus = i - cols }
                case "down": if i + cols < list.count { downloadFocus = i + cols } else if i / cols < (list.count - 1) / cols { downloadFocus = list.count - 1 }
                // A opens the game's page (A there downloads); Y downloads from the grid.
                case "accept": if let item = focusedStore { downloadPageFocus = 0; downloadPage = item }
                case "add": if let item = focusedStore { runStoreAction(item) }
                default: break
                }
            }
        case .settings:
            let categories = settingsCategories()
            let items = categories[min(settingsCategory, categories.count - 1)].items
            if inOptions {
                let i = min(settingsFocus, max(items.count - 1, 0))
                switch command {
                case "up": settingsFocus = max(i - 1, 0)
                case "down": settingsFocus = min(i + 1, max(items.count - 1, 0))
                case "left": if items.indices.contains(i) { items[i].change(-1) }
                case "right", "accept": if items.indices.contains(i) { items[i].change(1) }
                case "back": inOptions = false
                default: break
                }
            } else {
                switch command {
                case "up": settingsCategory = max(settingsCategory - 1, 0); settingsFocus = 0
                case "down": settingsCategory = min(settingsCategory + 1, categories.count - 1); settingsFocus = 0
                case "right", "accept": inOptions = true
                default: break
                }
            }
        }
    }
}

/// A full-screen page over the controller home: the cover on the left, the
/// details and their options on the right, kept inside the screen and scrolling
/// when they are taller than it.
struct DetailPanel<Art: View, Backdrop: View, Content: View>: View {
    var side: CGFloat
    var close: () -> Void
    var hints: [(String, String)] = []
    /// An id in the content to scroll to (the focused part, for the controller).
    var scrollTo: String? = nil
    @ViewBuilder var art: Art
    @ViewBuilder var backdrop: Backdrop
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let portrait = geo.size.width < geo.size.height
            VStack(spacing: 0) {
                Group {
                    if portrait {
                        // Portrait: the cover on top, the options below it.
                        VStack(alignment: .leading, spacing: 18) {
                            art
                                .frame(width: geo.size.height * 0.16, height: geo.size.height * 0.24)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: .black.opacity(0.6), radius: 18, y: 8)
                                .frame(maxWidth: .infinity)
                            ScrollViewReader { reader in
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 10) { content }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .scrollBounceBehavior(.basedOnSize)
                                .onChange(of: scrollTo) { _, id in withAnimation { reader.scrollTo(id ?? "top", anchor: .center) } }
                            }
                        }
                        .padding(.top, 12)
                    } else {
                        HStack(alignment: .center, spacing: 32) {
                            art
                                .frame(width: geo.size.height * 0.42, height: geo.size.height * 0.63)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
                            // Centred when it fits, scrolling when it is taller than the screen.
                            ScrollViewReader { reader in
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 10) { Color.clear.frame(height: 0).id("top"); content }
                                        .padding(.vertical, 16)
                                        .frame(maxWidth: .infinity, minHeight: geo.size.height * 0.78, alignment: .leading)
                                }
                                .scrollBounceBehavior(.basedOnSize)
                                .onChange(of: scrollTo) { _, id in withAnimation { reader.scrollTo(id ?? "top", anchor: id == nil ? .top : .center) } }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 26) {
                    ForEach(hints.indices, id: \.self) { ButtonHint(glyph: hints[$0].0, label: hints[$0].1) }
                    Spacer()
                }
                .padding(.vertical, 14)
            }
            // Clear of the Dynamic Island on its side only, like the home.
            .padding(.leading, IslandMargins.current().leading)
            .padding(.trailing, IslandMargins.current().trailing)
            .frame(width: geo.size.width, height: geo.size.height)
            .foregroundStyle(.white)
            .background {
                GeometryReader { full in
                    ZStack {
                        Color.black
                        backdrop.frame(width: full.size.width, height: full.size.height).clipped().blur(radius: 24).opacity(0.55)
                        LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                    }
                    .onTapGesture { close() }
                }
                .ignoresSafeArea()
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }
}

/// One controller button and what it does, as consoles show them.
/// MABD local: the device's battery, and the controller's when it reports one,
/// console style (top bar and guides). Red at 20% and below; a bolt while charging.
struct BatteryIndicator: View {
    var compact = false
    @State private var level: Float = -1
    @State private var state: UIDevice.BatteryState = .unknown
    @State private var pad: Float?

    var body: some View {
        HStack(spacing: compact ? 8 : 14) {
            if let pad {
                HStack(spacing: 4) {
                    Image(systemName: "gamecontroller.fill")
                    if !compact { Text("\(Int(pad * 100))%").monospacedDigit() }
                }
                .foregroundStyle(pad <= 0.2 ? Color.red : .secondary)
            } else if !compact {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
            }
            if level >= 0 {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    Text("\(Int((level * 100).rounded()))%").monospacedDigit()
                }
                .foregroundStyle(level <= 0.2 && state != .charging ? Color.red : .primary)
            }
        }
        .font((compact ? Font.subheadline : .headline))
        .lineLimit(1).fixedSize()
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true; read() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in read() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in read() }
        // Controllers report no change notification: look again every half minute.
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in read() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in read() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in read() }
    }

    private var symbol: String {
        if state == .charging || state == .full { return "battery.100percent.bolt" }
        switch level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func read() {
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState
        let controller = GCController.current ?? GCController.controllers().first
        pad = controller?.battery.map { $0.batteryLevel }.flatMap { $0 > 0 ? $0 : nil }
    }
}

struct ButtonHint: View {
    let glyph: String
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph).font(.title2)
            Text(label).font(.headline).lineLimit(1).fixedSize()
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Interface.
struct InterfaceSettingsSection: View {
    @AppStorage(InterfaceMode.key) private var mode = InterfaceMode.automatic.rawValue

    var body: some View {
        Section {
            Picker("Interface", selection: $mode) {
                ForEach(InterfaceMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        } header: { Text("Interface") } footer: {
            Text("Touch: the library with cards, tabs and search. Controller: a full-screen home made for playing with a controller — move with the D-pad, A to play, Y for details, ☰ for the library and Settings. Automatic shows the controller home whenever a controller is connected.")
        }
    }
}

/// MABD local: horizontal margins that keep clear of the Dynamic Island on its
/// side only. Read from the window: a view that ignores the safe area reports
/// no insets of its own. iOS reports the same inset on both sides in landscape;
/// the island is at the top of the phone, on the left with the interface in
/// landscapeRight (home edge on the right) and on the right in landscapeLeft.
enum IslandMargins {
    static func current() -> (leading: CGFloat, trailing: CGFloat) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        let insets = scene?.windows.first { $0.isKeyWindow }?.safeAreaInsets ?? scene?.windows.first?.safeAreaInsets ?? .zero
        switch scene?.interfaceOrientation {
        case .landscapeRight?: return (max(insets.left, 16) + 4, 30)
        case .landscapeLeft?: return (30, max(insets.right, 16) + 4)
        default: return (max(insets.left, 16), max(insets.right, 16))
        }
    }
}
