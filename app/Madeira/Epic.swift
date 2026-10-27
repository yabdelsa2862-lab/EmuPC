// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CryptoKit
import Foundation
import Security
import SwiftUI
import AuthenticationServices
import WebKit
import zlib

// MABD local: Epic Games Store games, downloaded straight from Epic.
//
// Follows the open-source Legendary client (legendary.gl): Epic's sign-in page
// redirects to /id/api/redirect, whose JSON carries an authorization code; that
// is exchanged (the Epic Games Launcher's client credentials) for tokens kept in
// the Keychain. The library is the account's Windows assets, named from the
// catalog. A download reads the build's binary manifest (header, then a zlib
// body: metadata, chunk list, file list, custom fields, and an encrypted part on
// newer builds, opened with AES-GCM keys Epic sends with the manifest), then
// fetches each ~1 MB chunk from Epic's CDN and writes its parts into the files
// under C:\Epic Games\<folder>. Epic games expect the launcher's sign-in on the
// command line, so every start asks Epic for a one-time exchange code (and an
// ownership token for games that need one) and adds Legendary's -AUTH_* / -epic*
// arguments. Log tag: [epic].

enum EpicAPI {
    static let clientID = "34a02cf8f4414e29b15921876da36f9a"
    static let clientSecret = "daafbccc737745039dffe53d94fc76cf"
    static let oauth = "https://account-public-service-prod03.ol.epicgames.com"
    static let launcher = "https://launcher-public-service-prod06.ol.epicgames.com"
    static let catalog = "https://catalog-public-service-prod06.ol.epicgames.com"
    static let ecommerce = "https://ecommerceintegration-public-service-ecomprod02.ol.epicgames.com"

    static var loginURL: URL {
        let redirect = "https://www.epicgames.com/id/api/redirect?clientId=\(clientID)&responseType=code"
        let encoded = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? redirect
        return URL(string: "https://www.epicgames.com/id/login?redirectUrl=\(encoded)")!
    }
}

enum EpicError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

// MARK: - Tokens

struct EpicTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var accountID: String
    var displayName: String
    var expires: Date
}

enum EpicTokenStore {
    private static let service = "madeira.epic.tokens"

    static func load() -> EpicTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "epic", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(EpicTokens.self, from: data)
    }

    static func save(_ tokens: EpicTokens) {
        clear()
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "epic", kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "epic"]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Library

struct EpicGame: Codable, Identifiable, Equatable {
    var id: String { appName }
    let appName: String
    let namespace: String
    let catalogItemID: String
    var title: String
    var tallImage: String?
    var wideImage: String?
    var folderName: String?
    var requiresOwnershipToken: Bool?

    /// Epic's image server resizes on request: a list needs ~40 KB, not the 1 MB original.
    static func sized(_ url: String?, width: Int, height: Int) -> URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url + (url.contains("?") ? "&" : "?") + "w=\(width)&h=\(height)&resize=1&quality=medium")
    }
    var poster: URL? { Self.sized(tallImage ?? wideImage, width: 360, height: 480) }
    var banner: URL? { Self.sized(wideImage ?? tallImage, width: 960, height: 540) }
}

/// Arguments for the next start of an Epic game, read by LibraryEntry.programArguments.
enum EpicLaunch {
    nonisolated(unsafe) static var pending: [UUID: String] = [:]
}

@MainActor
final class EpicLibrary: ObservableObject {
    static let shared = EpicLibrary()

    @Published private(set) var signedIn = EpicTokenStore.load() != nil
    @Published private(set) var owned: [EpicGame] = []
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
    @Published private(set) var downloads: [String: Download] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Download and installed size per game, read from its manifest once.
    @Published private(set) var sizes: [String: StoreSize] = StoreSize.load("epic-sizes.json")
    private var sizing = Set<String>()

    func requestSize(_ appName: String) {
        guard sizes[appName] == nil, !sizing.contains(appName), let game = owned.first(where: { $0.appName == appName }) else { return }
        sizing.insert(appName)
        Task {
            defer { sizing.remove(appName) }
            guard let token = try? await tokens().accessToken,
                  let (manifest, _, _) = try? await EpicInstaller.manifest(game, token: token) else { return }
            let download = manifest.chunks.values.reduce(Int64(0)) { $0 + $1.fileSize }
            let disk = manifest.files.reduce(Int64(0)) { $0 + $1.size }
            sizes[appName] = StoreSize(download: download, disk: disk)
            StoreSize.save(sizes, "epic-sizes.json")
        }
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("epic-library.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cached = try? JSONDecoder().decode([EpicGame].self, from: data) {
            owned = cached
        }
    }

    var notInstalled: [EpicGame] {
        let installed = Set(LibraryModel.shared.entries.compactMap(\.epicApp))
        return owned.filter { !installed.contains($0.appName) }
    }

    // MARK: Sign-in

