// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import Security
import SwiftUI
import WebKit

// MABD local: GOG games, downloaded straight from GOG like the Steam ones.
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

enum GOGAPI {
    static let clientID = "46899977096215655"
    static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    static let redirect = "https://embed.gog.com/on_login_success?origin=client"

    static var loginURL: URL {
        var c = URLComponents(string: "https://auth.gog.com/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "layout", value: "client2"),
        ]
        return c.url!
    }

    static func tokenURL(code: String? = nil, refresh: String? = nil) -> URL {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        var q = [URLQueryItem(name: "client_id", value: clientID),
                 URLQueryItem(name: "client_secret", value: clientSecret)]
        if let code {
            q += [URLQueryItem(name: "grant_type", value: "authorization_code"),
                  URLQueryItem(name: "code", value: code),
                  URLQueryItem(name: "redirect_uri", value: redirect)]
        } else if let refresh {
            q += [URLQueryItem(name: "grant_type", value: "refresh_token"),
                  URLQueryItem(name: "refresh_token", value: refresh)]
        }
        c.queryItems = q
        return c.url!
    }

    /// content-system v2 metadata (builds, depot manifests) by hash.
    static func meta(_ hash: String) -> URL {
        let h = hash.lowercased()
        return URL(string: "https://gog-cdn-fastly.gog.com/content-system/v2/meta/\(h.prefix(2))/\(h.dropFirst(2).prefix(2))/\(h)")!
    }

    /// GOG serves its metadata and chunks zlib-wrapped; Foundation inflates raw DEFLATE.
    static func inflate(_ data: Data) throws -> Data {
        guard data.count > 6, data[data.startIndex] & 0x0f == 8 else { throw GOGError.message("Bad compressed data from GOG.") }
        let raw = data.subdata(in: (data.startIndex + 2)..<(data.endIndex - 4))
        return try (raw as NSData).decompressed(using: .zlib) as Data
    }
}

enum GOGError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

// MARK: - Tokens

struct GOGTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var userID: String
    var expires: Date
}

enum GOGTokenStore {
    private static let service = "madeira.gog.tokens"

    static func load() -> GOGTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "gog", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GOGTokens.self, from: data)
    }

    static func save(_ tokens: GOGTokens) {
        clear()
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "gog", kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "gog"]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Library

struct GOGGame: Codable, Identifiable, Equatable {
    let id: Int
    var title: String
    /// Horizontal artwork (https), from the product's images.logo2x.
    var image: String?
    var folder: String?
    var installed: Bool?
}

@MainActor
final class GOGLibrary: ObservableObject {
    static let shared = GOGLibrary()

    @Published private(set) var signedIn = GOGTokenStore.load() != nil
    @Published private(set) var owned: [GOGGame] = []
    @Published private(set) var refreshing = false
    @Published var error: String?

    struct Download: Equatable {
        enum State: Equatable { case queued, active, paused, failed(String) }
        var state: State
        var done: Int64 = 0
        var total: Int64 = 0
        var bytesPerSecond: Double = 0
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }
    @Published private(set) var downloads: [Int: Download] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    /// Download and installed size per game, from its newest build's depots.
    @Published private(set) var sizes: [Int: StoreSize] = StoreSize.load("gog-sizes.json").reduce(into: [:]) { d, kv in if let k = Int(kv.key) { d[k] = kv.value } }
    private var sizing = Set<Int>()

