// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import Security
import SwiftUI
import WebKit

// EmuPC: GOG games, downloaded straight from GOG like the Steam ones.
//
// Sign-in is GOG's own web page (the GOG Galaxy client's sign-in, which every
// third-party GOG client uses); its redirect carries a code that is exchanged
// for tokens, kept in the Keychain. The library is the account's owned Windows
// games. A download reads the game's newest Galaxy build (content-system v2):
// the build lists depots, each depot lists files, and each file is a list of
// zlib-compressed chunks fetched from GOG's CDN through a signed link. Files are
// written to C:\GOG Games\<folder> (or the external drive's GOG Games), and the
// game's goggame-<id>.info names the program to start. GOG games carry no DRM,
// so the library entry starts that program directly. Log tag: [gog].

// The store itself (sign-in, library, downloads) is upstream's GOGLibrary.swift; what stays
// here is EmuPC's launch help for GOG games.

/// EmuPC: the registry keys GOG's own installer writes
/// (HKLM\\Software\\GOG.com\\Games\\<id>, both registry views). GOG launchers
/// such as Quake II's Q2Launcher read the install folder from them and say
/// "Game installation not found" without. Written into the prefix's system.reg
/// just before a GOG game starts, while no Wine session is running.
enum GOGRegistry {
    static func ensure(_ entry: LibraryEntry) {
        guard let id = entry.gogID else { return }
        let drive = LibraryModel.drive
        let exe = drive.appendingPathComponent(entry.relativePath)
        // The game folder: where goggame-<id>.info is, at or above the program's folder.
        var folder = exe.deletingLastPathComponent()
        for _ in 0..<3 where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("goggame-\(id).info").path) {
            let up = folder.deletingLastPathComponent()
            guard up.path.hasPrefix(drive.path + "/") else { break }
            folder = up
        }
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("goggame-\(id).info").path) {
            folder = exe.deletingLastPathComponent()
        }
        func windows(_ url: URL) -> String {
            "C:\\" + url.path.dropFirst(drive.path.count + 1).replacingOccurrences(of: "/", with: "\\")
        }
        let path = windows(folder), program = windows(exe)
        let values: [(String, String)] = [
            ("path", path), ("exe", program), ("exeFile", exe.lastPathComponent), ("workingDir", path),
            ("launchCommand", "\"\(program)\" \(entry.arguments)".trimmingCharacters(in: .whitespaces)),
            ("gameID", String(id)), ("productID", String(id)), ("gameName", entry.title), ("language", "English"),
        ]
        let registry = LibraryModel.documents.appendingPathComponent("wine/system.reg")
        guard let data = try? Data(contentsOf: registry), !data.isEmpty else { return }   // no prefix yet
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let now = Int(Date().timeIntervalSince1970)
        var changed = 0
        for key in ["Software\\GOG.com\\Games\\\(id)", "Software\\Wow6432Node\\GOG.com\\Games\\\(id)"] {
            let header = "[" + SteamInstallScripts.escape(key) + "]"
            if lines.firstIndex(where: { $0.lowercased().hasPrefix(header.lowercased()) }) == nil {
                while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
                lines += ["", header + " \(now)", ""]
            }
            let start = lines.firstIndex { $0.lowercased().hasPrefix(header.lowercased()) }!
            for (name, value) in values {
                var end = start + 1
                while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
                let prefix = "\"" + SteamInstallScripts.escape(name) + "\"="
                let line = prefix + "\"" + SteamInstallScripts.escape(value) + "\""
                if let index = (start + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(prefix.lowercased()) }) {
                    if lines[index] != line { lines[index] = line; changed += 1 }
                } else {
                    var at = end
                    while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
                    lines.insert(line, at: at); changed += 1
                }
            }
        }
        guard changed > 0 else { return }
        do {
            try Data(lines.joined(separator: "\n").utf8).write(to: registry, options: .atomic)
            LogStore.shared.log("[gog] registry: \(entry.title) (\(id)) at \(path), \(changed) value(s)")
        } catch {
            LogStore.shared.log("[gog] registry: could not write system.reg: \(error.localizedDescription)")
        }
    }
}


