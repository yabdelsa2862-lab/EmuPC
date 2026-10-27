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
            return "\(entry.title) leaves the library. Its files were not installed by EmuPC, so they stay on drive C:."
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
/// EmuPC's own menus read, so the guide and its chords keep working. A layout maps
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
            Text("What each controller button does in games. A game can have its own layout in its details. EmuPC's guide (Xbox button) always works.")
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

/// MABD local: the layout editor of the controller home, in the style of
/// Steam's controller settings: a drawn pad in the middle, what each shoulder,
/// trigger and View/Menu does beside it, and the sticks, d-pad and A/B/X/Y as
/// groups underneath. The d-pad moves, A opens, LB/RB switch this game / all
/// games, Y resets, B goes back.
extension PadButton {
    /// The name in the editor and the command list.
    var longLabel: String {
        switch self {
        case .lt: "Left Trigger"; case .lb: "Left Bumper"; case .rt: "Right Trigger"; case .rb: "Right Bumper"
        case .a: "A Button"; case .b: "B Button"; case .x: "X Button"; case .y: "Y Button"
        case .ls: "Left Stick Click"; case .rs: "Right Stick Click"
        default: label
        }
    }
}

@MainActor
final class LayoutEditor: ObservableObject {
    static let shared = LayoutEditor()

    /// The four groups under the pad.
    struct Group { let title: String; let buttons: [PadButton]; let standard: String }
    static let groups = [
        Group(title: "LEFT JOYSTICK", buttons: [.ls], standard: "Standard Joystick"),
        Group(title: "DIRECTIONAL PAD", buttons: [.up, .down, .left, .right], standard: "Standard DPad"),
        Group(title: "RIGHT JOYSTICK", buttons: [.rs], standard: "Standard Joystick"),
        Group(title: "A,B,X,Y", buttons: [.a, .b, .x, .y], standard: "Standard ABXY"),
    ]
    static let leftColumn: [PadButton] = [.lb, .lt, .view]
    static let rightColumn: [PadButton] = [.rb, .rt, .menu]

    enum Slot: Hashable { case left(Int), right(Int), group(Int) }

    @Published private(set) var open = false
    /// The game being edited; nil edits the layout for all games only.
    @Published private(set) var game: LibraryEntry?
    /// 0: this game, 1: all games (only 1 without a game).
    @Published var tab = 0
    @Published var focus = Slot.left(0)
    /// A group's buttons, listed after A on the group.
    @Published var groupOpen: Int?
    @Published var groupFocus = 0
    /// The command list for one button.
    @Published var picking: PadButton?
    @Published var pickFocus = 0
    private var saveGame: ((LibraryEntry) -> Void)?

    var editingGame: Bool { game != nil && tab == 0 }
    var tabs: [String] { game == nil ? ["All games"] : ["This game", "All games"] }
    var map: ButtonLayout.Map { editingGame ? (game?.buttonLayout ?? ButtonLayout.global) : ButtonLayout.global }
    var followsGlobal: Bool { editingGame && game?.buttonLayout == nil }

    func show(game: LibraryEntry? = nil, save: ((LibraryEntry) -> Void)? = nil) {
        self.game = game; saveGame = save
        tab = 0; focus = .left(0); groupOpen = nil; picking = nil; open = true
    }

    func close() { picking = nil; groupOpen = nil; open = false; game = nil; saveGame = nil }

    func target(_ b: PadButton) -> String { ButtonLayout.target(b, in: map) }
    func does(_ b: PadButton) -> String { ButtonLayout.label(target(b)) }
    func changed(_ b: PadButton) -> Bool { target(b) != b.rawValue }

    /// "Standard DPad", or what changed in the group.
    func summary(_ g: Group) -> String {
        let moved = g.buttons.filter(changed)
        if moved.isEmpty { return g.standard }
        if g.buttons.count == 1 { return "Click: \(does(g.buttons[0]))" }
        return "Custom (\(moved.count) changed)"
    }