    func requestSize(_ id: Int) {
        guard sizes[id] == nil, !sizing.contains(id) else { return }
        sizing.insert(id)
        Task {
            defer { sizing.remove(id) }
            guard let (bdata, _) = try? await URLSession.shared.data(from: URL(string: "https://content-system.gog.com/products/\(id)/os/windows/builds?generation=2")!),
                  let builds = try? JSONSerialization.jsonObject(with: bdata) as? [String: Any],
                  let items = builds["items"] as? [[String: Any]],
                  let link = ((items.first { ($0["branch"] as? String) == nil } ?? items.first)?["link"] as? String).flatMap(URL.init(string:)),
                  let (mdata, _) = try? await URLSession.shared.data(from: link),
                  let plain = try? GOGAPI.inflate(mdata),
                  let manifest = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return }
            let depots = (manifest["depots"] as? [[String: Any]] ?? []).filter {
                ($0["isGogDepot"] as? Bool) != true && ($0["productId"] as? String) == String(id)
            }
            func langs(_ d: [String: Any]) -> [String] { d["languages"] as? [String] ?? [] }
            let english = depots.contains { langs($0).contains { $0.hasPrefix("en") } }
            let chosen = depots.filter { d in langs(d).contains("*") || !english || langs(d).contains { $0.hasPrefix("en") } }
            let disk = chosen.reduce(Int64(0)) { $0 + ((($1["size"] as? NSNumber)?.int64Value) ?? 0) }
            let download = chosen.reduce(Int64(0)) { $0 + ((($1["compressedSize"] as? NSNumber)?.int64Value) ?? 0) }
            sizes[id] = StoreSize(download: download, disk: disk)
            StoreSize.save(Dictionary(uniqueKeysWithValues: sizes.map { (String($0.key), $0.value) }), "gog-sizes.json")
        }
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gog-library.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? JSONDecoder().decode([GOGGame].self, from: data) {
            owned = cached
        }
    }

    /// Games not yet in the Madeira library, for Download games.
    var notInstalled: [GOGGame] {
        let installedIDs = Set(LibraryModel.shared.entries.compactMap(\.gogID))
        return owned.filter { !installedIDs.contains($0.id) }
    }

    // MARK: Sign-in

    func finishSignIn(code: String) async {
        do {
            let tokens = try await Self.requestTokens(GOGAPI.tokenURL(code: code))
            GOGTokenStore.save(tokens)
            signedIn = true
            LogStore.shared.log("[gog] signed in user=\(tokens.userID)")
            await refresh()
        } catch {
            self.error = "GOG sign-in failed: \(error.localizedDescription)"
            LogStore.shared.log("[gog] sign-in failed: \(error.localizedDescription)", level: .error)
        }
    }

    func signOut() {
        GOGTokenStore.clear()
        signedIn = false
        owned = []
        try? FileManager.default.removeItem(at: Self.cacheURL)
        LogStore.shared.log("[gog] signed out")
    }

    private static func requestTokens(_ url: URL) async throws -> GOGTokens {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw GOGError.message("GOG did not accept the sign-in.")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let user = (json["user_id"] as? String) ?? ""
        return GOGTokens(accessToken: access, refreshToken: refresh, userID: user, expires: Date().addingTimeInterval(expiresIn - 120))
    }

    /// A valid access token, refreshed when it has expired.
    func accessToken() async throws -> String {
        guard var tokens = GOGTokenStore.load() else { signedIn = false; throw GOGError.message("Sign in to GOG first.") }
        if tokens.expires < Date() {
            let fresh = try await Self.requestTokens(GOGAPI.tokenURL(refresh: tokens.refreshToken))
            tokens = GOGTokens(accessToken: fresh.accessToken, refreshToken: fresh.refreshToken,
                               userID: fresh.userID.isEmpty ? tokens.userID : fresh.userID, expires: fresh.expires)
            GOGTokenStore.save(tokens)
        }
        return tokens.accessToken
    }

    // MARK: Owned games

    func refresh() async {
        guard signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let token = try await accessToken()
            var request = URLRequest(url: URL(string: "https://embed.gog.com/user/data/games")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = json["owned"] as? [Int] else { throw GOGError.message("GOG did not return your games.") }
            var games: [GOGGame] = []
            for start in stride(from: 0, to: ids.count, by: 50) {
                let batch = ids[start..<min(start + 50, ids.count)].map(String.init).joined(separator: ",")
                let url = URL(string: "https://api.gog.com/products?ids=\(batch)")!
                let (pdata, _) = try await URLSession.shared.data(from: url)
                guard let products = try JSONSerialization.jsonObject(with: pdata) as? [[String: Any]] else { continue }
                for p in products {
                    guard let id = p["id"] as? Int, let title = p["title"] as? String,
                          (p["game_type"] as? String ?? "game") == "game" else { continue }
                    let systems = p["content_system_compatibility"] as? [String: Any]
                    guard systems?["windows"] as? Bool ?? true else { continue }
                    var image = (p["images"] as? [String: Any])?["logo2x"] as? String
                    if let i = image, i.hasPrefix("//") { image = "https:" + i }
                    games.append(GOGGame(id: id, title: title, image: image))
                }
            }
            games.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            owned = games
            if let data = try? JSONEncoder().encode(games) { try? data.write(to: Self.cacheURL, options: .atomic) }
            LogStore.shared.log("[gog] library: \(ids.count) owned, \(games.count) Windows games")
        } catch {
            self.error = "Could not load your GOG library: \(error.localizedDescription)"
            LogStore.shared.log("[gog] library failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: Downloads

    func install(_ id: Int) {
        guard let game = owned.first(where: { $0.id == id }), tasks[id] == nil else { return }
        downloads[id] = Download(state: .active)
        let external = GameImporter.shared.toExternal && ExternalDrive.shared.root != nil
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.accessToken()
                let result = try await GOGInstaller(game: game, token: token, external: external) { done, total, speed in
                    Task { @MainActor in
                        guard var d = self.downloads[id], d.state == .active else { return }
                        d.done = done; d.total = total; d.bytesPerSecond = speed
                        self.downloads[id] = d
                    }
                }.run()
                self.addToLibrary(game, result)
                self.downloads[id] = nil
                LogStore.shared.log("[gog] installed \(game.title) -> \(result.program)")
            } catch is CancellationError {
                self.downloads[id]?.state = .paused
            } catch {
                if Task.isCancelled { self.downloads[id]?.state = .paused }
                else {
                    self.downloads[id]?.state = .failed(error.localizedDescription)
                    LogStore.shared.log("[gog] \(game.title) failed: \(error.localizedDescription)", level: .error)
                }
            }
            self.tasks[id] = nil
        }
    }

    func pause(_ id: Int) {
        tasks[id]?.cancel()
        downloads[id]?.state = .paused
    }

    func cancel(_ id: Int) {
        tasks[id]?.cancel()
        tasks[id] = nil
        downloads[id] = nil
    }

    private func addToLibrary(_ game: GOGGame, _ result: GOGInstaller.Result) {
        let model = LibraryModel.shared
        var entry = (try? LibraryModel.inspect(result.program)) ?? LibraryEntry(title: game.title, relativePath: "", bits: 0)
        if entry.relativePath.isEmpty, let relative = LibraryModel.relativeToDrive(result.program) { entry.relativePath = relative }
        if let existing = model.entries.first(where: { $0.gogID == game.id }) { entry.id = existing.id }
        entry.title = game.title
        entry.gogID = game.id
        entry.arguments = result.arguments
        if let dir = result.workingDirectory { entry.workingDirectory = dir }
        entry.folderBytes = result.bytes
        if let cover = result.cover { entry.coverFile = cover }
        model.save(entry)
    }
}