    private static func requestTokens(_ form: [String: String]) async throws -> EpicTokens {
        var request = URLRequest(url: URL(string: EpicAPI.oauth + "/account/api/oauth/token")!)
        request.httpMethod = "POST"
        let basic = Data("\(EpicAPI.clientID):\(EpicAPI.clientSecret)".utf8).base64EncodedString()
        request.setValue("basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["errorMessage"] as? String
            throw EpicError.message(message ?? "Epic did not accept the sign-in.")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 7200
        return EpicTokens(accessToken: access, refreshToken: refresh,
                          accountID: json["account_id"] as? String ?? "",
                          displayName: json["displayName"] as? String ?? "",
                          expires: Date().addingTimeInterval(expiresIn - 300))
    }

    func finishSignIn(code: String) async {
        do {
            let tokens = try await Self.requestTokens(["grant_type": "authorization_code", "code": code, "token_type": "eg1"])
            EpicTokenStore.save(tokens)
            signedIn = true
            LogStore.shared.log("[epic] signed in as \(tokens.displayName)")
            await refresh()
        } catch {
            self.error = "Epic sign-in failed: \(error.localizedDescription)"
            LogStore.shared.log("[epic] sign-in failed: \(error.localizedDescription)", level: .error)
        }
    }

    func signOut() {
        EpicTokenStore.clear()
        signedIn = false
        owned = []
        try? FileManager.default.removeItem(at: Self.cacheURL)
        LogStore.shared.log("[epic] signed out")
    }

    func tokens() async throws -> EpicTokens {
        guard var tokens = EpicTokenStore.load() else { signedIn = false; throw EpicError.message("Sign in to Epic first.") }
        if tokens.expires < Date() {
            do {
                let fresh = try await Self.requestTokens(["grant_type": "refresh_token", "refresh_token": tokens.refreshToken, "token_type": "eg1"])
                tokens = EpicTokens(accessToken: fresh.accessToken, refreshToken: fresh.refreshToken,
                                    accountID: fresh.accountID.isEmpty ? tokens.accountID : fresh.accountID,
                                    displayName: fresh.displayName.isEmpty ? tokens.displayName : fresh.displayName,
                                    expires: fresh.expires)
                EpicTokenStore.save(tokens)
            } catch {
                signedIn = false
                EpicTokenStore.clear()
                throw EpicError.message("Your Epic sign-in expired. Sign in again.")
            }
        }
        return tokens
    }

    static func get(_ url: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EpicError.message("Epic answered \(http.statusCode).")
        }
        return data
    }

    // MARK: Owned games

    func refresh() async {
        guard signedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let token = try await tokens().accessToken
            let assetsData = try await Self.get(EpicAPI.launcher + "/launcher/api/public/assets/Windows?label=Live", token: token)
            guard let assets = try JSONSerialization.jsonObject(with: assetsData) as? [[String: Any]] else {
                throw EpicError.message("Epic did not return your games.")
            }
            var games: [EpicGame] = []
            var seen = Set<String>()
            for asset in assets {
                guard let app = asset["appName"] as? String, let ns = asset["namespace"] as? String,
                      let item = asset["catalogItemId"] as? String, ns != "ue", !seen.contains(app) else { continue }
                seen.insert(app)
                let infoURL = EpicAPI.catalog + "/catalog/api/shared/namespace/\(ns)/bulk/items?id=\(item)&includeDLCDetails=true&includeMainGameDetails=true&country=US&locale=en"
                guard let infoData = try? await Self.get(infoURL, token: token),
                      let info = (try? JSONSerialization.jsonObject(with: infoData) as? [String: Any])?[item] as? [String: Any] else { continue }
                // DLC lists its main game; leave it out.
                if info["mainGameItem"] != nil { continue }
                let title = info["title"] as? String ?? app
                let images = info["keyImages"] as? [[String: Any]] ?? []
                func image(_ type: String) -> String? { images.first { ($0["type"] as? String) == type }?["url"] as? String }
                let attributes = info["customAttributes"] as? [String: Any] ?? [:]
                func attribute(_ key: String) -> String? { (attributes[key] as? [String: Any])?["value"] as? String }
                games.append(EpicGame(appName: app, namespace: ns, catalogItemID: item, title: title,
                                      tallImage: image("DieselGameBoxTall") ?? image("Thumbnail"),
                                      wideImage: image("DieselGameBox") ?? image("OfferImageWide"),
                                      folderName: attribute("FolderName"),
                                      requiresOwnershipToken: attribute("OwnershipToken") == "true"))
            }
            games.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            owned = games
            if let data = try? JSONEncoder().encode(games) { try? data.write(to: Self.cacheURL, options: .atomic) }
            LogStore.shared.log("[epic] library: \(assets.count) assets, \(games.count) games")
        } catch {
            self.error = "Could not load your Epic library: \(error.localizedDescription)"
            LogStore.shared.log("[epic] library failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: Downloads

    func install(_ appName: String) {
        guard let game = owned.first(where: { $0.appName == appName }), tasks[appName] == nil else { return }
        downloads[appName] = Download(state: .active)
        let external = GameImporter.shared.toExternal && ExternalDrive.shared.root != nil
        tasks[appName] = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.tokens().accessToken
                let result = try await EpicInstaller(game: game, token: token, external: external) { done, total, speed in
                    Task { @MainActor in
                        guard var d = self.downloads[appName], d.state == .active else { return }
                        d.done = done; d.total = total; d.bytesPerSecond = speed
                        self.downloads[appName] = d
                    }
                }.run()
                self.addToLibrary(game, result)
                self.downloads[appName] = nil
                LogStore.shared.log("[epic] installed \(game.title) -> \(result.program.lastPathComponent)")
            } catch {
                if Task.isCancelled || error is CancellationError { self.downloads[appName]?.state = .paused }
                else {
                    self.downloads[appName]?.state = .failed(error.localizedDescription)
                    LogStore.shared.log("[epic] \(game.title) failed: \(error.localizedDescription)", level: .error)
                }
            }
            self.tasks[appName] = nil
        }
    }