/// EmuPC: GOG games whose own program cannot run here start a better one.
/// Quake II: Q2Launcher never starts the game, and the original quake2.exe needs
/// OpenGL (not available) or its software renderer, which rewrites its own code
/// (not allowed on iOS). Yamagi Quake II, an open-source engine for the same game
/// files, runs instead when its yquake2.exe is in the game folder: software
/// renderer, full screen at the screen's resolution.
enum GOGLaunchOverride {
    struct Override {
        let replaces: [String]; let program: String; let arguments: String; var config: [String] = []
        /// Arguments for the OpenGL renderer (the game page's Renderer row; driver_ios.c + gl4es).
        var openGLArguments: String? = nil
    }
    /// The player's choice of the OpenGL renderer, kept in the game's config.
    static let openGLLine = "env.EMUPC_RENDERER = opengl"
    static func wantsOpenGL(_ entry: LibraryEntry) -> Bool {
        entry.config?.components(separatedBy: "\n").contains(openGLLine) == true
    }
    static func hasRendererChoice(_ entry: LibraryEntry) -> Bool {
        entry.gogID.flatMap { games[$0]?.openGLArguments } != nil
    }
    static let games: [Int: Override] = [
        // SDL draws through Direct3D 9: its Direct3D 11 renderer aborts on DXMT (SetRotation),
        // and its GDI framebuffer never reaches the screen here.
        1441704824: Override(replaces: ["q2launcher.exe", "quake2.exe"], program: "yquake2.exe",
                             arguments: "+set vid_renderer soft +set vid_fullscreen 2 +set r_mode -2",
                             config: ["env.SDL_RENDER_DRIVER = direct3d"],
                             openGLArguments: "+set vid_renderer gl1 +set vid_fullscreen 2 +set r_mode -2"),
    ]

    /// The program and arguments for a fresh install, when the better program is there.
    static func program(for id: Int, in folder: URL) -> (String, String)? {
        guard let o = games[id], FileManager.default.fileExists(atPath: folder.appendingPathComponent(o.program).path) else { return nil }
        return (o.program, o.arguments)
    }

    /// Moves an installed entry to the better program when it is in the game folder.
    static func apply(_ entry: inout LibraryEntry) -> Bool {
        guard let id = entry.gogID, let o = games[id] else { return false }
        let name = entry.relativePath.split(separator: "/").last.map { $0.lowercased() } ?? ""
        let folder = (entry.relativePath as NSString).deletingLastPathComponent
        var changed = false
        if o.replaces.contains(name),
           FileManager.default.fileExists(atPath: LibraryModel.drive.appendingPathComponent(folder).appendingPathComponent(o.program).path) {
            entry.relativePath = folder + "/" + o.program
            entry.arguments = o.arguments
            LogStore.shared.log("[gog] \(entry.title): starts \(o.program)")
            changed = true
        }
        // The program's own config lines (the player's other lines stay); keys this
        // override set before and no longer sets are dropped.
        if entry.relativePath.lowercased().hasSuffix("/" + o.program.lowercased()) {
            func key(_ line: String) -> String { line.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? line }
            let managed: Set<String> = ["env.SDL_RENDER_DRIVER", "env.SDL_FRAMEBUFFER_ACCELERATION", "env.MADEIRA_GAME_GDI_FULLSCREEN"]
            let gl = o.openGLArguments != nil && wantsOpenGL(entry)
            let old = entry.config?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
            let lines = old.filter { !managed.contains(key($0)) } + (gl ? [] : o.config)
            if lines != old { entry.config = lines.joined(separator: "\n"); changed = true }
            let args = gl ? o.openGLArguments! : o.arguments
            if entry.arguments != args { entry.arguments = args; changed = true }
        }
        return changed
    }
}