// MARK: - Installer

/// One game's download: newest Windows build, its depots and files.
struct GOGInstaller {
    let game: GOGGame
    let token: String
    let external: Bool
    let progress: @Sendable (Int64, Int64, Double) -> Void

    struct Result {
        var program: URL
        var arguments: String
        var workingDirectory: String?
        var bytes: Int64
        var cover: String?
    }

    private struct Chunk { let md5: String; let compressedMd5: String; let size: Int64; let compressedSize: Int64 }
    private struct File { let path: String; let product: String; let chunks: [Chunk]; var size: Int64 { chunks.reduce(0) { $0 + $1.size } } }

    private func json(_ url: URL, auth: Bool = false, compressed: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GOGError.message("GOG answered \(http.statusCode) for \(url.lastPathComponent).")
        }
        let body = compressed ? try GOGAPI.inflate(data) : data
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw GOGError.message("Unexpected answer from GOG.") }
        return obj
    }

    func run() async throws -> Result {
        // The newest build of the default branch.
        let builds = try await json(URL(string: "https://content-system.gog.com/products/\(game.id)/os/windows/builds?generation=2")!, auth: true)
        guard let items = builds["items"] as? [[String: Any]],
              let build = items.first(where: { ($0["branch"] as? String) == nil }) ?? items.first,
              let link = (build["link"] as? String).flatMap(URL.init(string:)) else {
            throw GOGError.message("This game has no Galaxy download on GOG (only an older installer), which Rig can't use yet.")
        }
        let manifest = try await json(link, compressed: true)
        let folderName = (manifest["installDirectory"] as? String).map(Self.safeName) ?? Self.safeName(game.title)
        let depots = (manifest["depots"] as? [[String: Any]] ?? []).filter { ($0["isGogDepot"] as? Bool) != true }
        let base = String(game.id)
        // One language: English where the game offers a choice, otherwise what it has.
        func langs(_ d: [String: Any]) -> [String] { d["languages"] as? [String] ?? [] }
        let english = depots.contains { langs($0).contains { $0.hasPrefix("en") } }
        let chosen = depots.filter { d in
            let l = langs(d)
            guard (d["productId"] as? String) == base else { return false }
            return l.contains("*") || !english || l.contains { $0.hasPrefix("en") }
        }
        guard !chosen.isEmpty else { throw GOGError.message("GOG lists no Windows files for this game.") }

        var files: [File] = []
        for depot in chosen {
            guard let hash = depot["manifest"] as? String else { continue }
            let product = depot["productId"] as? String ?? base
            let content = try await json(GOGAPI.meta(hash), compressed: true)
            let list = (content["depot"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            for item in list where (item["type"] as? String) == "DepotFile" {
                guard let path = item["path"] as? String, let chunks = item["chunks"] as? [[String: Any]] else { continue }
                let parsed = chunks.compactMap { c -> Chunk? in
                    guard let md5 = c["md5"] as? String, let cmd5 = c["compressedMd5"] as? String,
                          let size = (c["size"] as? NSNumber)?.int64Value,
                          let csize = (c["compressedSize"] as? NSNumber)?.int64Value else { return nil }
                    return Chunk(md5: md5, compressedMd5: cmd5, size: size, compressedSize: csize)
                }
                files.append(File(path: path, product: product, chunks: parsed))
            }
        }

        let root = LibraryModel.drive.appendingPathComponent(external ? "External/GOG Games" : "GOG Games", isDirectory: true)
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let need = files.reduce(Int64(0)) { $0 + $1.size }
        if let free = ExternalDrive.freeBytes(atPath: root.path), Int64(free) < need {
            throw GOGError.message("Not enough space: \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) needed.")
        }
        LogStore.shared.log("[gog] \(game.title): build \(build["build_id"] as? String ?? "?"), \(chosen.count) depot(s), \(files.count) files, \(need >> 20)MB -> \(folder.path)")

        // Signed CDN links, one per product.
        var links: [String: (format: String, params: [String: String])] = [:]
        for product in Set(files.map(\.product)) {
            let secure = try await json(URL(string: "https://content-system.gog.com/products/\(product)/secure_link?generation=2&path=/&_version=2")!, auth: true)
            guard let first = (secure["urls"] as? [[String: Any]])?.first, let format = first["url_format"] as? String else {
                throw GOGError.message("GOG did not give a download link.")
            }
            var params: [String: String] = [:]
            for (k, v) in first["parameters"] as? [String: Any] ?? [:] { params[k] = "\(v)" }
            links[product] = (format, params)
        }
        func chunkURL(_ product: String, _ compressedMd5: String) -> URL? {
            guard var link = links[product] else { return nil }
            let m = compressedMd5.lowercased()
            link.params["path"] = (link.params["path"] ?? "") + "/\(m.prefix(2))/\(m.dropFirst(2).prefix(2))/\(m)"
            var url = link.format
            for (k, v) in link.params { url = url.replacingOccurrences(of: "{\(k)}", with: v) }
            return URL(string: url)
        }

        let total = files.reduce(Int64(0)) { $0 + $1.chunks.reduce(0) { $0 + $1.compressedSize } }
        let counter = GOGProgress(total: total, report: progress)
        // A file already on disk at its full size is kept (a resumed download).
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for file in files {
                if running >= 6 { try await group.next(); running -= 1 }
                running += 1
                group.addTask {
                    try Task.checkCancellation()
                    let target = folder.appendingPathComponent(Self.localPath(file.path))
                    guard target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                        throw GOGError.message("GOG listed a file outside the game folder.")
                    }
                    let fm = FileManager.default
                    if let attrs = try? fm.attributesOfItem(atPath: target.path), (attrs[.size] as? NSNumber)?.int64Value == file.size {
                        await counter.add(file.chunks.reduce(0) { $0 + $1.compressedSize })
                        return
                    }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let partial = target.appendingPathExtension("madeira-part")
                    fm.createFile(atPath: partial.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: partial)
                    defer { try? handle.close() }
                    for chunk in file.chunks {
                        try Task.checkCancellation()
                        guard let url = chunkURL(file.product, chunk.compressedMd5) else { throw GOGError.message("No download link for a file.") }
                        var attempt = 0
                        while true {
                            do {
                                let (data, response) = try await URLSession.shared.data(from: url)
                                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GOGError.message("GOG's server refused a file.") }
                                let plain = try GOGAPI.inflate(data)
                                let digest = Insecure.MD5.hash(data: plain).map { String(format: "%02x", $0) }.joined()
                                guard digest == chunk.md5.lowercased() else { throw GOGError.message("A downloaded file was damaged.") }
                                try handle.write(contentsOf: plain)
                                break
                            } catch {
                                attempt += 1
                                if attempt >= 3 || error is CancellationError { throw error }
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                        }
                        await counter.add(chunk.compressedSize)
                    }
                    try handle.close()
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: partial, to: target)
                }
            }
            try await group.waitForAll()
        }

        // The program: goggame-<id>.info's primary play task.
        let info = folder.appendingPathComponent("goggame-\(game.id).info")
        var program: URL?
        var arguments = ""
        var workingDirectory: String?
        if let data = try? Data(contentsOf: info),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tasks = obj["playTasks"] as? [[String: Any]] {
            let task = tasks.first { ($0["isPrimary"] as? Bool) == true && ($0["type"] as? String ?? "FileTask") == "FileTask" }
                ?? tasks.first { ($0["type"] as? String ?? "FileTask") == "FileTask" }
            if let task, let path = task["path"] as? String {
                program = folder.appendingPathComponent(Self.localPath(path))
                arguments = task["arguments"] as? String ?? ""
                if let wd = task["workingDir"] as? String, !wd.isEmpty {
                    let rel = (external ? "External\\GOG Games\\" : "GOG Games\\") + folderName + "\\" + wd.replacingOccurrences(of: "/", with: "\\")
                    workingDirectory = "C:\\" + rel
                }
            }
        }
        if program == nil {
            // No info file: the largest .exe in the top folder.
            let exes = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]))?
                .filter { $0.pathExtension.lowercased() == "exe" && !$0.lastPathComponent.lowercased().hasPrefix("unins") } ?? []
            program = exes.max { (($0.fileSize) ?? 0) < (($1.fileSize) ?? 0) }
        }
        guard let program else { throw GOGError.message("Installed, but Rig could not find the game's program.") }
        let cover = await Self.fetchCover(game.id)
        return Result(program: program, arguments: arguments, workingDirectory: workingDirectory, bytes: need, cover: cover)
    }

    static func localPath(_ gogPath: String) -> String {
        gogPath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
    }

    static func safeName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = name.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Game" : cleaned
    }

    /// The vertical box art, saved as the library cover.
    static func fetchCover(_ id: Int) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://api.gog.com/v2/games/\(id)")!),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let href = ((obj["_links"] as? [String: Any])?["boxArtImage"] as? [String: Any])?["href"] as? String,
              let url = URL(string: href),
              let (image, _) = try? await URLSession.shared.data(from: url), image.count > 1000 else { return nil }
        let dir = LibraryModel.documents.appendingPathComponent("madeira-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "gog-\(id).\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)"
        guard (try? image.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }
}