    /// The buttons the focus stands for (lit on the drawing).
    var focusedButtons: [PadButton] {
        if let picking { return [picking] }
        if let g = groupOpen { return [Self.groups[g].buttons[groupFocus]] }
        switch focus {
        case .left(let i): return [Self.leftColumn[i]]
        case .right(let i): return [Self.rightColumn[i]]
        case .group(let i): return Self.groups[i].buttons
        }
    }

    private func store(_ map: ButtonLayout.Map) {
        if editingGame, var entry = game {
            entry.buttonLayout = map.filter { $0.key != $0.value }
            game = entry; saveGame?(entry)
        } else {
            ButtonLayout.global = map
            objectWillChange.send()
        }
    }

    /// The command list: the button itself, every other button, nothing.
    func choices(_ b: PadButton) -> [String] {
        [b.rawValue] + PadButton.allCases.filter { $0 != b }.map(\.rawValue) + [ButtonLayout.none]
    }
    func choiceLabel(_ c: String, for b: PadButton) -> String {
        c == b.rawValue ? "\(b.longLabel) (default)" : PadButton(rawValue: c)?.longLabel ?? "Nothing (off)"
    }

    func choose(_ c: String) {
        guard let b = picking else { return }
        var m = map
        if c == b.rawValue { m.removeValue(forKey: b.rawValue) } else { m[b.rawValue] = c }
        store(m); picking = nil
    }

    func pick(_ b: PadButton) {
        pickFocus = choices(b).firstIndex(of: target(b)) ?? 0
        picking = b
    }

    /// A on the focus: a button's command list, or a group's buttons.
    func select(_ slot: Slot) {
        focus = slot
        switch slot {
        case .left(let i): pick(Self.leftColumn[i])
        case .right(let i): pick(Self.rightColumn[i])
        case .group(let i):
            let g = Self.groups[i]
            if g.buttons.count == 1 { pick(g.buttons[0]) } else { groupFocus = 0; groupOpen = i }
        }
    }

    /// Y: this game back to the global layout, or the global layout to default.
    func reset() {
        if editingGame, var entry = game { entry.buttonLayout = nil; game = entry; saveGame?(entry); return }
        store([:])
    }
    var resetLabel: String { editingGame ? "Use global layout" : "Reset to default" }

    private func move(_ c: String) {
        let last = Self.leftColumn.count - 1, groups = Self.groups.count
        switch (focus, c) {
        case (.left(let i), "up"): if i > 0 { focus = .left(i - 1) }
        case (.left(let i), "down"): focus = i < last ? .left(i + 1) : .group(0)
        case (.left(let i), "right"): focus = .right(i)
        case (.right(let i), "up"): if i > 0 { focus = .right(i - 1) }
        case (.right(let i), "down"): focus = i < last ? .right(i + 1) : .group(groups - 1)
        case (.right(let i), "left"): focus = .left(i)
        case (.group(let j), "left"): if j > 0 { focus = .group(j - 1) }
        case (.group(let j), "right"): if j < groups - 1 { focus = .group(j + 1) }
        case (.group(let j), "up"): focus = j < groups / 2 ? .left(last) : .right(last)
        default: break
        }
    }

    func command(_ c: String) {
        if let b = picking {
            let list = choices(b)
            switch c {
            case "up": pickFocus = max(pickFocus - 1, 0)
            case "down": pickFocus = min(pickFocus + 1, list.count - 1)
            case "accept": choose(list[pickFocus])
            case "back", "guide": picking = nil
            default: break
            }
            return
        }
        if let g = groupOpen {
            let buttons = Self.groups[g].buttons
            switch c {
            case "up": groupFocus = max(groupFocus - 1, 0)
            case "down": groupFocus = min(groupFocus + 1, buttons.count - 1)
            case "accept": pick(buttons[groupFocus])
            case "back", "guide": groupOpen = nil
            default: break
            }
            return
        }
        switch c {
        case "up", "down", "left", "right": move(c)
        case "accept": select(focus)
        case "add": reset()
        case "tab", "tabBack": if game != nil { tab = tab == 0 ? 1 : 0 }
        case "back", "guide": close()
        default: break
        }
    }
}