/// EmuPC: Yamagi Quake II for GOG's Quake II, set up by EmuPC. The game's own
/// quake2.exe cannot draw here (GOGLaunchOverride), so the first install or
/// start fetches Yamagi Quake II (open source, GPL) from its official site,
/// checks it against the SHA-256 of the release that was tested, and puts its
/// engine next to the GOG files: GOG's game data is used as it is, a replaced
/// GOG file is kept as <name>.gog. A controller layout goes in baseq2/autoexec.cfg
/// unless the player already has one.
enum YamagiSetup {
    static let gameID = 1441704824
    static let url = URL(string: "https://deponie.yamagi.org/quake2/windows/quake2-8.70a.zip")!
    static let sha256 = "26cc30f81598d746d691c4adfd7010403969680dc6c65e83df30260cea1e652a"
    static let root = "quake2-8.70a"
    static let files = ["yquake2.exe", "SDL3.dll", "curl.dll", "openal32.dll", "ref_soft.dll", "ref_gl1.dll",
                        "baseq2/game.dll", "baseq2/footsteps.pkz", "ctf/game.dll", "rogue/game.dll", "xatrix/game.dll"]
    static let autoexec = """
        // EmuPC: controller layout for Yamagi Quake II (Xbox names).
        // Runs at every start; change it here or remove this file to use your own binds.
        set joy_labels 1
        bind TRIG_RIGHT +attack
        bind TRIG_LEFT +movedown
        bind BTN_SOUTH +moveup
        bind BTN_EAST +movedown
        bind BTN_WEST invuse
        bind BTN_NORTH inven
        bind SHOULDR_RIGHT weapnext
        bind SHOULDR_LEFT weapprev
        bind DP_LEFT invprev
        bind DP_RIGHT invnext
        bind DP_UP invuse
        bind DP_DOWN invdrop
        bind BTN_BACK "cmd help"
        bind STICK_LEFT +speed
        bind STICK_RIGHT centerview

        """
    nonisolated(unsafe) private static var tried = Set<String>()

    static func needed(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: folder.appendingPathComponent("yquake2.exe").path)
            || !fm.fileExists(atPath: folder.appendingPathComponent("baseq2/autoexec.cfg").path)
    }

    /// Once per app run per folder, so a failed download never blocks Play.
    static func shouldTry(_ folder: URL) -> Bool { needed(folder) && tried.insert(folder.path).inserted }

    static func install(into folder: URL) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.appendingPathComponent("yquake2.exe").path) {
            LogStore.shared.log("[yamagi] downloading \(url.lastPathComponent) for \(folder.lastPathComponent)")
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw YamagiError.message("Yamagi Quake II could not be downloaded.") }
            let work = fm.temporaryDirectory.appendingPathComponent("yamagi-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let zip = work.appendingPathComponent("yamagi.zip")
            try fm.moveItem(at: downloaded, to: zip)
            var hasher = SHA256()
            let handle = try FileHandle(forReadingFrom: zip)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            try handle.close()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else {
                LogStore.shared.log("[yamagi] checksum mismatch \(digest): not installed")
                throw YamagiError.message("The Yamagi Quake II download did not match the tested release, so EmuPC did not install it.")
            }
            let unpacked = work.appendingPathComponent("x", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try ZipExtractor.extract(zip, into: unpacked) { _ in }
            for name in files {
                let source = unpacked.appendingPathComponent(root).appendingPathComponent(name)
                let target = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { throw YamagiError.message("The Yamagi Quake II download is missing \(name).") }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    let backup = target.appendingPathExtension("gog")
                    if !fm.fileExists(atPath: backup.path) { try fm.moveItem(at: target, to: backup) } else { try fm.removeItem(at: target) }
                }
                try fm.copyItem(at: source, to: target)
            }
            LogStore.shared.log("[yamagi] installed \(files.count) files into \(folder.lastPathComponent)")
        }
        let cfg = folder.appendingPathComponent("baseq2/autoexec.cfg")
        if !fm.fileExists(atPath: cfg.path) {
            try fm.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(autoexec.utf8).write(to: cfg, options: .atomic)
        }
    }
}

enum YamagiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
