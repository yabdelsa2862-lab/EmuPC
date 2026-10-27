// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import SwiftUI

// MABD local: one-tap tuning for a game.
//
// Graphics presets set the game's resolution and MetalFX upscaling together:
// Performance renders at 480 lines and lets MetalFX scale it 1.5× (about 720
// on screen), Balanced renders at the screen's light size with MetalFX 1.5×,
// Quality renders at the default size without upscaling. A game whose own
// choices match none of them shows Custom.
//
// Unreal Engine games are found by their layout (an Engine folder beside the
// game, or a *-Win64-Shipping.exe). Madeira's Direct3D 12 is experimental, and
// UE games that hang on it (MECCHA CHAMELEON) run on Direct3D 11 with -dx11.

enum GraphicsPreset: String, CaseIterable, Identifiable {
    case performance, balanced, quality
    var id: String { rawValue }

    var label: String {
        switch self {
        case .performance: return "Performance"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        }
    }

    var note: String {
        switch self {
        case .performance: return "Renders small and upscales with MetalFX. Highest frame rate, softest picture."
        case .balanced: return "A lighter resolution, upscaled with MetalFX."
        case .quality: return "The default resolution, no upscaling. Sharpest, slowest."
        }
    }

    private var target: (resolution: String, metalFX: Double?)? {
        let groups = ResolutionChoices.groups()
        switch self {
        case .performance:
            if let small = ResolutionChoices.metalFX(in: groups) { return (small.value, 1.5) }
            guard let light = groups.first?.choices.first else { return nil }
            return (light.value, 2)
        case .balanced:
            guard let light = groups.first?.choices.first else { return nil }
            return (light.value, 1.5)
        case .quality:
            return (ResolutionChoices.defaultValue, nil)
        }
    }

    func apply(to entry: inout LibraryEntry) {
        guard let target else { return }
        entry.resolution = target.resolution
        entry.metalFXUpscale = target.metalFX
    }

    /// The preset this game's choices match, nil for Custom.
    static func current(_ entry: LibraryEntry) -> GraphicsPreset? {
        allCases.first { preset in
            guard let t = preset.target else { return false }
            return t.resolution == entry.resolution && t.metalFX == entry.metalFXUpscale
        }
    }

    /// Cycles Performance → Balanced → Quality (and back with -1).
    static func next(after entry: LibraryEntry, _ direction: Int) -> GraphicsPreset {
        let all = allCases
        guard let now = current(entry), let i = all.firstIndex(of: now) else { return direction < 0 ? .quality : .performance }
        return all[(i + (direction < 0 ? all.count - 1 : 1)) % all.count]
    }
}

enum UnrealFix {
    static let flag = "-dx11"

    /// Whether this game is an Unreal Engine game, read from its folder.
    static func isUnreal(_ entry: LibraryEntry) -> Bool {
        if let cached = cache[entry.id] { return cached }
        var found = entry.relativePath.lowercased().hasSuffix("-shipping.exe")
        if !found, var dir = LibraryEntry.hostURL(ofWindowsPath: entry.launchDirectory) {
            let fm = FileManager.default
            for _ in 0..<4 where !found {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir.appendingPathComponent("Engine/Binaries").path, isDirectory: &isDir), isDir.boolValue {
                    found = true
                } else if let items = try? fm.contentsOfDirectory(atPath: dir.path),
                          items.contains(where: { $0.lowercased().hasSuffix("-win64-shipping.exe") }) {
                    found = true
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path || parent.lastPathComponent == "drive_c" { break }
                dir = parent
            }
        }
        cache[entry.id] = found
        return found
    }
    private static var cache: [UUID: Bool] = [:]

    static func enabled(_ entry: LibraryEntry) -> Bool {
        entry.arguments.split(separator: " ").contains { ["-dx11", "-d3d11"].contains($0.lowercased()) }
    }