    func pause(_ appName: String) {
        tasks[appName]?.cancel()
        downloads[appName]?.state = .paused
    }

    private func addToLibrary(_ game: EpicGame, _ result: EpicInstaller.Result) {
        let model = LibraryModel.shared
        var entry = (try? LibraryModel.inspect(result.program)) ?? LibraryEntry(title: game.title, relativePath: "", bits: 0)
        if entry.relativePath.isEmpty, let relative = LibraryModel.relativeToDrive(result.program) { entry.relativePath = relative }
        if let existing = model.entries.first(where: { $0.epicApp == game.appName }) { entry.id = existing.id }
        entry.title = game.title
        entry.epicApp = game.appName
        entry.arguments = result.arguments
        entry.folderBytes = result.bytes
        if let cover = result.cover { entry.coverFile = cover }
        model.save(entry)
    }

    // MARK: Launch

    /// The launcher's sign-in for one start: an exchange code, and an ownership
    /// token file for games that check one. Stored for programArguments.
    func prepareLaunch(_ entry: LibraryEntry) async -> Bool {
        guard let app = entry.epicApp else { return true }
        do {
            let t = try await tokens()
            let exchange = try await Self.get(EpicAPI.oauth + "/account/api/oauth/exchange", token: t.accessToken)
            guard let code = (try JSONSerialization.jsonObject(with: exchange) as? [String: Any])?["code"] as? String else {
                throw EpicError.message("Epic did not give a sign-in code for the game.")
            }
            let game = owned.first { $0.appName == app }
            var args = ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=\(code)", "-AUTH_TYPE=exchangecode",
                        "-epicapp=\(app)", "-epicenv=Prod", "-EpicPortal",
                        "-epicusername=\"\(t.displayName)\"", "-epicuserid=\(t.accountID)", "-epiclocale=en-US"]
            if let ns = game?.namespace { args.append("-epicsandboxid=\(ns)") }
            if let game, game.requiresOwnershipToken == true {
                var request = URLRequest(url: URL(string: EpicAPI.ecommerce + "/ecommerceintegration/api/public/platforms/EPIC/identities/\(t.accountID)/ownershipToken")!)
                request.httpMethod = "POST"
                request.setValue("bearer \(t.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = "nsCatalogItemId=\(game.namespace):\(game.catalogItemID)".data(using: .utf8)
                let (ovt, _) = try await URLSession.shared.data(for: request)
                let dir = LibraryModel.drive.appendingPathComponent("users/Public/Epic", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = "\(game.namespace)\(game.catalogItemID).ovt"
                try ovt.write(to: dir.appendingPathComponent(name), options: .atomic)
                args.append("-epicovt=C:\\users\\Public\\Epic\\\(name)")
            }
            EpicLaunch.pending[entry.id] = args.joined(separator: " ")
            LogStore.shared.log("[epic] launch sign-in ready for \(app)\(game?.requiresOwnershipToken == true ? " with ownership token" : "")")
            return true
        } catch {
            LogStore.shared.log("[epic] launch sign-in failed: \(error.localizedDescription) — starting offline", level: .error)
            EpicLaunch.pending[entry.id] = ""
            return true
        }
    }
}

// MARK: - Binary reader

private struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) { self.data = data; self.offset = offset }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.count else { throw EpicError.message("The game's manifest is cut short.") }
        defer { offset += n }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
    }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func u64() throws -> UInt64 { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian }
    mutating func guid() throws -> [UInt32] { [try u32(), try u32(), try u32(), try u32()] }
    mutating func fstring() throws -> String {
        let length = try i32()
        if length < 0 {
            let raw = try bytes(Int(-length) * 2)
            return String(data: raw.dropLast(2), encoding: .utf16LittleEndian) ?? ""
        } else if length > 0 {
            let raw = try bytes(Int(length))
            return String(data: raw.dropLast(1), encoding: .isoLatin1) ?? ""
        }
        return ""
    }
}

