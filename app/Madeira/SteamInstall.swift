// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Where Madeira's own Steam downloads live, and how one is read and removed
// (docs/STEAM_LIBRARY.md). Foundation only, so tests/host/check-steam-library.py
// compiles this file as it is.
//
// A download goes into Madeira Dock's own Steam library folder,
// C:\Program Files (x86)\Steam\steamapps, as `common/<installdir>` plus Steam's
// `appmanifest_<appid>.acf` install record. That is exactly the layout
// Madeira Dock's discovery (MadeiraDock.games) reads and Valve's client, which
// Dock starts the game through, understands: a game is "installed" for Dock
// once its record says so, and the record is written last.

enum SteamInstallPaths {
    /// The library folder, relative to drive_c (the value `DockGame.library` has).
    static let libraryRelative = "Program Files (x86)/Steam/steamapps"

    static func steamApps(drive: URL) -> URL { drive.appendingPathComponent(libraryRelative, isDirectory: true) }
    static func common(drive: URL) -> URL { steamApps(drive: drive).appendingPathComponent("common", isDirectory: true) }

    /// Whether an install (its drive-relative library folder) is in the library
    /// Madeira downloads into, and so can be updated or removed here.
    static func isManaged(library: String) -> Bool {
        library.caseInsensitiveCompare(libraryRelative) == .orderedSame
    }
}

enum SteamInstallFiles {
    /// The `buildid` the install record of an app states, or nil when there is
    /// no readable record.
    static func buildID(appID: Int, steamApps: URL) -> Int? {
        guard let state = record(appID: appID, steamApps: steamApps) else { return nil }
        return state["buildid"]?.string.flatMap { Int($0) }
    }

    /// The language the install record states (`UserConfig.language`), or nil.
    static func language(appID: Int, steamApps: URL) -> String? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let language = state["UserConfig"]?["language"]?.string, !language.isEmpty else { return nil }
        return language.lowercased()
    }

    /// The depots the install record holds: its own (`InstalledDepots`) and
    /// those shared from other apps (`SharedDepots`).
    static func depots(appID: Int, steamApps: URL) -> Set<Int> {
        guard let state = record(appID: appID, steamApps: steamApps) else { return [] }
        let keys = Array((state["InstalledDepots"]?.fields ?? [:]).keys) + Array((state["SharedDepots"]?.fields ?? [:]).keys)
        return Set(keys.prefix(512).compactMap { Int($0) })
    }

    /// The install size the record states (`SizeOnDisk`, bytes), or nil.
    static func sizeOnDisk(appID: Int, steamApps: URL) -> Int64? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let size = state["SizeOnDisk"]?.string.flatMap({ Int64($0) }), size > 0 else { return nil }
        return size
    }

    /// Removes an app's install: its folder under `common`, its record, its
    /// resume journal and the records of the apps that own its shared depots
    /// (those describe the same folder). Only paths strictly inside
    /// `steamApps/common` are removed.
    nonisolated static func delete(appID: Int, folderName: String, steamApps: URL) {
        let fm = FileManager.default
        let common = steamApps.appendingPathComponent("common", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let link = common.appendingPathComponent(safeFolderName(folderName))
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            // Installed on an external drive: common/<folder> links to
            // <drive>/SteamLibrary/common/<folder>. Remove that folder (only when it
            // has exactly that shape) and the link; never follow the link elsewhere.
            let real = URL(fileURLWithPath: target).standardizedFileURL
            if real.lastPathComponent == link.lastPathComponent,
               real.deletingLastPathComponent().lastPathComponent == "common",
               real.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "SteamLibrary" {
                try? fm.removeItem(at: real)
            }
            try? fm.removeItem(at: link)
        } else {
            let folder = link.resolvingSymlinksInPath().standardizedFileURL
            if folder.path.hasPrefix(common.path + "/"), folder.deletingLastPathComponent().path == common.path {
                try? fm.removeItem(at: folder)
            }
        }
        let recordURL = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        if let state = record(appID: appID, steamApps: steamApps) {
            let shared = (state["SharedDepots"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }).prefix(64)
            for (_, owner) in shared {
                guard let ownerID = owner.string.flatMap({ Int($0) }), ownerID > 0, ownerID != appID,
                      let ownerState = record(appID: ownerID, steamApps: steamApps),
                      let dir = ownerState["installdir"]?.string
                else { continue }
                // An owner in another folder (its own installdir) goes too when
                // it holds nothing but depots shared into this app.
                let mine = Set(shared.filter { $0.value.string == owner.string }.map { $0.key })
                let held = Set((ownerState["InstalledDepots"]?.fields ?? [:]).keys)
                guard safeFolderName(dir).caseInsensitiveCompare(safeFolderName(folderName)) == .orderedSame ||
                      held.isSubset(of: mine) else { continue }
                try? fm.removeItem(at: steamApps.appendingPathComponent("appmanifest_\(ownerID).acf"))
            }
        }
        try? fm.removeItem(at: recordURL)
        try? fm.removeItem(at: steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
    }

    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String]) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }

    /// Materializes already verified shared content in the owner's install folder.
    /// No second download; each replacement is atomic if copying fails.
    nonisolated static func stageSharedContent(paths: [String], from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let sourceRoot = source.resolvingSymlinksInPath().standardizedFileURL
        guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let targetRoot = destination.resolvingSymlinksInPath().standardizedFileURL
        if sourceRoot == targetRoot { return }
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        for path in Set(paths).sorted() where !path.isEmpty {
            try Task.checkCancellation()
            let input = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard input.path.hasPrefix(sourceRoot.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
            let relative = String(input.path.dropFirst(sourceRoot.path.count + 1))
            // Resolve each existing parent: resolving a nonexistent full file
            // path does not reliably resolve its symlinked ancestors on macOS.
            let components = relative.split(separator: "/").map(String.init)
            var parent = targetRoot
            for component in components.dropLast() {
                parent = parent.appendingPathComponent(component).resolvingSymlinksInPath().standardizedFileURL
                guard parent.path.hasPrefix(targetRoot.path + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            let output = parent.appendingPathComponent(components.last!)
            let temporary = parent.appendingPathComponent(".shared-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: input, to: temporary)
            try Task.checkCancellation()
            guard rename(temporary.path, output.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Install folders come from app metadata; keep them to one safe component.
    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.contains(":"),
              !cleaned.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "app" }
        return cleaned
    }

    /// The `AppState` block of `appmanifest_<appid>.acf` when the file is
    /// readable, bounded, and names this app.
    private static func record(appID: Int, steamApps: URL) -> SteamValue? {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], state["appid"]?.string == String(appID) else { return nil }
        return state
    }
}