    static func toggle(_ entry: inout LibraryEntry) {
        if enabled(entry) {
            entry.arguments = entry.arguments.split(separator: " ")
                .filter { !["-dx11", "-d3d11"].contains($0.lowercased()) }.joined(separator: " ")
        } else {
            entry.arguments = (entry.arguments.trimmingCharacters(in: .whitespaces) + " " + flag).trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Deleting a game

/// One way to delete any game, from either home screen: a Steam game is
/// uninstalled (SteamOwnedLibrary.uninstall: its files, record and entry); a game
/// you added from a link or file loses its folder under C:\Games (or the external
/// drive's Games folder) and its entry, so the space comes back. A game installed
/// anywhere else only leaves the library: Madeira does not know which files are
/// its own there. Saves in AppData and Documents are kept.
@MainActor
final class GameDeletion: ObservableObject {
    static let shared = GameDeletion()
    /// The game waiting for the touch library's confirmation.
    @Published var pending: LibraryEntry?

    enum Plan {
        case steam(DockGame)
        case folder(URL)
        case entryOnly
    }

    func plan(_ entry: LibraryEntry) -> Plan {
        if let appID = entry.steamAppID {
            if let game = SteamGamesModel.shared.games.first(where: { $0.id == appID }),
               SteamInstallPaths.isManaged(library: game.library) { return .steam(game) }
            return .entryOnly
        }
        let parts = entry.relativePath.split(separator: "/").map(String.init)
        let drive = LibraryModel.drive
        if parts.count >= 3, parts[0].caseInsensitiveCompare("Games") == .orderedSame {
            return .folder(drive.appendingPathComponent("Games/" + parts[1], isDirectory: true))
        }
        if parts.count >= 4, parts[0] == "External", parts[1].caseInsensitiveCompare("Games") == .orderedSame {
            return .folder(drive.appendingPathComponent("External/Games/" + parts[2], isDirectory: true))
        }
        // Epic downloads (Epic.swift): C:\Epic Games\<folder>, or the drive's.
        if entry.epicApp != nil, parts.count >= 3, parts[0] == "Epic Games" {
            return .folder(drive.appendingPathComponent("Epic Games/" + parts[1], isDirectory: true))
        }
        if entry.epicApp != nil, parts.count >= 4, parts[0] == "External", parts[1] == "Epic Games" {
            return .folder(drive.appendingPathComponent("External/Epic Games/" + parts[2], isDirectory: true))
        }
        // GOG downloads (GOG.swift): C:\GOG Games\<folder>, or the drive's.
        if entry.gogID != nil, parts.count >= 3, parts[0] == "GOG Games" {
            return .folder(drive.appendingPathComponent("GOG Games/" + parts[1], isDirectory: true))
        }
        if entry.gogID != nil, parts.count >= 4, parts[0] == "External", parts[1] == "GOG Games" {
            return .folder(drive.appendingPathComponent("External/GOG Games/" + parts[2], isDirectory: true))
        }
        return .entryOnly
    }

    /// The confirmation's text.
    func summary(_ entry: LibraryEntry) -> String {
        let size = entry.folderBytes.map { " (" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + ")" } ?? ""
        switch plan(entry) {
        case .steam, .folder:
            return "\(entry.title)\(size) is deleted from this iPhone and the space comes back. Saves are kept."
        case .entryOnly:
            return "\(entry.title) leaves the library. Its files were not installed by Rig, so they stay on drive C:."
        }
    }

    func delete(_ entry: LibraryEntry) {
        guard LibraryModel.shared.current == nil else { return }
        let model = LibraryModel.shared
        if let cover = entry.coverFile {
            try? FileManager.default.removeItem(at: LibraryModel.documents.appendingPathComponent("madeira-art/" + cover))
        }
        switch plan(entry) {
        case .steam(let game):
            SteamOwnedLibrary.shared.uninstall(game)
            model.remove(entry.id)
        case .folder(let url):
            model.remove(entry.id)
            Task.detached(priority: .utility) {
                // Only a folder directly inside a Games folder, never Games itself.
                let folder = url.standardizedFileURL
                let parent = folder.deletingLastPathComponent().lastPathComponent
                guard parent.caseInsensitiveCompare("Games") == .orderedSame || parent == "GOG Games" || parent == "Epic Games" else { return }
                try? FileManager.default.removeItem(at: folder)
            }
        case .entryOnly:
            model.remove(entry.id)
        }
        LogStore.shared.log("[delete] \(entry.title) plan=\(plan(entry))")
        pending = nil
    }
}

/// The touch library's long-press menu on a game.
struct GameDeleteMenu: ViewModifier {
    let entry: LibraryEntry?
    func body(content: Content) -> some View {
        if let entry {
            content.contextMenu {
                Button(role: .destructive) { GameDeletion.shared.pending = entry } label: {
                    Label("Delete game", systemImage: "trash")
                }
            }
        } else {
            content
        }
    }
}

/// The confirmation, shown over the touch library.
struct GameDeleteDialog: ViewModifier {
    @ObservedObject private var deletion = GameDeletion.shared
    func body(content: Content) -> some View {
        content.confirmationDialog(deletion.pending.map { "Delete \($0.title)?" } ?? "",
                                   isPresented: Binding(get: { deletion.pending != nil }, set: { if !$0 { deletion.pending = nil } }),
                                   titleVisibility: .visible) {
            if let entry = deletion.pending {
                Button("Delete", role: .destructive) { deletion.delete(entry) }
            }
            Button("Cancel", role: .cancel) { deletion.pending = nil }
        } message: {
            Text(deletion.pending.map { deletion.summary($0) } ?? "")
        }
    }
}


// MARK: - Controller button layout

/// MABD local: controller remapping, one global layout and an optional one per
/// game. Applied to the pad state the game sees (GamepadInput), never to what
/// Rig's own menus read, so the guide and its chords keep working. A layout maps
/// each physical button to the button the game gets, or to nothing.
enum PadButton: String, CaseIterable, Codable {
    case a, b, x, y, lb, rb, lt, rt, view, menu, ls, rs, up, down, left, right

    var label: String {
        switch self {
        case .a: "A"; case .b: "B"; case .x: "X"; case .y: "Y"
        case .lb: "LB"; case .rb: "RB"; case .lt: "LT"; case .rt: "RT"
        case .view: "View"; case .menu: "Menu"; case .ls: "Left stick"; case .rs: "Right stick"
        case .up: "D-pad up"; case .down: "D-pad down"; case .left: "D-pad left"; case .right: "D-pad right"
        }
    }

    /// XInput button bit; nil for the analog triggers.
    var mask: UInt16? {
        switch self {
        case .up: 0x0001; case .down: 0x0002; case .left: 0x0004; case .right: 0x0008
        case .menu: 0x0010; case .view: 0x0020; case .ls: 0x0040; case .rs: 0x0080
        case .lb: 0x0100; case .rb: 0x0200; case .a: 0x1000; case .b: 0x2000; case .x: 0x4000; case .y: 0x8000
        case .lt, .rt: nil
        }
    }
}

enum ButtonLayout {
    /// "none" turns a button off; a missing key keeps the button as it is.
    typealias Map = [String: String]
    static let none = "none"
    private static let globalKey = "madeiraButtonLayout"

    static var global: Map {
        get { (UserDefaults.standard.dictionary(forKey: globalKey) as? Map) ?? [:] }
        set { UserDefaults.standard.set(newValue.filter { $0.key != $0.value }, forKey: globalKey) }
    }

    /// What a physical button sends under a layout ("none" or a PadButton raw value).
    static func target(_ button: PadButton, in map: Map) -> String { map[button.rawValue] ?? button.rawValue }
    static func label(_ target: String) -> String { PadButton(rawValue: target)?.label ?? "Nothing" }

    /// The next choice for a button's target: every button, then nothing.
    static func cycle(_ button: PadButton, in map: inout Map, _ d: Int) {
        let choices = PadButton.allCases.map(\.rawValue) + [none]
        let i = choices.firstIndex(of: target(button, in: map)) ?? 0
        let next = choices[(i + (d < 0 ? choices.count - 1 : 1)) % choices.count]
        if next == button.rawValue { map.removeValue(forKey: button.rawValue) } else { map[button.rawValue] = next }
    }

    // The layout of the running game (GamepadInput reads it on its own queue).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeMap: Map = [:]

    /// At launch: the game's own layout, else the global one.
    static func activate(for entry: LibraryEntry?) {
        let map = entry?.buttonLayout ?? global
        lock.lock(); activeMap = map; lock.unlock()
        if !map.isEmpty { LogStore.shared.log("[buttons] \(entry?.buttonLayout == nil ? "global" : "game") layout: " + map.sorted { $0.key < $1.key }.map { "\($0.key)->\($0.value)" }.joined(separator: " ")) }
    }

    /// The pad state with the running game's layout applied. The guide (Home) bit stays.
    static func apply(_ s: winios_gamepad) -> winios_gamepad {
        lock.lock(); let map = activeMap; lock.unlock()
        guard !map.isEmpty else { return s }
        var out = s
        out.buttons = s.buttons & 0x0400
        out.left_trigger = 0; out.right_trigger = 0
        for button in PadButton.allCases {
            let analog: UInt8
            switch button {
            case .lt: analog = s.left_trigger
            case .rt: analog = s.right_trigger
            default: analog = s.buttons & (button.mask ?? 0) != 0 ? 255 : 0
            }
            guard analog > 0, let to = PadButton(rawValue: target(button, in: map)) else { continue }
            switch to {
            case .lt: out.left_trigger = max(out.left_trigger, analog)
            case .rt: out.right_trigger = max(out.right_trigger, analog)
            default: if analog > 30 { out.buttons |= to.mask ?? 0 }
            }
        }
        return out
    }
}

/// One picker per button (touch library).
struct ButtonLayoutRows: View {
    @Binding var map: ButtonLayout.Map

    var body: some View {
        ForEach(PadButton.allCases, id: \.self) { button in
            Picker(button.label, selection: Binding(
                get: { ButtonLayout.target(button, in: map) },
                set: { v in if v == button.rawValue { map.removeValue(forKey: button.rawValue) } else { map[button.rawValue] = v } })) {
                ForEach(PadButton.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                Text("Nothing").tag(ButtonLayout.none)
            }
        }
    }
}

/// Settings › Controller buttons: the global layout.
struct ButtonLayoutSettingsSection: View {
    @State private var map = ButtonLayout.global

    var body: some View {
        Section {
            DisclosureGroup("Button layout") {
                ButtonLayoutRows(map: $map)
                Button("Reset to default") { map = [:] }.disabled(map.isEmpty)
            }
        } header: { Text("Controller buttons") } footer: {
            Text("What each controller button does in games. A game can have its own layout in its details. Rig's guide (Xbox button) always works.")
        }
        .onChange(of: map) { _, m in ButtonLayout.global = m }
    }
}

/// Game details › Controller buttons: this game's own layout, or the global one.
struct ButtonLayoutGameSection: View {
    @Binding var layout: ButtonLayout.Map?

    var body: some View {
        Section {
            Toggle("Own layout for this game", isOn: Binding(get: { layout != nil }, set: { layout = $0 ? ButtonLayout.global : nil }))
            if layout != nil {
                ButtonLayoutRows(map: Binding(get: { layout ?? [:] }, set: { layout = $0 }))
            }
        } header: { Text("Controller buttons") } footer: {
            Text(layout == nil ? "This game uses the layout from Settings." : "Starts from the layout in Settings. Applies at the next start.")
        }
    }
}

// MARK: - Low-memory devices

/// MABD local: a profile for devices with 4 GB of RAM or less (iPad Air 4,
/// older iPhones), where the defaults sized for 8 GB phones run out of memory.
/// Applied once, at the first start on such a device, and only to keys the
/// player has not set: a smaller JIT pool, a 1 GB video memory budget (games
/// pick lighter settings), a 2 GB swap tier, and 30 FPS for new games.
/// Settings › General turns it on or off on any device.
enum LowMemoryDevice {
    /// 4 GB devices report a little under 4 GiB; 6 GB ones about 5.7.
    static let isLow = ProcessInfo.processInfo.physicalMemory < 5_000_000_000
    static let profile: [(key: String, value: String)] = [("pool", "512"), ("vram-mb", "1024"), ("swap-mb", "2048")]
    private static let appliedKey = "madeiraLowMemoryProfileApplied"

    /// Every profile value is in madeira.cfg.
    static var active: Bool { profile.allSatisfy { MadeiraConfig.get($0.key) == $0.value } }
    /// New games start at 30 FPS while the profile is on.
    static var defaultFPSMode: Int { (isLow || UserDefaults.standard.bool(forKey: appliedKey)) && active ? 3 : 1 }

    static func applyIfNeeded() {
        guard isLow, !UserDefaults.standard.bool(forKey: appliedKey) else { return }
        UserDefaults.standard.set(true, forKey: appliedKey)
        for item in profile where MadeiraConfig.get(item.key) == nil { MadeiraConfig.set(item.key, item.value) }
        LogStore.shared.log("[low-memory] ram=\(ProcessInfo.processInfo.physicalMemory >> 20)MB profile applied")
    }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: appliedKey)
        for item in profile { MadeiraConfig.set(item.key, on ? item.value : nil) }
        LogStore.shared.log("[low-memory] profile \(on ? "on" : "off") from Settings")
    }
}

// MARK: - Known games

/// MABD local: settings a game is known to need, put on its library entry when
/// it is first added (a Steam download finishing, or its first details page).
/// Only games tested on this phone are listed; the player can change any of it.
enum KnownGameProfiles {
    struct Profile {
        let note: String
        var config: [String] = []
        var fpsMode: Int?
        var preset: GraphicsPreset?
    }

    static let steam: [Int: Profile] = [
        // PEAK (Unity): ran out of memory loading a match with every setting on
        // low, and is CPU-bound at about 20 FPS. Memory swap for this game only
        // (broad coverage set globally broke Gang Beasts), a steady 30 FPS, and
        // a lighter resolution upscaled by MetalFX.
        3527290: Profile(note: "PEAK: memory swap, 30 FPS, Balanced graphics",
                         config: ["swap-mb = 4096", "env.MADEIRA_SWAP_COVERAGE = broad"],
                         fpsMode: 3, preset: .balanced),
    ]

    static func apply(_ entry: inout LibraryEntry) {
        guard let id = entry.steamAppID, let profile = steam[id] else { return }
        var lines = (entry.config ?? "").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for line in profile.config {
            let key = line.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
            if !lines.contains(where: { $0.hasPrefix(key) }) { lines.append(line) }
        }
        entry.config = lines.joined(separator: "\n")
        if let fps = profile.fpsMode { entry.fpsMode = fps }
        profile.preset?.apply(to: &entry)

    }
}

// MARK: - Controller layout editor

/// MABD local: Steam-style layout editor for the controller home. The pad is
/// drawn in the middle with every button around it; the d-pad moves between
/// them, A picks what one does, LB/RB switch between this game and all games.
extension PadButton {
    /// The name on the editor's pills and in the picker.
    var longLabel: String {
        switch self {
        case .lt: "Left Trigger"; case .lb: "Left Bumper"; case .rt: "Right Trigger"; case .rb: "Right Bumper"
        default: label
        }
    }
    /// The few characters on a small button or a badge.
    var short: String {
        switch self {
        case .ls: "LS"; case .rs: "RS"; case .view: "View"; case .menu: "Menu"
        case .up: "↑"; case .down: "↓"; case .left: "←"; case .right: "→"
        default: label
        }
    }
    /// Where the button sits in the editor, as fractions of its area.
    var spot: CGPoint {
        switch self {
        case .lt: CGPoint(x: 0.15, y: 0.07); case .lb: CGPoint(x: 0.15, y: 0.19)
        case .ls: CGPoint(x: 0.15, y: 0.43)
        case .up: CGPoint(x: 0.15, y: 0.66); case .down: CGPoint(x: 0.15, y: 0.92)
        case .left: CGPoint(x: 0.09, y: 0.79); case .right: CGPoint(x: 0.21, y: 0.79)
        case .view: CGPoint(x: 0.40, y: 0.13); case .menu: CGPoint(x: 0.60, y: 0.13)
        case .rt: CGPoint(x: 0.85, y: 0.07); case .rb: CGPoint(x: 0.85, y: 0.19)
        case .y: CGPoint(x: 0.85, y: 0.34); case .a: CGPoint(x: 0.85, y: 0.58)
        case .x: CGPoint(x: 0.79, y: 0.46); case .b: CGPoint(x: 0.91, y: 0.46)
        case .rs: CGPoint(x: 0.85, y: 0.82)
        }
    }
    var isPill: Bool { [.lt, .lb, .rt, .rb, .view, .menu].contains(self) }
}

@MainActor
final class LayoutEditor: ObservableObject {
    static let shared = LayoutEditor()
    @Published private(set) var open = false
    /// The game being edited; nil edits the layout for all games only.
    @Published private(set) var game: LibraryEntry?
    /// 0: this game, 1: all games (only 1 without a game).
    @Published var tab = 0
    @Published var focus = PadButton.a
    /// The command list for the focused button, and its row.
    @Published var picking = false
    @Published var pickFocus = 0
    private var saveGame: ((LibraryEntry) -> Void)?

    var editingGame: Bool { game != nil && tab == 0 }
    var tabs: [String] { game == nil ? ["All games"] : ["This game", "All games"] }

    /// What the buttons do on the current tab.
    var map: ButtonLayout.Map { editingGame ? (game?.buttonLayout ?? ButtonLayout.global) : ButtonLayout.global }
    /// This game follows the global layout (no own layout yet).
    var followsGlobal: Bool { editingGame && game?.buttonLayout == nil }

    func show(game: LibraryEntry? = nil, save: ((LibraryEntry) -> Void)? = nil) {
        self.game = game; saveGame = save
        tab = 0; focus = .a; picking = false; open = true
    }

    func close() { picking = false; open = false; game = nil; saveGame = nil }

    private func store(_ map: ButtonLayout.Map) {
        if editingGame, var entry = game {
            entry.buttonLayout = map.filter { $0.key != $0.value }
            game = entry; saveGame?(entry)
        } else {
            ButtonLayout.global = map
            objectWillChange.send()
        }
    }

    /// The picker's choices: the button itself, every other button, nothing.
    var choices: [String] {
        [focus.rawValue] + PadButton.allCases.filter { $0 != focus }.map(\.rawValue) + [ButtonLayout.none]
    }
    func choiceLabel(_ c: String) -> String {
        c == focus.rawValue ? "\(focus.longLabel) (default)" : PadButton(rawValue: c)?.longLabel ?? "Nothing (off)"
    }

    func choose(_ c: String) {
        var m = map
        if c == focus.rawValue { m.removeValue(forKey: focus.rawValue) } else { m[focus.rawValue] = c }
        store(m); picking = false
    }

    /// Y: this game back to the global layout, or the global layout back to default.
    func reset() {
        if editingGame, var entry = game { entry.buttonLayout = nil; game = entry; saveGame?(entry); return }
        store([:])
    }
    var resetLabel: String { editingGame ? "Use global layout" : "Reset to default" }

    func openPicker() {
        pickFocus = choices.firstIndex(of: ButtonLayout.target(focus, in: map)) ?? 0
        picking = true
    }

    /// The nearest button in a direction: along it, and not far off to the side.
    private func move(_ dx: CGFloat, _ dy: CGFloat) {
        let from = focus.spot
        let best = PadButton.allCases.filter { $0 != focus }.compactMap { b -> (PadButton, CGFloat)? in
            let vx = b.spot.x - from.x, vy = b.spot.y - from.y
            let along = vx * dx + vy * dy
            guard along > 0.01 else { return nil }
            let side = abs(vx * dy - vy * dx)
            return (b, along + side * 2.5)
        }.min { $0.1 < $1.1 }
        if let best { focus = best.0 }
    }

    func command(_ c: String) {
        if picking {
            switch c {
            case "up": pickFocus = max(pickFocus - 1, 0)
            case "down": pickFocus = min(pickFocus + 1, choices.count - 1)
            case "accept": choose(choices[pickFocus])
            case "back", "guide": picking = false
            default: break
            }
            return
        }
        switch c {
        case "up": move(0, -1)
        case "down": move(0, 1)
        case "left": move(-1, 0)
        case "right": move(1, 0)
        case "accept": openPicker()
        case "add": reset()
        case "tab", "tabBack": if game != nil { tab = tab == 0 ? 1 : 0 }
        case "back", "guide": close()
        default: break
        }
    }
}

struct LayoutEditorView: View {
    @ObservedObject private var editor = LayoutEditor.shared
    @ObservedObject private var theme = ThemeSettings.shared
    @State private var now = Date()

    var body: some View {
        let map = editor.map
        VStack(spacing: 0) {
            header
            HStack(spacing: 6) {
                Text("Select a command for \(editor.focus.longLabel)")
                Image(systemName: "arrow.right")
                Text(ButtonLayout.label(ButtonLayout.target(editor.focus, in: map)))
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .font(.title3.weight(.medium)).lineLimit(1).minimumScaleFactor(0.6)
            .padding(.top, 10)
            if editor.followsGlobal {
                Text("This game uses the global layout. Changing a button gives it its own.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.top, 2)
            }
            GeometryReader { geo in
                ZStack {
                    Image(systemName: "gamecontroller")
                        .resizable().scaledToFit()
                        .fontWeight(.ultraLight)
                        .foregroundStyle(.white.opacity(0.22))
                        .frame(width: geo.size.width * 0.34, height: geo.size.height * 0.62)
                        .position(x: geo.size.width * 0.5, y: geo.size.height * 0.56)
                    stickRing(.ls, geo.size); stickRing(.rs, geo.size)
                    padBackdrop(center: CGPoint(x: PadButton.up.spot.x, y: 0.79), geo.size)
                    padBackdrop(center: CGPoint(x: PadButton.a.spot.x, y: 0.46), geo.size)
                    ForEach(PadButton.allCases, id: \.self) { b in
                        control(b, map: map, size: geo.size)
                            .position(x: b.spot.x * geo.size.width, y: b.spot.y * geo.size.height)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            footer
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.07, green: 0.08, blue: 0.1).ignoresSafeArea())
        .overlay { if editor.picking { picker } }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(editor.game?.title ?? "Rig") Controller Settings")
                    .font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                BatteryIndicator(compact: true)
                Text(now.formatted(date: .omitted, time: .shortened)).font(.headline)
                ProfileAvatar(size: 30)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .padding(.leading, IslandMargins.current().leading)
            .background(Color.black)
            HStack(spacing: 12) {
                if editor.game != nil { shoulderChip("LB") }
                Spacer()
                ForEach(editor.tabs.indices, id: \.self) { i in
                    Text(editor.tabs[i].uppercased())
                        .font(.subheadline.weight(.bold)).tracking(1)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(i == editor.tab ? Color.white.opacity(0.18) : .clear, in: Capsule())
                        .foregroundStyle(i == editor.tab ? .white : .white.opacity(0.65))
                        .onTapGesture { editor.tab = i }
                }
                Spacer()
                if editor.game != nil { shoulderChip("RB") }
            }
            .padding(.horizontal, 24)
        }
    }

    private func shoulderChip(_ s: String) -> some View {
        Text(s).font(.headline.weight(.heavy)).foregroundStyle(.black)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
    }

    private var footer: some View {
        HStack(spacing: 22) {
            ButtonHint(glyph: "y.circle.fill", label: editor.resetLabel).onTapGesture { editor.reset() }
            Spacer()
            ButtonHint(glyph: "a.circle.fill", label: "Select").onTapGesture { editor.openPicker() }
            ButtonHint(glyph: "b.circle.fill", label: "Back").onTapGesture { editor.close() }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .padding(.leading, IslandMargins.current().leading)
        .background(Color.black)
    }

    private func stickRing(_ b: PadButton, _ size: CGSize) -> some View {
        let d = min(size.width * 0.13, size.height * 0.3)
        return ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
            ForEach(0..<4, id: \.self) { i in
                Image(systemName: "triangle.fill").font(.system(size: d * 0.1))
                    .rotationEffect(.degrees(Double(i) * 90))
                    .offset(y: -d * 0.4).rotationEffect(.degrees(Double(i) * 90))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: d, height: d)
        .position(x: b.spot.x * size.width, y: b.spot.y * size.height)
    }

    private func padBackdrop(center: CGPoint, _ size: CGSize) -> some View {
        let d = min(size.width * 0.15, size.height * 0.36)
        return RoundedRectangle(cornerRadius: d * 0.22, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 2)
            .frame(width: d, height: d).rotationEffect(.degrees(45))
            .position(x: center.x * size.width, y: center.y * size.height)
    }

    @ViewBuilder
    private func control(_ b: PadButton, map: ButtonLayout.Map, size: CGSize) -> some View {
        let on = b == editor.focus
        let target = ButtonLayout.target(b, in: map)
        let changed = target != b.rawValue
        let badge = PadButton(rawValue: target)?.short ?? "Off"
        if b.isPill {
            HStack(spacing: 8) {
                Text(b.longLabel).lineLimit(1).minimumScaleFactor(0.7)
                if changed {
                    Text("→ \(badge)").font(.caption.weight(.bold))
                        .foregroundStyle(on ? theme.accent.color : theme.accent.color.opacity(0.95))
                }
            }
            .font(.headline.weight(.medium))
            .foregroundStyle(on ? .black : .white)
            .frame(width: min(size.width * (b == .view || b == .menu ? 0.13 : 0.2), 230), height: min(34, size.height * 0.1))
            .background(on ? Color.white : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: on ? theme.accent.color.opacity(0.9) : .clear, radius: 10)
            .onTapGesture { editor.focus = b; editor.openPicker() }
        } else {
            let d = min(size.width * 0.048, size.height * 0.12) * (b == .ls || b == .rs ? 1.35 : 1)
            ZStack(alignment: .bottomTrailing) {
                Text(b.short)
                    .font(.system(size: d * 0.42, weight: .bold))
                    .foregroundStyle(on ? .black : .white)
                    .frame(width: d, height: d)
                    .background(on ? Color.white : Color.white.opacity(0.28), in: Circle())
                    .overlay { if b == .ls || b == .rs { Circle().stroke(Color.white.opacity(0.5), lineWidth: 2).padding(4) } }
                    .shadow(color: on ? theme.accent.color.opacity(0.9) : .clear, radius: 10)
                if changed {
                    Text(badge).font(.system(size: max(9, d * 0.26), weight: .heavy))
                        .foregroundStyle(theme.accent.onAccent)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(theme.accent.color, in: Capsule())
                        .offset(x: d * 0.22, y: d * 0.12)
                }
            }
            .onTapGesture { editor.focus = b; editor.openPicker() }
        }
    }

    private var picker: some View {
        let choices = editor.choices
        let current = ButtonLayout.target(editor.focus, in: editor.map)
        return ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { editor.picking = false }
            VStack(alignment: .leading, spacing: 8) {
                Text("\(editor.focus.longLabel) does").font(.headline).foregroundStyle(.white.opacity(0.7))
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(choices.indices, id: \.self) { i in
                                let on = i == editor.pickFocus
                                HStack {
                                    Text(editor.choiceLabel(choices[i])).font(.headline)
                                    Spacer()
                                    if choices[i] == current { Image(systemName: "checkmark").font(.headline) }
                                }
                                .foregroundStyle(on ? theme.accent.onAccent : .white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(on ? theme.accent.color : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { editor.choose(choices[i]) }
                                .id(i)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(editor.pickFocus, anchor: .center) }
                    .onChange(of: editor.pickFocus) { _, i in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) } }
                }
                HStack(spacing: 18) {
                    ButtonHint(glyph: "a.circle.fill", label: "Choose")
                    ButtonHint(glyph: "b.circle.fill", label: "Cancel").onTapGesture { editor.picking = false }
                }
            }
            .padding(18)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(.white)
        }
    }
}