private func inflateZlib(_ data: Data, expected: Int) throws -> Data {
    var output = Data(count: max(expected, 1))
    var destLen = uLongf(output.count)
    let status = output.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            uncompress(out.bindMemory(to: Bytef.self).baseAddress, &destLen,
                       input.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
        }
    }
    guard status == Z_OK else { throw EpicError.message("Could not unpack Epic data (\(status)).") }
    output.count = Int(destLen)
    return output
}

private func aesGCM(_ ciphertext: Data, keyHex: String, nonce: Data, tag: Data) throws -> Data {
    var key = Data()
    var i = keyHex.startIndex
    while i < keyHex.endIndex {
        let j = keyHex.index(i, offsetBy: 2, limitedBy: keyHex.endIndex) ?? keyHex.endIndex
        guard let b = UInt8(keyHex[i..<j], radix: 16) else { throw EpicError.message("Bad key from Epic.") }
        key.append(b); i = j
    }
    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
    return try AES.GCM.open(box, using: SymmetricKey(data: key))
}

private func guidKey(_ g: [UInt32]) -> String { g.map { String(format: "%08X", $0) }.joined() }

// MARK: - Manifest

struct EpicManifest {
    struct Chunk {
        let guid: [UInt32]
        let hash: UInt64
        let group: UInt8
        let fileSize: Int64
        var secretGUID: [UInt32]?
        var path: String
    }
    struct Part { let guid: [UInt32]; let offset: UInt32; let size: UInt32 }
    struct File { var name: String; let sha1: Data; let parts: [Part]; var size: Int64 { parts.reduce(0) { $0 + Int64($1.size) } } }

    var featureLevel: UInt32 = 0
    var launchExe = ""
    var launchCommand = ""
    var chunks: [String: Chunk] = [:]
    var files: [File] = []