private extension URL {
    var fileSize: Int? { (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
}

/// Download progress shared by the file tasks.
actor GOGProgress {
    let total: Int64
    let report: @Sendable (Int64, Int64, Double) -> Void
    private var done: Int64 = 0
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private var speed: Double = 0

    init(total: Int64, report: @escaping @Sendable (Int64, Int64, Double) -> Void) {
        self.total = total
        self.report = report
    }

    func add(_ bytes: Int64) {
        done += bytes
        windowBytes += bytes
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            speed = Double(windowBytes) / elapsed
            windowBytes = 0
            windowStart = Date()
        }
        report(done, total, speed)
    }
}

// MARK: - Sign-in sheet

/// GOG's sign-in page. Its redirect to embed.gog.com/on_login_success carries the code.
struct GOGSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var finishing = false

    var body: some View {
        NavigationStack {
            ZStack {
                GOGWebView { code in
                    finishing = true
                    Task {
                        await GOGLibrary.shared.finishSignIn(code: code)
                        SignInWebContainer.end("gog")
                        dismiss()
                    }
                }
                if finishing { ProgressView("Signing in…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .navigationTitle("Sign in to GOG").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { SignInWebContainer.end("gog"); dismiss() } } }
        }
    }
}

/// A sign-in page that opens real popup windows on top of itself (Google,
/// Discord, Xbox and Steam sign-ins report back to the page that opened them,
/// so loading them in place left a blank page). `match` gets every navigation
/// and page load: it returns true when it found what the sign-in needs.
final class SignInWebContainer: UIView, WKNavigationDelegate, WKUIDelegate {
    static let safariAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    var onNavigate: ((URL) -> Bool)?
    var onFinish: ((WKWebView) -> Void)?
    /// The sign-in found what it needs; later matches are ignored.
    var done = false

    /// One live page per sign-in, so leaving for an authenticator app and coming
    /// back (which can rebuild the sheet) keeps the page where it was instead of
    /// starting over. Dropped when the sign-in ends.
    private static var live: [String: SignInWebContainer] = [:]
    static func page(_ key: String, start: URL) -> SignInWebContainer {
        if let page = live[key] { return page }
        let page = SignInWebContainer(start: start)
        live[key] = page
        return page
    }
    static func end(_ key: String) { live[key] = nil }
    private var popups: [WKWebView] = []
    let main: WKWebView

    init(start: URL) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        main = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        configure(main)
        main.load(URLRequest(url: start))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.customUserAgent = Self.safariAgent
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: bounds, configuration: configuration)
        configure(popup)
        popups.append(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView !== main else { return }
        webView.removeFromSuperview()
        popups.removeAll { $0 === webView }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, onNavigate?(url) == true { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(webView) }
}

private struct GOGWebView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> SignInWebContainer {
        let view = SignInWebContainer.page("gog", start: GOGAPI.loginURL)
        view.onNavigate = { [weak view] url in
            guard let view, url.host == "embed.gog.com", url.path.hasPrefix("/on_login_success"),
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value
            else { return false }
            if !view.done { view.done = true; onCode(code) }
            return true
        }
        return view
    }

    func updateUIView(_ uiView: SignInWebContainer, context: Context) {}
}

// MARK: - Download games section

struct GOGDownloadSection: View {
    let search: String
    @ObservedObject private var gog = GOGLibrary.shared
    @State private var signIn = false

    private var games: [GOGGame] {
        let list = gog.notInstalled
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Section {
            if !gog.signedIn {
                Button { signIn = true } label: {
                    Label("Sign in to GOG", systemImage: "person.crop.circle.badge.plus").fontWeight(.semibold)
                }
            } else if games.isEmpty {
                if gog.refreshing {
                    HStack { ProgressView(); Text("Loading your GOG library…").foregroundStyle(.secondary) }
                } else {
                    Text(search.isEmpty ? (gog.owned.isEmpty ? "Pull down to load your GOG library." : "Every GOG game you own is installed.")
                         : "No GOG games match \"\(search)\".").foregroundStyle(.secondary)
                }
            } else {
                ForEach(games) { game in row(game) }
            }
            if let error = gog.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("GOG")
                Spacer()
                if gog.refreshing { ProgressView().controlSize(.mini) }
                if gog.signedIn {
                    Menu {
                        Button { Task { await gog.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { gog.signOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        } footer: {
            Text(gog.signedIn ? "GOG games have no DRM: they download straight from GOG and start without a launcher. Keep Rig open while they download."
                              : "Sign in with your GOG account to download the games you own.")
        }
        .sheet(isPresented: $signIn) { GOGSignInView() }
        .task { if gog.signedIn && gog.owned.isEmpty { await gog.refresh() } }
    }

    private func row(_ game: GOGGame) -> some View {
        let download = gog.downloads[game.id]
        return HStack(spacing: 12) {
            AsyncImage(url: game.image.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.body.weight(.semibold)).lineLimit(2)
                if download == nil {
                    StoreSizeLine(size: gog.sizes[game.id]).onAppear { gog.requestSize(game.id) }
                    StoreCompatibility(gogID: game.id)
                }
                if let download {
                    switch download.state {
                    case .queued: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                    case .active:
                        ProgressView(value: download.fraction)
                        Text(download.total > 0
                             ? "\(ByteCountFormatter.string(fromByteCount: download.done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file))"
                             : "Preparing…").font(.caption).foregroundStyle(.secondary)
                    case .paused: Text("Paused at \(Int(download.fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                    case .failed(let why): Text(why).font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                }
            }
            Spacer(minLength: 0)
            if let download, download.state == .active || download.state == .queued {
                Button { gog.pause(game.id) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                    .buttonStyle(.plain).accessibilityLabel("Pause download")
            } else {
                Button { gog.install(game.id) } label: { Text(download == nil ? "Get" : "Resume").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { StorePageRouter.shared.page = StorePageID(value: "gog:\(game.id)") }
    }
}
