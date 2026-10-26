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