    static func parse(_ raw: Data, secrets: [String: String]) throws -> EpicManifest {
        var header = ByteReader(raw)
        guard try header.u32() == 0x44BEC00C else {
            throw EpicError.message("This game uses an older Epic manifest that EmuPC can't read yet.")
        }
        let headerSize = Int(try header.u32())
        let sizeUncompressed = Int(try header.u32())
        _ = try header.u32()
        _ = try header.bytes(20)
        let storedAs = try header.u8()
        let version = try header.u32()
        var manifestSecret: [UInt32]?
        var manifestTag = Data()
        if version >= 22 { manifestSecret = try header.guid(); manifestTag = try header.bytes(16) }
        let bodyRaw = raw.subdata(in: (raw.startIndex + headerSize)..<raw.endIndex)
        let body = storedAs & 1 != 0 ? try inflateZlib(bodyRaw, expected: sizeUncompressed) : bodyRaw
        var r = ByteReader(body)
        var m = EpicManifest()

        // Metadata
        let metaStart = r.offset
        let metaSize = Int(try r.u32())
        let dataVersion = try r.u8()
        m.featureLevel = try r.u32()
        _ = try r.u8(); _ = try r.u32()
        _ = try r.fstring(); _ = try r.fstring()
        m.launchExe = try r.fstring()
        m.launchCommand = try r.fstring()
        let prereqs = try r.u32()
        for _ in 0..<prereqs { _ = try r.fstring() }
        _ = try r.fstring(); _ = try r.fstring(); _ = try r.fstring()
        if dataVersion >= 1 { _ = try r.fstring() }
        if dataVersion >= 2 { _ = try r.fstring(); _ = try r.fstring() }
        r.offset = metaStart + metaSize

        // Chunk data list
        let cdlStart = r.offset
        let cdlSize = Int(try r.u32())
        _ = try r.u8()
        let count = Int(try r.u32())
        var guids: [[UInt32]] = [], hashes: [UInt64] = [], groups: [UInt8] = [], sizes: [Int64] = []
        for _ in 0..<count { guids.append(try r.guid()) }
        for _ in 0..<count { hashes.append(try r.u64()) }
        for _ in 0..<count { _ = try r.bytes(20) }
        for _ in 0..<count { groups.append(try r.u8()) }
        for _ in 0..<count { _ = try r.u32() }
        for _ in 0..<count { sizes.append(Int64(bitPattern: try r.u64())) }
        var chunkSecrets: [[UInt32]] = []
        if m.featureLevel >= 22 {
            for _ in 0..<count { chunkSecrets.append(try r.guid()) }
            for _ in 0..<count { _ = try r.u32() }
            for _ in 0..<count { _ = try r.bytes(16) }
        }
        r.offset = cdlStart + cdlSize
        let dir: String
        switch m.featureLevel {
        case 22...: dir = "ChunksV5"
        case 15...: dir = "ChunksV4"
        case 6...: dir = "ChunksV3"
        case 3...: dir = "ChunksV2"
        default: dir = "Chunks"
        }
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        func packed(_ g: [UInt32]) -> Data { var d = Data(); for v in g { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }; return d }
        for i in 0..<count {
            let path: String
            if m.featureLevel >= 22 {
                let secret = chunkSecrets.indices.contains(i) ? chunkSecrets[i] : [0, 0, 0, 0]
                let secretPart = secret == [0, 0, 0, 0] ? "plain" : b64(packed(secret))
                var h = hashes[i].littleEndian
                let hashData = Data(bytes: &h, count: 8)
                path = "\(dir)/\(secretPart)/\(String(format: "%02d", groups[i]))/\(b64(hashData))_\(b64(packed(guids[i]))).chunk"
            } else {
                path = "\(dir)/\(String(format: "%02d", groups[i]))/\(String(format: "%016llX", hashes[i]))_\(guidKey(guids[i])).chunk"
            }
            m.chunks[guidKey(guids[i])] = Chunk(guid: guids[i], hash: hashes[i], group: groups[i], fileSize: sizes[i],
                                                secretGUID: chunkSecrets.indices.contains(i) ? chunkSecrets[i] : nil, path: path)
        }

        // File manifest list
        let fmlStart = r.offset
        let fmlSize = Int(try r.u32())
        _ = try r.u8()
        let fileCount = Int(try r.u32())
        var names: [String] = [], shas: [Data] = [], parts: [[Part]] = []
        for _ in 0..<fileCount { names.append(try r.fstring()) }
        for _ in 0..<fileCount { _ = try r.fstring() }
        for _ in 0..<fileCount { shas.append(try r.bytes(20)) }
        for _ in 0..<fileCount { _ = try r.u8() }
        for _ in 0..<fileCount { let tags = try r.u32(); for _ in 0..<tags { _ = try r.fstring() } }
        for _ in 0..<fileCount {
            let n = try r.u32()
            var list: [Part] = []
            for _ in 0..<n {
                let start = r.offset
                let partSize = Int(try r.u32())
                let g = try r.guid()
                let off = try r.u32()
                let size = try r.u32()
                list.append(Part(guid: g, offset: off, size: size))
                r.offset = start + max(partSize, 28)
            }
            parts.append(list)
        }
        r.offset = fmlStart + fmlSize
        m.files = (0..<fileCount).map { File(name: names[$0], sha1: shas[$0], parts: parts[$0]) }

        // Custom fields, then (feature level 24+) the encrypted part.
        let cfStart = r.offset
        if r.offset + 4 <= body.count {
            let cfSize = Int(try r.u32())
            r.offset = cfStart + cfSize
        }
        if storedAs & 2 != 0 {
            guard let secret = manifestSecret, let key = secrets[guidKey(secret)] else {
                throw EpicError.message("Epic sent this game's files locked, without the key.")
            }
            let edStart = r.offset
            let edSize = Int(try r.u32())
            _ = try r.u8()
            let cipherSize = Int(try r.u32())
            var block = ByteReader(try r.bytes(cipherSize))
            let hStart = block.offset
            let hSize = Int(try block.u32())
            _ = try block.u32()
            let hStored = try block.u8()
            let plainSize = Int(try block.u32())
            _ = try block.u32()
            let ivLength = Int(try block.u32())
            let iv = try block.bytes(ivLength)
            block.offset = hStart + hSize
            let cipherLength = Int(try block.u32())
            let cipher = try block.bytes(cipherLength)
            r.offset = edStart + edSize
            var plain = try aesGCM(cipher, keyHex: key, nonce: iv, tag: manifestTag)
            if hStored & 1 != 0 { plain = try inflateZlib(plain, expected: plainSize) }
            var p = ByteReader(plain)
            m.launchExe = try p.fstring()
            m.launchCommand = try p.fstring()
            let prereqCount = try p.u32()
            for _ in 0..<prereqCount { _ = try p.fstring() }
            for _ in 0..<5 { _ = try p.fstring() }
            for i in m.files.indices {
                m.files[i].name = try p.fstring()
                _ = try p.fstring()
            }
        }
        return m
    }
}

// MARK: - Installer

struct EpicInstaller {
    let game: EpicGame
    let token: String
    let external: Bool
    let progress: @Sendable (Int64, Int64, Double) -> Void

    struct Result {
        var program: URL
        var arguments: String
        var bytes: Int64
        var cover: String?
    }

    func run() async throws -> Result {
        let (manifest, baseURLs, secrets) = try await Self.manifest(game, token: token)
        return try await install(manifest, baseURLs: baseURLs, secrets: secrets)
    }

