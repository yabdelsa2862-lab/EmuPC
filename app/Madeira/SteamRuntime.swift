// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import zlib
#if canImport(CryptoKit)
import CryptoKit
#endif

// Valve's client components for Madeira Dock, fetched from Valve's own update
// CDN (one host, HTTPS) and checked against pinned sizes and SHA-256 sums; the
// unpacked steamclient64.dll must be the client build the Dock host supports.
// Pins never follow a moving client manifest. No Valve binary is bundled.
enum SteamRuntimeFiles {
    struct Package: Sendable {
        let file: String
        let bytes: Int
        let sha256: String
    }
    static let origin = "https://client-update.akamai.steamstatic.com/"
    // MABD local: Valve's 64-bit client 1792618285 (steam_client_win64). The
    // 32-bit channel (steam_client_win32) stopped at the January 2026 build,
    // whose steamclient64.dll lacks the interfaces newer games ask for
    // (SteamUtils011, SteamInput007, SteamNetworkingSockets013): Geometry
    // Dash's SteamAPI_Init failed with it. Dock's adapter 202610 matches this build.
    static let packages = [
        Package(file: "bins_win64.zip.1f91da2609327de9658146b01307e89a13cc1ef8", bytes: 64_309_479,
                sha256: "f34b0d5924d0cca4c81775ed2fef0aee1ca060e2daa5c24270711267786c0236"),
        Package(file: "steam_win64_steamrow.zip.9ddc7f402ba9bec08b7dbee2cf6ee37d21e1b4e0", bytes: 2_692_595,
                sha256: "9a5aba7f8b5341344717f4a07027ac128e6913bb918454672e843fb5f7e61468")
    ]
    static let clientSHA256 = "253e0a11a4415b38c78a42f7bdd6ecc426455f06c1ba6453a48090df3142dbbc"
    /// Earlier pinned clients (Dock adapters 202601, 202609): an install of one of
    /// these is updated in place to the current pin.
    static let previousClients: Set<String> = [
        "71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640",
        "caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee",
    ]
    nonisolated(unsafe) private static var checkedUpdate: Bool?
    /// The installed client is an earlier pinned build (checked once per app run).
    static func needsUpdate(_ root: URL) -> Bool {
        if let checkedUpdate { return checkedUpdate }
        let dll = root.appendingPathComponent("steamclient64.dll")
        guard let data = try? Data(contentsOf: dll, options: .mappedIfSafe) else { checkedUpdate = false; return false }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        checkedUpdate = previousClients.contains(hash)
        return checkedUpdate!
    }
    static func updated() { checkedUpdate = false }
    static let relativeRoot = "Program Files (x86)/Steam"
    static let windowsRoot = "C:\\Program Files (x86)\\Steam"

    enum Failure: LocalizedError {
        case invalidPackage, conflict, activeSession, prefixMissing
        var errorDescription: String? {
            switch self {
            case .invalidPackage: return "Steam's components could not be verified. Try downloading them again."
            case .conflict: return "Existing Steam files need attention. They were kept. Use the desktop setup option."
            case .activeSession: return "Close the running session before preparing Steam's components."
            case .prefixMissing: return "EmuPC could not prepare its Windows environment."
            }
        }
    }