/// An Xbox-style pad, drawn in lines; the given buttons are lit.
struct PadDrawing: View {
    let lit: Set<PadButton>
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            // Drawn on a 400 × 300 grid, scaled to fit.
            let k = min(size.width / 400, size.height / 300)
            let ox = (size.width - 400 * k) / 2, oy = (size.height - 300 * k) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * k, y: oy + y * k) }
            let line = Color.white.opacity(0.7), faint = Color.white.opacity(0.45)
            let stroke = StrokeStyle(lineWidth: max(1.2, 1.6 * k), lineCap: .round, lineJoin: .round)

            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: ox + (x - r) * k, y: oy + (y - r) * k, width: 2 * r * k, height: 2 * r * k))
            }
            func on(_ b: PadButton) -> Bool { lit.contains(b) }
            func draw(_ path: Path, _ b: PadButton?, fill: Bool = false) {
                if let b, on(b) {
                    ctx.fill(path, with: .color(accent.opacity(fill ? 0.9 : 0.35)))
                    ctx.stroke(path, with: .color(accent), style: stroke)
                } else {
                    ctx.stroke(path, with: .color(line), style: stroke)
                }
            }

            // Bumpers along the top.
            var lb = Path()
            lb.move(to: p(66, 68)); lb.addQuadCurve(to: p(162, 38), control: p(95, 40))
            lb.addLine(to: p(166, 49)); lb.addQuadCurve(to: p(80, 76), control: p(108, 52))
            lb.closeSubpath()
            var rb = Path()
            rb.move(to: p(334, 68)); rb.addQuadCurve(to: p(238, 38), control: p(305, 40))
            rb.addLine(to: p(234, 49)); rb.addQuadCurve(to: p(320, 76), control: p(292, 52))
            rb.closeSubpath()
            draw(lb, .lb); draw(rb, .rb)
            // Triggers peek out behind them.
            var lt = Path()
            lt.move(to: p(96, 42)); lt.addQuadCurve(to: p(146, 20), control: p(108, 22)); lt.addLine(to: p(156, 30))
            var rt = Path()
            rt.move(to: p(304, 42)); rt.addQuadCurve(to: p(254, 20), control: p(292, 22)); rt.addLine(to: p(244, 30))
            if on(.lt) { ctx.stroke(lt, with: .color(accent), style: StrokeStyle(lineWidth: 4 * k, lineCap: .round)) } else { ctx.stroke(lt, with: .color(faint), style: stroke) }
            if on(.rt) { ctx.stroke(rt, with: .color(accent), style: StrokeStyle(lineWidth: 4 * k, lineCap: .round)) } else { ctx.stroke(rt, with: .color(faint), style: stroke) }

            // The body: shoulders, grips, and the curve between them.
            var body = Path()
            body.move(to: p(200, 50))
            body.addCurve(to: p(318, 58), control1: p(250, 48), control2: p(295, 50))
            body.addCurve(to: p(370, 150), control1: p(345, 70), control2: p(360, 110))
            body.addCurve(to: p(392, 262), control1: p(382, 195), control2: p(395, 235))
            body.addCurve(to: p(345, 292), control1: p(390, 290), control2: p(365, 298))
            body.addCurve(to: p(285, 232), control1: p(320, 285), control2: p(305, 250))
            body.addCurve(to: p(115, 232), control1: p(250, 212), control2: p(150, 212))
            body.addCurve(to: p(55, 292), control1: p(95, 250), control2: p(80, 285))
            body.addCurve(to: p(8, 262), control1: p(35, 298), control2: p(10, 290))
            body.addCurve(to: p(30, 150), control1: p(5, 235), control2: p(18, 195))
            body.addCurve(to: p(82, 58), control1: p(40, 110), control2: p(55, 70))
            body.addCurve(to: p(200, 50), control1: p(105, 50), control2: p(150, 48))
            ctx.stroke(body, with: .color(line), style: stroke)

            // Home (guide) button: a plain ring, no maker's logo.
            ctx.stroke(circle(200, 78, 15), with: .color(faint), style: stroke)
            ctx.stroke(circle(200, 78, 8), with: .color(faint), style: stroke)

            // Left stick (top left) and right stick (bottom right), as on an Xbox pad.
            for (b, cx, cy) in [(PadButton.ls, CGFloat(115), CGFloat(118)), (.rs, 252, 182)] {
                draw(circle(cx, cy, 30), nil)
                draw(circle(cx, cy, 20), b, fill: false)
            }
            // View and Menu.
            draw(circle(170, 118, 8), .view, fill: true)
            draw(circle(230, 118, 8), .menu, fill: true)

            // D-pad.
            ctx.stroke(circle(160, 182, 32), with: .color(faint), style: stroke)
            let arms: [(PadButton, CGRect)] = [
                (.up, CGRect(x: 151, y: 156, width: 18, height: 18)), (.down, CGRect(x: 151, y: 190, width: 18, height: 18)),
                (.left, CGRect(x: 134, y: 173, width: 18, height: 18)), (.right, CGRect(x: 168, y: 173, width: 18, height: 18)),
            ]
            var cross = Path()
            cross.move(to: p(151, 156)); cross.addLine(to: p(169, 156)); cross.addLine(to: p(169, 173)); cross.addLine(to: p(186, 173))
            cross.addLine(to: p(186, 191)); cross.addLine(to: p(169, 191)); cross.addLine(to: p(169, 208)); cross.addLine(to: p(151, 208))
            cross.addLine(to: p(151, 191)); cross.addLine(to: p(134, 191)); cross.addLine(to: p(134, 173)); cross.addLine(to: p(151, 173))
            cross.closeSubpath()
            for (b, r) in arms where on(b) {
                ctx.fill(Path(CGRect(x: ox + r.minX * k, y: oy + r.minY * k, width: r.width * k, height: r.height * k)), with: .color(accent.opacity(0.9)))
            }
            ctx.stroke(cross, with: .color(line), style: stroke)

            // A, B, X, Y.
            for (b, cx, cy) in [(PadButton.y, CGFloat(285), CGFloat(92)), (.x, 260, 118), (.b, 310, 118), (.a, 285, 144)] {
                let c = circle(cx, cy, 12)
                if on(b) { ctx.fill(c, with: .color(accent)) }
                ctx.stroke(c, with: .color(on(b) ? accent : line), style: stroke)
                ctx.draw(Text(b.label).font(.system(size: 13 * k, weight: .bold))
                            .foregroundStyle(on(b) ? Color.black : Color.white.opacity(0.85)),
                         at: p(cx, cy))
            }
        }
        .accessibilityHidden(true)
    }
}