    /// The live build's manifest, the CDN bases and the keys for this game.
    static func manifest(_ game: EpicGame, token: String) async throws -> (EpicManifest, [String], [String: String]) {
        let assetURL = EpicAPI.launcher + "/launcher/api/public/assets/v2/platform/Windows/namespace/\(game.namespace)/catalogItem/\(game.catalogItemID)/app/\(game.appName)/label/Live"
        let api = try JSONSerialization.jsonObject(with: try await EpicLibrary.get(assetURL, token: token)) as? [String: Any]
        guard let element = (api?["elements"] as? [[String: Any]])?.first,
              let manifests = element["manifests"] as? [[String: Any]], !manifests.isEmpty else {
            throw EpicError.message("Epic has no Windows download for this game.")
        }
        let secrets = element["secrets"] as? [String: String] ?? [:]
        var baseURLs: [String] = []
        var manifestData: Data?
        for entry in manifests {
            guard let uri = entry["uri"] as? String else { continue }
            let base = String(uri[..<(uri.lastIndex(of: "/") ?? uri.endIndex)])
            if !baseURLs.contains(base) { baseURLs.append(base) }
            if manifestData == nil {
                var url = uri
                if let params = entry["queryParams"] as? [[String: Any]], !params.isEmpty {
                    url += "?" + params.compactMap { p in (p["name"] as? String).map { "\($0)=\(p["value"] as? String ?? "")" } }.joined(separator: "&")
                }
                if let u = URL(string: url), let (data, response) = try? await URLSession.shared.data(from: u),
                   (response as? HTTPURLResponse)?.statusCode == 200 { manifestData = data }
            }
        }
        guard let manifestData else { throw EpicError.message("Could not download the game's file list from Epic.") }
        return (try EpicManifest.parse(manifestData, secrets: secrets), baseURLs, secrets)
    }

    private func install(_ manifest: EpicManifest, baseURLs: [String], secrets: [String: String]) async throws -> Result {

        let folderName = GOGInstaller.safeName(game.folderName ?? game.title)
        let root = LibraryModel.drive.appendingPathComponent(external ? "External/Epic Games" : "Epic Games", isDirectory: true)
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let need = manifest.files.reduce(Int64(0)) { $0 + $1.size }
        if let free = ExternalDrive.freeBytes(atPath: root.path), Int64(free) < need {
            throw EpicError.message("Not enough space: \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) needed.")
        }
        LogStore.shared.log("[epic] \(game.title): feature level \(manifest.featureLevel), \(manifest.files.count) files, \(manifest.chunks.count) chunks, \(need >> 20)MB -> \(folder.path)")

        // Download size: every chunk once (refetches after eviction are not counted).
        let total = manifest.chunks.values.reduce(Int64(0)) { $0 + $1.fileSize }
        let counter = GOGProgress(total: total, report: progress)
        let cache = EpicChunkCache(baseURLs: baseURLs, secrets: secrets, manifest: manifest, counter: counter)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            for file in manifest.files {
                if running >= 4 { try await group.next(); running -= 1 }
                running += 1
                group.addTask {
                    try Task.checkCancellation()
                    let target = folder.appendingPathComponent(GOGInstaller.localPath(file.name))
                    guard target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                        throw EpicError.message("Epic listed a file outside the game folder.")
                    }
                    let fm = FileManager.default
                    if let attrs = try? fm.attributesOfItem(atPath: target.path), (attrs[.size] as? NSNumber)?.int64Value == file.size {
                        await cache.skip(file)
                        return
                    }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let partial = target.appendingPathExtension("madeira-part")
                    fm.createFile(atPath: partial.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: partial)
                    var sha = Insecure.SHA1()
                    for part in file.parts {
                        try Task.checkCancellation()
                        let data = try await cache.chunk(part.guid)
                        let start = Int(part.offset), end = start + Int(part.size)
                        guard end <= data.count else { try? handle.close(); throw EpicError.message("A downloaded piece was too short.") }
                        let slice = data.subdata(in: start..<end)
                        sha.update(data: slice)
                        try handle.write(contentsOf: slice)
                        await cache.used(part.guid)
                    }
                    try handle.close()
                    guard Data(sha.finalize()) == file.sha1 else {
                        try? fm.removeItem(at: partial)
                        throw EpicError.message("\(target.lastPathComponent) was damaged while downloading. Try again.")
                    }
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.moveItem(at: partial, to: target)
                }
            }
            try await group.waitForAll()
        }

        let program = folder.appendingPathComponent(GOGInstaller.localPath(manifest.launchExe))
        guard !manifest.launchExe.isEmpty, FileManager.default.fileExists(atPath: program.path) else {
            throw EpicError.message("Installed, but Epic names no program to start for this game.")
        }
        var cover: String?
        if let url = EpicGame.sized(game.tallImage, width: 600, height: 800), let (data, _) = try? await URLSession.shared.data(from: url), data.count > 1000 {
            let dir = LibraryModel.documents.appendingPathComponent("madeira-art", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "epic-\(game.appName).jpg"
            if (try? data.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil { cover = name }
        }
        return Result(program: program, arguments: manifest.launchCommand, bytes: need, cover: cover)
    }
}