    static func validPath(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count < 240,
              !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(".") || $0.hasSuffix(" ") }
    }

    static func destination(_ relative: String, under drive: URL) throws -> URL {
        guard validPath(relative) else { throw Failure.conflict }
        let fm = FileManager.default
        var result = drive
        for component in relative.split(separator: "/") {
            if fm.fileExists(atPath: result.path) {
                let matches = try fm.contentsOfDirectory(atPath: result.path)
                    .filter { $0.caseInsensitiveCompare(String(component)) == .orderedSame }
                guard matches.isEmpty || matches == [String(component)] else { throw Failure.conflict }
            }
            result.appendPathComponent(String(component))
            guard result.standardizedFileURL.path == result.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw Failure.conflict
            }
        }
        return result
    }

    // Parse the central directory, then validate each local header. ZIP64,
    // encryption, symlinks and duplicate/case-colliding names are rejected.
    // Called only AFTER the whole archive's pinned SHA-256 has been checked.
    static func unpack(_ data: Data, write: (String, Data) throws -> Void) throws {
        func need(_ condition: Bool) throws { if !condition { throw Failure.invalidPackage } }
        try need(data.count >= 22 && data.count <= 64 * 1024 * 1024)
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1)
            .first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == data.count }) else {
            throw Failure.invalidPackage
        }
        let count = u16(end + 10), central = u32(end + 16), centralSize = u32(end + 12)
        try need(u16(end + 4) == 0 && u16(end + 6) == 0 && u16(end + 8) == count && count <= 256)
        try need(central <= end && centralSize == end - central)
        var cursor = central, total = 0
        var seen = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            try need(cursor + 46 <= end && u32(cursor) == 0x02014b50)
            let flags = u16(cursor + 8), method = u16(cursor + 10)
            let crc = UInt32(u32(cursor + 16)), compressed = u32(cursor + 20), size = u32(cursor + 24)
            let nameLength = u16(cursor + 28), local = u32(cursor + 42)
            let next = cursor + 46 + nameLength + u16(cursor + 30) + u16(cursor + 32)
            let kind = (u32(cursor + 38) >> 16) & 0xf000
            try need(next <= end && flags & 1 == 0 && (method == 0 || method == 8))
            try need(kind == 0 || kind == 0x8000 || kind == 0x4000)
            guard let rawName = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8) else {
                throw Failure.invalidPackage
            }
            // Valve's Windows packages use backslashes. Normalize BEFORE all
            // traversal/duplicate checks, but compare local headers verbatim.
            let normalizedName = rawName.replacingOccurrences(of: "\\", with: "/")
            let directory = normalizedName.hasSuffix("/")
            let name = directory ? String(normalizedName.dropLast()) : normalizedName
            try need(validPath(name) && seen.insert(name.lowercased()).inserted)
            try need(size <= 64 * 1024 * 1024 && local + 30 <= central && u32(local) == 0x04034b50)
            try need(u16(local + 6) == flags && u16(local + 8) == method && u16(local + 26) == nameLength)
            let body = local + 30 + nameLength + u16(local + 28)
            try need(body <= central && compressed <= central - body)
            try need(data.subdata(in: local + 30..<local + 30 + nameLength) == Data(rawName.utf8))
            if flags & 8 == 0 { try need(u32(local + 18) == compressed && u32(local + 22) == size) }
            total += size
            try need(total <= 256 * 1024 * 1024)
            if directory { try need(size == 0 && compressed == 0); cursor = next; continue }
            let encoded = data.subdata(in: body..<body + compressed)
            var decoded: Data
            if method == 0 {
                try need(compressed == size); decoded = encoded
            } else {
                decoded = Data(count: max(size, 1))
                var stream = z_stream(), valid = false
                encoded.withUnsafeBytes { source in
                    decoded.withUnsafeMutableBytes { destination in
                        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                        stream.avail_in = UInt32(compressed)
                        stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                        stream.avail_out = UInt32(max(size, 1))
                        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                        let result = inflate(&stream, Z_FINISH)
                        valid = result == Z_STREAM_END && stream.total_in == compressed && stream.total_out == size
                        inflateEnd(&stream)
                    }
                }
                try need(valid); decoded.count = size
            }
            let actualCRC = decoded.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(size)) }
            try need(UInt32(actualCRC) == crc)
            try write(name, decoded)
            cursor = next
        }
        try need(cursor == end)
    }

    /// The registry value or file that stopped the last setup, for the log.
    nonisolated(unsafe) static var lastConflict: String?

    /// A REG_SZ line's value, unescaped ("C:\\\\Steam" in the hive is C:\Steam), or nil.
    static func stringValue(_ line: String, after prefix: String) -> String? {
        let rest = line.dropFirst(prefix.count)
        guard rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 else { return nil }
        return String(rest.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\\", with: "\u{0}").replacingOccurrences(of: "\u{0}", with: "\\")
    }

    // Only fixed client-discovery paths are written. Never write user IDs,
    // licenses, login cache, tokens, or a value asserting ownership.
    // - stale: whether a value already there names a Steam client that is not
    //   on the drive (a C:\ path, unescaped). A Steam emulator shipped with a
    //   game, or a client removed since, leaves SteamPath / SteamClientDll64
    //   pointing at a folder without Steam: such a value is replaced (both hives
    //   keep their .dock-setup-bak copy), and any other differing value is kept.
    static func registry(_ text: String, machine: Bool, stale: (String) -> Bool = { _ in false }) throws -> String {
        guard text.hasPrefix("WINE REGISTRY Version 2") else { throw Failure.prefixMissing }
        let root = windowsRoot.replacingOccurrences(of: "\\", with: "\\\\")
        let sections: [(String, [(String, String)])] = machine
            ? [("Software\\\\Valve\\\\Steam", [("InstallPath", root)]),
               ("Software\\\\Wow6432Node\\\\Valve\\\\Steam", [("InstallPath", root)])]
            : [("Software\\\\Valve\\\\Steam", [("SteamPath", root), ("SteamExe", root + "\\\\steam.exe")]),
               ("Software\\\\Valve\\\\Steam\\\\ActiveProcess",
                [("SteamClientDll", root + "\\\\steamclient.dll"), ("SteamClientDll64", root + "\\\\steamclient64.dll")])]
        var lines = text.components(separatedBy: "\n")
        for (key, values) in sections {
            let header = "[\(key)]"
            let starts = lines.indices.filter { lines[$0].lowercased().hasPrefix(header.lowercased()) }
            guard starts.count <= 1 else { throw Failure.conflict }
            if let start = starts.first {
                let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
                var additions: [String] = []
                for (name, value) in values {
                    let prefix = "\"\(name)\"="
                    let found = lines[(start + 1)..<end].indices.filter { lines[$0].lowercased().hasPrefix(prefix.lowercased()) }
                    let expected = prefix + "\"\(value)\""
                    if found.count == 1, lines[found[0]] != expected, let old = stringValue(lines[found[0]], after: prefix),
                       stale(old) {
                        lines[found[0]] = expected
                        continue
                    }
                    guard found.isEmpty || found.map({ lines[$0] }) == [expected] else {
                        lastConflict = "\(key)\\\(name)"
                        throw Failure.conflict
                    }
                    if found.isEmpty { additions.append(expected) }
                }
                lines.insert(contentsOf: additions, at: end)
            } else {
                lines += ["", header] + values.map { "\"\($0.0)\"=\"\($0.1)\"" } + [""]
            }
        }
        return lines.joined(separator: "\n")
    }
}