struct LayoutEditorView: View {
    @ObservedObject private var editor = LayoutEditor.shared
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 10) {
                if editor.game != nil { glyphChip("LB") }
                ForEach(editor.tabs.indices, id: \.self) { i in
                    Text("LAYOUT FOR – \(editor.tabs[i].uppercased())")
                        .font(.footnote.weight(i == editor.tab ? .bold : .regular)).tracking(0.5)
                        .foregroundStyle(.white.opacity(i == editor.tab ? 0.95 : 0.4))
                        .onTapGesture { editor.tab = i }
                }
                if editor.game != nil { glyphChip("RB") }
            }
            .padding(.top, 8)
            if editor.followsGlobal {
                Text("Uses the global layout. Changing a button gives this game its own.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).padding(.top, 2)
            }
            GeometryReader { geo in
                let padW = geo.size.width * 0.4
                HStack(spacing: 0) {
                    column(LayoutEditor.leftColumn, left: true, height: geo.size.height)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    PadDrawing(lit: Set(editor.focusedButtons), accent: theme.accent.color)
                        .frame(width: padW, height: geo.size.height)
                    column(LayoutEditor.rightColumn, left: false, height: geo.size.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24).padding(.top, 6)
            HStack(alignment: .top, spacing: 12) {
                ForEach(LayoutEditor.groups.indices, id: \.self) { i in
                    groupCell(i)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .padding(.leading, IslandMargins.current().leading)
            footer
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.06, green: 0.08, blue: 0.1).ignoresSafeArea())
        .overlay { if let g = editor.groupOpen, editor.picking == nil { groupPanel(g) } }
        .overlay { if let b = editor.picking { picker(b) } }
    }

    private var header: some View {
        HStack {
            Text("\(editor.game?.title ?? "EmuPC") Controller Settings")
                .font(.title3.weight(.semibold)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .padding(.leading, IslandMargins.current().leading)
        .background(Color.black)
    }

    private func glyphChip(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.white, in: Capsule())
    }

    /// The physical button's glyph next to its label.
    @ViewBuilder private func glyph(_ b: PadButton) -> some View {
        switch b {
        case .view: Image(systemName: "rectangle.on.rectangle").font(.subheadline)
        case .menu: Image(systemName: "line.3.horizontal").font(.subheadline)
        default: glyphChip(b.label)
        }
    }

    /// LB, LT, View (or RB, RT, Menu): what each does, spread down the pad's height.
    private func column(_ buttons: [PadButton], left: Bool, height: CGFloat) -> some View {
        VStack(alignment: left ? .trailing : .leading, spacing: 0) {
            ForEach(buttons.indices, id: \.self) { i in
                let b = buttons[i]
                let slot: LayoutEditor.Slot = left ? .left(i) : .right(i)
                let on = editor.focus == slot && editor.groupOpen == nil && editor.picking == nil
                HStack(spacing: 10) {
                    if !left { glyph(b) }
                    Text(editor.does(b))
                        .font(.body)
                        .foregroundStyle(editor.changed(b) ? theme.accent.color : .white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if left { glyph(b) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(on ? theme.accent.color : .clear, lineWidth: 2))
                .contentShape(Rectangle())
                .onTapGesture { editor.select(slot) }
                .frame(height: height / CGFloat(buttons.count + 1))
                if i == 0 { Spacer(minLength: 0) }
            }
        }
        .frame(height: height * 0.85)
    }

    private func groupCell(_ i: Int) -> some View {
        let g = LayoutEditor.groups[i]
        let on = editor.focus == .group(i) && editor.groupOpen == nil && editor.picking == nil
        let custom = g.buttons.contains(where: editor.changed)
        return VStack(alignment: .leading, spacing: 4) {
            Text(g.title).font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(.white.opacity(0.55))
            Text(editor.summary(g)).font(.body)
                .foregroundStyle(custom ? theme.accent.color : .white)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(on ? theme.accent.color : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { editor.select(.group(i)) }
    }

    private var footer: some View {
        HStack(spacing: 22) {
            ButtonHint(glyph: "y.circle.fill", label: editor.resetLabel).onTapGesture { editor.reset() }
            Spacer()
            ButtonHint(glyph: "a.circle.fill", label: "Select")
            ButtonHint(glyph: "b.circle.fill", label: "Back").onTapGesture { editor.close() }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .padding(.leading, IslandMargins.current().leading)
        .background(Color.black)
    }

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content, cancel: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.white.opacity(0.7))
                content()
                HStack(spacing: 18) {
                    ButtonHint(glyph: "a.circle.fill", label: "Choose")
                    ButtonHint(glyph: "b.circle.fill", label: "Back").onTapGesture(perform: cancel)
                }
            }
            .padding(18)
            .frame(width: 380)
            .padding(.vertical, 24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(.white)
        }
    }

    private func row(_ title: String, value: String?, on: Bool, check: Bool = false, tap: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let value { Text(value).font(.subheadline.weight(.semibold)) }
            if check { Image(systemName: "checkmark").font(.headline) }
        }
        .foregroundStyle(on ? theme.accent.onAccent : .white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(on ? theme.accent.color : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }

    private func groupPanel(_ g: Int) -> some View {
        let group = LayoutEditor.groups[g]
        return panel(group.title.capitalized) {
            VStack(spacing: 2) {
                ForEach(group.buttons.indices, id: \.self) { i in
                    let b = group.buttons[i]
                    row(b.longLabel, value: editor.does(b), on: i == editor.groupFocus) { editor.groupFocus = i; editor.pick(b) }
                }
            }
        } cancel: { editor.groupOpen = nil }
    }

    private func picker(_ b: PadButton) -> some View {
        let choices = editor.choices(b)
        let current = editor.target(b)
        return panel("\(b.longLabel) does") {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(choices.indices, id: \.self) { i in
                            row(editor.choiceLabel(choices[i], for: b), value: nil, on: i == editor.pickFocus,
                                check: choices[i] == current) { editor.pickFocus = i; editor.choose(choices[i]) }
                                .id(i)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(editor.pickFocus, anchor: .center) }
                .onChange(of: editor.pickFocus) { _, i in withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) } }
            }
        } cancel: { editor.picking = nil }
    }
}

// MARK: - OpenGL games

/// MABD local: a game whose program draws with OpenGL starts with the OpenGL
/// driver on (env.MADEIRA_OPENGL = 1 in its config: gl4es on OpenGL ES,
/// driver_ios.c and build/gl4es-ios). Other games keep it off, so Direct3D
/// games and Steam behave as before. A player's own "env.MADEIRA_OPENGL = 0"
/// stays and turns it off for that game.
enum OpenGLGames {
    static let line = "env.MADEIRA_OPENGL = 1"
    /// Bring-up tracing lines of earlier builds, removed from configs on sight.
    static let oldTraces: Set<String> = [
        "env.WINEDEBUG = err+all,err-virtual,fixme-d3dcompiler,trace+wgl,trace+opengl,warn+win,warn+system,warn+monitor,trace+display",
        "env.WINEDEBUG = err+all,err-virtual,fixme-d3dcompiler,warn+all,warn-virtual,warn-seh,warn-module,warn-file,warn-heap,trace+wgl,trace+opengl,trace+dialog,trace+msgbox",
    ]

    static func uses(_ entry: LibraryEntry) -> Bool {
        entry.graphicsAPI?.localizedCaseInsensitiveContains("OpenGL") == true
            || GOGLaunchOverride.wantsOpenGL(entry)
            || folderImportsOpenGL(entry)
    }

    /// A game whose library scan has not named its graphics API (or named another
    /// program's): any program in its folder that imports opengl32.dll. Geometry
    /// Dash on one device had no API recorded, started without OpenGL and crashed.
    private static func folderImportsOpenGL(_ entry: LibraryEntry) -> Bool {
        let fm = FileManager.default
        var folder = LibraryModel.drive.appendingPathComponent(entry.relativePath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { folder.deleteLastPathComponent() }
        let programs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return programs.contains { $0.pathExtension.lowercased() == "exe" && LibraryModel.importNames($0).contains("opengl32.dll") }
    }

    /// True when the config changed.
    static func apply(_ entry: inout LibraryEntry) -> Bool {
        var lines = entry.config?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let key = { (l: String) in l.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? l }
        let own = lines.first { key($0) == "env.MADEIRA_OPENGL" }
        let traced = lines.contains(where: oldTraces.contains)
        lines.removeAll(where: oldTraces.contains)
        if uses(entry) {
            guard own == nil || traced else { return false }
            if own == nil { lines.append(line) }
        } else {
            guard own == line || traced else { return false }
            lines.removeAll { $0 == line }
        }
        entry.config = lines.isEmpty ? nil : lines.joined(separator: "\n")
        LogStore.shared.log("[gl] \(entry.title): OpenGL driver \(uses(entry) ? "on" : "off")")
        return true
    }
}