/// Downloaded chunks, kept while files still need them (up to ~96 MB), else fetched again.
actor EpicChunkCache {
    private let baseURLs: [String]
    private let secrets: [String: String]
    private let manifest: EpicManifest
    private let counter: GOGProgress
    private var remaining: [String: Int] = [:]
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var counted = Set<String>()
    private var inflight: [String: Task<Data, Error>] = [:]

    init(baseURLs: [String], secrets: [String: String], manifest: EpicManifest, counter: GOGProgress) {
        self.baseURLs = baseURLs
        self.secrets = secrets
        self.manifest = manifest
        self.counter = counter
        for file in manifest.files { for part in file.parts { remaining[guidKey(part.guid), default: 0] += 1 } }
    }

    func skip(_ file: EpicManifest.File) async {
        for part in file.parts { await usedKey(guidKey(part.guid), countIfNew: true) }
    }

    func used(_ guid: [UInt32]) async { await usedKey(guidKey(guid), countIfNew: false) }

    private func usedKey(_ key: String, countIfNew: Bool) async {
        if countIfNew, !counted.contains(key) {
            counted.insert(key)
            await counter.add(manifest.chunks[key]?.fileSize ?? 0)
        }
        remaining[key, default: 1] -= 1
        if remaining[key, default: 0] <= 0 { cache[key] = nil; order.removeAll { $0 == key } }
    }

    func chunk(_ guid: [UInt32]) async throws -> Data {
        let key = guidKey(guid)
        if let data = cache[key] { return data }
        if let task = inflight[key] { return try await task.value }
        guard let info = manifest.chunks[key] else { throw EpicError.message("A file needs a piece Epic doesn't list.") }
        let bases = baseURLs, secrets = self.secrets
        let task = Task { try await Self.fetch(info, bases: bases, secrets: secrets) }
        inflight[key] = task
        defer { inflight[key] = nil }
        let data = try await task.value
        if !counted.contains(key) { counted.insert(key); await counter.add(info.fileSize) }
        cache[key] = data
        order.append(key)
        while order.count > 96, let oldest = order.first { order.removeFirst(); cache[oldest] = nil }
        return data
    }

    private static func fetch(_ info: EpicManifest.Chunk, bases: [String], secrets: [String: String]) async throws -> Data {
        var lastError: Error = EpicError.message("Could not download a piece of the game.")
        for attempt in 0..<4 {
            let base = bases[attempt % max(bases.count, 1)]
            guard let url = URL(string: base + "/" + info.path) else { continue }
            do {
                let (raw, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EpicError.message("Epic's server refused a piece of the game.") }
                return try decode(raw, secrets: secrets)
            } catch {
                if error is CancellationError { throw error }
                lastError = error
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw lastError
    }

    /// A chunk file: header, then the data (encrypted with AES-GCM and/or zlib-compressed).
    private static func decode(_ raw: Data, secrets: [String: String]) throws -> Data {
        var r = ByteReader(raw)
        guard try r.u32() == 0xB1FE3AA2 else { throw EpicError.message("A piece of the game came back damaged.") }
        let headerVersion = try r.u32()
        let headerSize = Int(try r.u32())
        _ = try r.u32()
        _ = try r.guid()
        _ = try r.u64()
        let storedAs = try r.u8()
        var sha = Data()
        var uncompressed = 1024 * 1024
        var secretGUID: [UInt32]?
        var tag = Data()
        if headerVersion >= 2 { sha = try r.bytes(20); _ = try r.u8() }
        if headerVersion >= 3 { uncompressed = Int(try r.u32()) }
        if headerVersion >= 4 { secretGUID = try r.guid(); tag = try r.bytes(16) }
        var data = raw.subdata(in: (raw.startIndex + headerSize)..<raw.endIndex)
        if storedAs & 2 != 0 {
            guard let secretGUID, let key = secrets[guidKey(secretGUID)], sha.count >= 12 else {
                throw EpicError.message("A piece of the game is locked without its key.")
            }
            data = try aesGCM(data, keyHex: key, nonce: sha.prefix(12), tag: tag)
        }
        if storedAs & 1 != 0 { data = try inflateZlib(data, expected: uncompressed) }
        return data
    }
}

// MARK: - Sign-in sheet

struct EpicSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var finishing = false
    /// Safari sign-in (passkeys): the code Epic shows, pasted back here.
    @State private var pasteMode = false
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            ZStack {
                if pasteMode { pasteForm } else {
                    EpicWebView { code in finish(code) }
                }
                if finishing { ProgressView("Signing in…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .navigationTitle("Sign in to Epic Games").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { SignInWebContainer.end("epic"); dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if !pasteMode {
                    Button { Task { await safariSignIn() } } label: {
                        Label("Use a passkey: sign in with Safari", systemImage: "person.badge.key.fill")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
    }

    private var pasteForm: some View {
        Form {
            Section {
                TextField("Paste the code", text: $pasted, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: pasted) { _, text in if let code = Self.code(in: text) { finish(code) } }
                PasteButton(payloadType: String.self) { items in
                    if let text = items.first { pasted = text }
                }
            } header: { Text("Your Epic code") } footer: {
                Text("After you signed in, Epic showed a short page of text with \"authorizationCode\". Copy that whole page (or just the code) and paste it here. The code works once and only for a few minutes.")
            }
            Section {
                Button("Open Safari sign-in again") { Task { await safariSignIn() } }
            }
        }
    }

    /// Apple's sign-in window (Safari, with passkeys and saved passwords). Epic
    /// ends on its redirect page, which this app cannot read, so the window is
    /// closed by hand and the code pasted.
    private func safariSignIn() async {
        _ = try? await webAuth.authenticate(using: EpicAPI.loginURL, callbackURLScheme: "madeira-epic",
                                            preferredBrowserSession: .shared)
        pasteMode = true
    }

    private func finish(_ code: String) {
        guard !finishing else { return }
        finishing = true
        Task {
            await EpicLibrary.shared.finishSignIn(code: code)
            SignInWebContainer.end("epic")
            dismiss()
        }
    }

    /// The authorization code from Epic's redirect JSON, or a bare 32-character code.
    static func code(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["authorizationCode"] as? String, !code.isEmpty { return code }
        if let range = trimmed.range(of: #"(?<="authorizationCode"\s?:\s?")[0-9a-fA-F]{32}"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        if trimmed.range(of: #"^[0-9a-fA-F]{32}$"#, options: .regularExpression) != nil { return trimmed }
        return nil
    }
}

private struct EpicWebView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> SignInWebContainer {
        let view = SignInWebContainer.page("epic", start: EpicAPI.loginURL)
        // The redirect page is JSON with the authorization code.
        view.onFinish = { [weak view] web in
            guard let view, !view.done, let url = web.url, url.host?.hasSuffix("epicgames.com") == true, url.path.contains("/id/api/redirect") else { return }
            web.evaluateJavaScript("document.body.innerText") { result, _ in
                guard !view.done, let text = result as? String,
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let code = json["authorizationCode"] as? String, !code.isEmpty else { return }
                view.done = true
                onCode(code)
            }
        }
        return view
    }

    func updateUIView(_ uiView: SignInWebContainer, context: Context) {}
}

// MARK: - Download games section

struct EpicDownloadSection: View {
    let search: String
    @ObservedObject private var epic = EpicLibrary.shared
    @State private var signIn = false

    private var games: [EpicGame] {
        let list = epic.notInstalled
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Section {
            if !epic.signedIn {
                Button { signIn = true } label: {
                    Label("Sign in to Epic Games", systemImage: "person.crop.circle.badge.plus").fontWeight(.semibold)
                }
            } else if games.isEmpty {
                if epic.refreshing {
                    HStack { ProgressView(); Text("Loading your Epic library…").foregroundStyle(.secondary) }
                } else {
                    Text(search.isEmpty ? (epic.owned.isEmpty ? "Pull down to load your Epic library." : "Every Epic game you own is installed.")
                         : "No Epic games match \"\(search)\".").foregroundStyle(.secondary)
                }
            } else {
                ForEach(games) { game in row(game) }
            }
            if let error = epic.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Epic Games")
                Spacer()
                if epic.refreshing { ProgressView().controlSize(.mini) }
                if epic.signedIn {
                    Menu {
                        Button { Task { await epic.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { epic.signOut() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        } footer: {
            Text(epic.signedIn ? "Games download straight from Epic. Each start signs the game in to Epic for you. Games with anti-cheat in online modes won't play online. Keep EmuPC open while they download."
                               : "Sign in with your Epic account to download the games you own, free ones included.")
        }
        .sheet(isPresented: $signIn) { EpicSignInView() }
        .task { if epic.signedIn && epic.owned.isEmpty { await epic.refresh() } }
    }

    private func row(_ game: EpicGame) -> some View {
        let download = epic.downloads[game.appName]
        return HStack(spacing: 12) {
            AsyncImage(url: game.poster) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: 48, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.body.weight(.semibold)).lineLimit(2)
                if download == nil {
                    StoreSizeLine(size: epic.sizes[game.appName]).onAppear { epic.requestSize(game.appName) }
                    StoreCompatibility(epic: game)
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
                Button { epic.pause(game.appName) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                    .buttonStyle(.plain).accessibilityLabel("Pause download")
            } else {
                Button { epic.install(game.appName) } label: { Text(download == nil ? "Get" : "Resume").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { StorePageRouter.shared.page = StorePageID(value: "epic:\(game.appName)") }
    }
}