#if canImport(CryptoKit)
private final class SteamRuntimeRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == "client-update.akamai.steamstatic.com"
            && (url?.port == nil || url?.port == 443) && url?.user == nil && url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}

actor SteamRuntimeInstaller {
    static let shared = SteamRuntimeInstaller()
    private var busy = false

    // Runs before any Wine session in this app run; no Wine/JIT run.
    func prepare(prefix: URL, progress: @Sendable (String) async -> Void) async throws {
        guard !busy, wine_process_is_running() == 0, wineserver_is_running() == 0 else {
            throw SteamRuntimeFiles.Failure.activeSession
        }
        busy = true; defer { busy = false }
        SteamRuntimeFiles.lastConflict = nil
        let fm = FileManager.default
        // Do not let the template seeder overwrite a preexisting, unstamped
        // registry. Fresh downloads may have created drive_c/steamapps only.
        if !fm.fileExists(atPath: prefix.appendingPathComponent(".update-timestamp").path),
           ["system.reg", "user.reg"].contains(where: { fm.fileExists(atPath: prefix.appendingPathComponent($0).path) }) {
            SteamRuntimeFiles.lastConflict = "an unstamped registry"
            throw SteamRuntimeFiles.Failure.conflict
        }
        let drive = prefix.appendingPathComponent("drive_c")
        let root = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            SteamRuntimeFiles.lastConflict = "a linked Steam folder"
            throw SteamRuntimeFiles.Failure.conflict
        }
        // Existing installs are retained; this trial prepares missing files. MABD local:
        // an earlier pinned client is replaced by the current one instead.
        let upgrading = fm.fileExists(atPath: root.appendingPathComponent("steam.exe").path) && SteamRuntimeFiles.needsUpdate(root)
        guard upgrading || !fm.fileExists(atPath: root.appendingPathComponent("steam.exe").path) else {
            SteamRuntimeFiles.lastConflict = "steam.exe already there"
            throw SteamRuntimeFiles.Failure.conflict
        }
        let stage = fm.temporaryDirectory.appendingPathComponent("madeira-runtime-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: SteamRuntimeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var names = Set<String>(), files: [String] = []
        for (index, package) in SteamRuntimeFiles.packages.enumerated() {
            try Task.checkCancellation()
            await progress("Downloading Steam components (\(index + 1) of \(SteamRuntimeFiles.packages.count))…")
            let url = URL(string: SteamRuntimeFiles.origin + package.file)!
            let (temporary, response) = try await session.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == url.host, http.url?.scheme == "https",
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else {
                throw SteamRuntimeFiles.Failure.invalidPackage
            }
            let archive = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard Self.hash(archive) == package.sha256 else { throw SteamRuntimeFiles.Failure.invalidPackage }
            await progress("Verifying Steam components…")
            try SteamRuntimeFiles.unpack(archive) { name, bytes in
                guard names.insert(name.lowercased()).inserted else { throw SteamRuntimeFiles.Failure.invalidPackage }
                let file = stage.appendingPathComponent(name)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file, options: .atomic)
                files.append(name)
            }
        }
        guard Self.hash(try Data(contentsOf: stage.appendingPathComponent("steamclient64.dll"))) == SteamRuntimeFiles.clientSHA256,
              files.contains("steam.exe") else { throw SteamRuntimeFiles.Failure.invalidPackage }
        try Task.checkCancellation()
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { throw SteamRuntimeFiles.Failure.activeSession }
        await progress("Preparing the Windows environment…")
        try Task.checkCancellation()
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { throw SteamRuntimeFiles.Failure.activeSession }
        madeira_seed_prefix_if_needed(prefix.path)
        // Preflight all destinations and both hives before publishing anything.
        // A discovery value naming a C:\ folder (or a file in one) without steam.exe
        // points at no Steam client: an emulator's or a removed client's leftover.
        let stale: (String) -> Bool = { value in
            guard value.lowercased().hasPrefix("c:\\") else { return false }
            var folder = drive.appendingPathComponent(value.dropFirst(3).replacingOccurrences(of: "\\", with: "/"))
            if [".exe", ".dll"].contains(where: value.lowercased().hasSuffix) { folder.deleteLastPathComponent() }
            return !fm.fileExists(atPath: folder.appendingPathComponent("steam.exe").path)
        }
        var pending: [(URL, Data)] = []
        for (file, machine) in [("system.reg", true), ("user.reg", false)] {
            let url = prefix.appendingPathComponent(file)
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw SteamRuntimeFiles.Failure.conflict
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            pending.append((url, Data(try SteamRuntimeFiles.registry(text, machine: machine, stale: stale).utf8)))
        }
        for name in files {
            let target = try SteamRuntimeFiles.destination(SteamRuntimeFiles.relativeRoot + "/" + name, under: drive)
            if !upgrading, fm.fileExists(atPath: target.path), !fm.contentsEqual(atPath: target.path, andPath: stage.appendingPathComponent(name).path) {
                SteamRuntimeFiles.lastConflict = name
                throw SteamRuntimeFiles.Failure.conflict
            }
        }
        try Task.checkCancellation()
        // No suspension during commit. steam.exe is last, so a check for an installed
        // client never mistakes a partial package for one. A retry accepts
        // identical files left by an interrupted commit, never replaces others.
        for (url, bytes) in pending {
            let backup = url.appendingPathExtension("dock-setup-bak")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
            try bytes.write(to: url, options: .atomic)
        }
        for name in files.sorted(by: { $0 == "steam.exe" ? false : ($1 == "steam.exe" ? true : $0 < $1) }) {
            let target = try SteamRuntimeFiles.destination(SteamRuntimeFiles.relativeRoot + "/" + name, under: drive)
            if fm.fileExists(atPath: target.path) {
                guard upgrading else { continue }
                try fm.removeItem(at: target)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stage.appendingPathComponent(name), to: target)
        }
        if upgrading { SteamRuntimeFiles.updated() }
        await progress(upgrading ? "Steam's client is up to date." : "Steam components are ready.")
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
#endif

/// MABD local: one automatic update attempt per app run (ContentView's launch).
enum SteamClientUpdate {
    nonisolated(unsafe) static var tried = false
}
