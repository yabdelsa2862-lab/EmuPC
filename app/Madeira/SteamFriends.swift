// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import SwiftUI

// EmuPC: Steam Overlay (friends, game invites, and live lobby join).
//
// Valve's client runs headless inside a game session, so an invite a friend
// sends ("Invite to Game" / "Join Game" in Steam chat) has nowhere to show unless
// EmuPC provides its own Steam Overlay.
//
// SteamFriendsModel uses a dedicated companion chat SteamSession (`isChatSession = true`,
// with a distinct LoginID mask and Chat/Web UI mode) so it can stay online and receive
// real-time invites and friend lobby states BOTH while in the Library and while a Steam
// game is running inside Madeira Dock, without colliding with dockhost.exe's desktop
// Steamworks session.
//
// Joining works in two ways:
//   1. Cold start / restart: passes "+connect_lobby <lobby>" (or the friend's rich-presence
//      connect string) on the game's command line via SteamInvites.take AND queues the
//      Steamworks callback in C:\madeira\steam_join_cb.bin.
//   2. Live in-game join (when the target game is already running): writes
//      C:\madeira\steam_join_cb.bin, which tftrace-x64.dll's Steam_BGetCallback wrapper
//      delivers into the running game as GameLobbyJoinRequested_t (333) or
//      GameRichPresenceJoinRequested_t (337).
// Log tag: [steam-friends].

/// One friend, from their persona state.
struct SteamFriend: Identifiable, Equatable {
    let id: UInt64
    var name = ""
    /// EPersonaState: 0 offline, 1 online, 2 busy, 3 away, 4 snooze, 5 looking to trade, 6 looking to play.
    var state = 0
    var appID = 0
    var gameName = ""
    /// Field 14 (`steamid_source`) in CMsgClientPersonaState.Friend — holds the active
    /// Steam Matchmaking Lobby SteamID when the player is in a joinable lobby.
    var lobbyID: UInt64 = 0
    var gameServerIP: UInt32 = 0
    var gameServerPort: UInt32 = 0
    var richPresence: [String: String] = [:]

    var online: Bool { state != 0 }
    var inGame: Bool { appID != 0 || !gameName.isEmpty }

    /// The friend's active Matchmaking Lobby ID, from either `steamid_source` (field 14)
    /// or a `+connect_lobby <id>` rich-presence string.
    var joinableLobbyID: UInt64? {
        if lobbyID != 0, (lobbyID >> 52) != 0x011 {
            return lobbyID
        }
        if let c = richPresence["connect"],
           let r = c.range(of: #"\+connect_lobby\s+(\d+)"#, options: .regularExpression) {
            let digits = String(c[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let parsed = UInt64(digits), parsed != 0 { return parsed }
        }
        return nil
    }

    /// What a friend in a joinable game set for others to join with.
    var connect: String? {
        if let lobby = joinableLobbyID {
            return "+connect_lobby \(lobby)"
        }
        if let c = richPresence["connect"], !c.isEmpty {
            return c
        }
        if gameServerIP != 0, gameServerPort != 0 {
            let a = (gameServerIP >> 24) & 0xFF
            let b = (gameServerIP >> 16) & 0xFF
            let c = (gameServerIP >> 8) & 0xFF
            let d = gameServerIP & 0xFF
            return "+connect \(a).\(b).\(c).\(d):\(gameServerPort)"
        }
        return nil
    }

    /// Rich presence status subtitle if the game publishes one.
    var presenceDetail: String? {
        if let status = richPresence["status"], !status.isEmpty { return status }
        if let group = richPresence["steam_player_group_size"], !group.isEmpty, Int(group) ?? 0 > 1 {
            return "In party (\(group) players)"
        }
        if joinableLobbyID != nil { return "In joinable lobby" }
        return nil
    }
}

/// A game invite found in a chat or synthesized from a live joinable lobby.
struct SteamGameInvite: Identifiable, Equatable {
    let id: String
    let from: UInt64
    let time: Date
    var appID: Int?
    var lobbyID: UInt64?
    var connect: String?
    /// The command-line arguments that join it.
    var arguments: String? {
        if let lobbyID, lobbyID != 0 { return "+connect_lobby \(lobbyID)" }
        return connect
    }
}

/// Arguments and callback metadata for the next Dock start of a game: an accepted invite's.
@MainActor
enum SteamInvites {
    private static var pending: [Int: String] = [:]
    private static var pendingMeta: [Int: (friendID: UInt64, lobbyID: UInt64?)] = [:]
    private static let defaultsKey = "madeira.steam.pendingInvites.v1"
    private static let ttl: TimeInterval = 30 * 60

    static func set(_ arguments: String, for appID: Int, friendID: UInt64 = 0, lobbyID: UInt64? = nil) {
        pending[appID] = arguments
        let resolvedLobby = lobbyID ?? Self.extractLobbyID(from: arguments)
        pendingMeta[appID] = (friendID: friendID, lobbyID: resolvedLobby)
        saveToDefaults(appID: appID, arguments: arguments, friendID: friendID, lobbyID: resolvedLobby)
        SteamFriendsModel.clearJoinCallback()
    }

    /// Read once by the start that uses them. Cold launches already pass `+connect_lobby <id>`
    /// on the command line, so clear `C:\madeira\steam_join_cb.bin` to avoid a duplicate join.
    static func take(_ appID: Int) -> String? {
        SteamFriendsModel.clearJoinCallback()
        if let args = pending.removeValue(forKey: appID) {
            pendingMeta.removeValue(forKey: appID)
            clearFromDefaults(appID: appID)
            return args
        }
        if let stored = loadFromDefaults(appID: appID) {
            clearFromDefaults(appID: appID)
            return stored.arguments
        }
        return nil
    }

    static func extractLobbyID(from arguments: String) -> UInt64? {
        guard let r = arguments.range(of: #"\+connect_lobby\s+(\d+)"#, options: .regularExpression) else { return nil }
        let digits = String(arguments[r]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return UInt64(digits)
    }

    private static func saveToDefaults(appID: Int, arguments: String, friendID: UInt64, lobbyID: UInt64?) {
        var map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]]) ?? [:]
        map[String(appID)] = [
            "arguments": arguments,
            "friendID": String(friendID),
            "lobbyID": lobbyID.map(String.init) ?? "",
            "timestamp": Date().timeIntervalSince1970,
        ]
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    private static func loadFromDefaults(appID: Int) -> (arguments: String, friendID: UInt64, lobbyID: UInt64?)? {
        guard let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]],
              let entry = map[String(appID)],
              let args = entry["arguments"] as? String, !args.isEmpty,
              let ts = entry["timestamp"] as? Double,
              Date().timeIntervalSince1970 - ts <= ttl else { return nil }
        let friendID = (entry["friendID"] as? String).flatMap(UInt64.init) ?? 0
        let lobbyID = (entry["lobbyID"] as? String).flatMap(UInt64.init)
        return (args, friendID, lobbyID)
    }

    private static func clearFromDefaults(appID: Int) {
        guard var map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] else { return }
        map.removeValue(forKey: String(appID))
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}

@MainActor
final class SteamFriendsModel: ObservableObject {
    static let shared = SteamFriendsModel()

    @Published private(set) var friends: [UInt64: SteamFriend] = [:]
    @Published private(set) var invites: [SteamGameInvite] = []
    @Published private(set) var selfPersona: SteamFriend?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var updated: Date?

    /// Live toast invite banner shown when a new invite arrives.
    @Published var activeBannerInvite: SteamGameInvite?
    /// Feedback shown when a live callback was injected into the running game or an invite was sent.
    @Published var statusNotice: String?
    /// Most recent invite joined in-game, so the user can also opt to restart into the lobby if needed.
    @Published var lastInGameJoinedInvite: SteamGameInvite?

    /// Dedicated companion chat session so Friends & Invites stay online while a game runs.
    let chatSession: SteamSession = {
        let s = SteamSession()
        s.isChatSession = true
        s.customIdleTimeout = 600
        return s
    }()

    private var handlerInstalled = false
    private var seededSeenInvites = false
    private var seenInviteIDs: Set<String> = []
    private var bannerDismissTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private static let steamID64Base: UInt64 = 76561197960265728
    /// Invites older than this are left out.
    private static let inviteWindow: TimeInterval = 2 * 24 * 3600
    /// Invites newer than this on first poll are eligible to pop the toast banner.
    private static let freshBannerWindow: TimeInterval = 120

    var sortedFriends: [SteamFriend] {
        friends.values.sorted {
            let a = ($0.inGame && $0.connect != nil) ? 0 : $0.inGame ? 1 : $0.online ? 2 : 3
            let b = ($1.inGame && $1.connect != nil) ? 0 : $1.inGame ? 1 : $1.online ? 2 : 3
            return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Friends currently in a game with a joinable lobby or connect string.
    var joinableFriends: [SteamFriend] {
        sortedFriends.filter { $0.inGame && $0.connect != nil && $0.appID != 0 }
    }

    func name(_ id: UInt64) -> String { friends[id]?.name.isEmpty == false ? friends[id]!.name : "A friend" }

    // MARK: In-Game Background Monitoring

    /// Starts background polling and live notification listening while in the library.
    /// When a game session starts, disconnects the companion CM session so Madeira Dock's
    /// Steam client holds the account without competing for the refresh token.
    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if SteamOwnedLibrary.shared.gameSessionRunning || LibraryModel.shared.current != nil {
                    await self.chatSession.disconnectGracefully()
                } else if SteamSignIn.isSignedIn {
                    await self.refresh()
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: Refresh

    func refresh() async {
        guard SteamSignIn.isSignedIn else { error = "Sign in to Steam in Settings first."; return }
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        let session = chatSession
        do {
            try await session.ensureConnected()
            installHandler(session)
            await setPersonaOnline(session)
            let ids = try await friendIDs(session)
            for id in ids where friends[id] == nil { friends[id] = SteamFriend(id: id) }
            for id in Array(friends.keys) where !ids.contains(id) { friends[id] = nil }
            var requestIDs = ids
            if session.steamID != 0, !requestIDs.contains(session.steamID) {
                requestIDs.append(session.steamID)
            }
            try await requestPersonas(session, requestIDs)
            let fetchedInvites = try await recentInvites(session)
            mergeInvites(fetchedInvites)
            updated = Date()
            SteamLog.event("[steam-friends] friends=\(ids.count) invites=\(invites.count) joinable=\(joinableFriends.count)")
        } catch {
            self.error = "Steam did not answer: \(error.localizedDescription)"
            SteamLog.event("[steam-friends] refresh failed: \(error)")
        }
    }

    /// Announces Online persona status on the companion chat session so friends see us online
    /// and Steam CM pushes live friend state changes and incoming game invites.
    private func setPersonaOnline(_ session: SteamSession) async {
        var status = ProtobufEncoder()
        status.writeUInt32(fieldNumber: 1, value: 1) // persona_state = 1 (Online)
        status.writeBool(fieldNumber: 5, value: true) // persona_set_by_user = true
        try? await session.sendMessage(eMsg: .clientChangeStatus, body: status.data)
    }

    private func friendIDs(_ session: SteamSession) async throws -> [UInt64] {
        let body = try await session.callServiceMethod(method: .friendsListGet, body: Data(), timeout: 15)
        // CFriendsList_GetFriendsList_Response: 1 friendslist (CMsgClientFriendsList:
        // 2 friends { 1 ulfriendid fixed64, 2 efriendrelationship }).
        var ids: [UInt64] = []
        for list in Proto.messages(body, 1) {
            for friend in Proto.messages(list, 2) {
                let fields = Proto.fields(friend)
                guard let id = fields[1]?.first?.u64, fields[2]?.first?.u64 == 3 else { continue }   // 3 = friend
                // Individual accounts only (a group's ID has another universe/type).
                if id >> 52 == 0x011 { ids.append(id) }
            }
        }
        return ids
    }

    private func requestPersonas(_ session: SteamSession, _ ids: [UInt64]) async throws {
        guard !ids.isEmpty else { return }
        // CMsgClientRequestFriendData: 1 persona_state_requested:
        //   1 (Status) | 2 (PlayerName) | 4 (QueryPort) | 8 (SourceID / Lobby SteamID!) |
        //   16 (Presence) | 64 (LastSeen) | 256 (GameExtraInfo) | 512 (GameDataBlob) | 4096 (RichPresence)
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: 1 | 2 | 4 | 8 | 16 | 64 | 256 | 512 | 4096)
        for id in ids { request.writeFixed64(fieldNumber: 2, value: id) }
        try await session.sendMessage(eMsg: .clientRequestFriendData, body: request.data)
        // The answers arrive as pushes; give them a moment.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func installHandler(_ session: SteamSession) {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        session.registerHandler(for: .clientPersonaState) { [weak self] message in
            self?.applyPersonas(message.body)
        }
        session.registerHandler(for: .serviceMethodCallFromClient) { [weak self] message in
            self?.handleServiceNotification(message)
        }
        session.registerHandler(for: .clientFriendMsgIncoming) { [weak self] message in
            self?.handleLegacyFriendMessage(message.body)
        }
    }

    private func applyPersonas(_ body: Data) {
        // CMsgClientPersonaState: 2 friends { 1 friendid fixed64, 2 persona_state,
        // 3 game_played_app_id, 4 game_server_ip, 5 game_server_port, 14 steamid_source fixed64,
        // 15 player_name, 55 game_name, 56 gameid fixed64, 71 rich_presence { 1 key, 2 value } }.
        let myID = chatSession.steamID
        for entry in Proto.messages(body, 2) {
            let f = Proto.fields(entry)
            guard let id = f[1]?.first?.u64 else { continue }
            if id == myID, myID != 0 {
                var me = selfPersona ?? SteamFriend(id: id)
                populateFriend(&me, from: f)
                selfPersona = me
                continue
            }
            guard friends[id] != nil || id >> 52 == 0x011 else { continue }
            var friend = friends[id] ?? SteamFriend(id: id)
            populateFriend(&friend, from: f)
            friends[id] = friend

            // Backfill appID or lobbyID on any existing invites from this friend.
            if friend.appID != 0 {
                for idx in invites.indices where invites[idx].from == id {
                    if invites[idx].appID == nil || invites[idx].appID == 0 {
                        invites[idx].appID = friend.appID
                    }
                    if invites[idx].lobbyID == nil, let lobby = friend.joinableLobbyID {
                        invites[idx].lobbyID = lobby
                    }
                }
            }
        }
    }

    private func populateFriend(_ friend: inout SteamFriend, from f: [UInt32: [Proto.Value]]) {
        if let name = f[15]?.first?.string, !name.isEmpty { friend.name = name }
        if let state = f[2]?.first?.u64 { friend.state = Int(state) }
        if let app = f[3]?.first?.u64 { friend.appID = Int(app) }
        else if let gameID = f[56]?.first?.u64 { friend.appID = Int(gameID & 0xFFFFFF) }
        if let ip = f[4]?.first?.u64 { friend.gameServerIP = UInt32(truncatingIfNeeded: ip) }
        if let port = f[5]?.first?.u64 { friend.gameServerPort = UInt32(truncatingIfNeeded: port) }
        if let sourceID = f[14]?.first?.u64 { friend.lobbyID = sourceID }
        if let game = f[55]?.first?.string { friend.gameName = game }
        if let kvs = f[71] {
            var rp: [String: String] = [:]
            for kv in kvs {
                let k = Proto.fields(kv.bytes ?? Data())
                if let key = k[1]?.first?.string { rp[key] = k[2]?.first?.string ?? "" }
            }
            friend.richPresence = rp
        }
        if friend.state == 0 {
            friend.appID = 0
            friend.gameName = ""
            friend.lobbyID = 0
            friend.gameServerIP = 0
            friend.gameServerPort = 0
            friend.richPresence = [:]
        }
    }

    // MARK: Real-Time Incoming Invite Notifications

    private func handleServiceNotification(_ message: SteamMessageCodec.IncomingMessage) {
        let method = message.header.targetJobName
        guard method.isEmpty || method.contains("FriendMessagesClient.IncomingMessage") else { return }
        // CFriendMessages_IncomingMessage_Notification:
        // 1 steamid_friend (fixed64), 2 chat_entry_type, 4 message (string),
        // 5 rtime32_server_timestamp (fixed32), 6 ordinal (uint32), 7 local_echo (bool).
        let f = Proto.fields(message.body)
        if f[7]?.first?.u64 == 1 { return } // Ignore our own sent messages
        guard let from = f[1]?.first?.u64, from != chatSession.steamID,
              let text = f[4]?.first?.string, !text.isEmpty else { return }
        let stamp = f[5]?.first?.u64.map { Date(timeIntervalSince1970: Double($0)) } ?? Date()
        let ordinal = f[6]?.first?.u64 ?? 0
        ingestIncomingChat(text: text, from: from, time: stamp, ordinal: ordinal)
    }

    private func handleLegacyFriendMessage(_ body: Data) {
        // CMsgClientFriendMsgIncoming:
        // 1 steamid_from (fixed64), 2 chat_entry_type, 4 message (bytes), 5 rtime32_server_timestamp (fixed32)
        let f = Proto.fields(body)
        guard let from = f[1]?.first?.u64, from != chatSession.steamID,
              let text = f[4]?.first?.string, !text.isEmpty else { return }
        let stamp = f[5]?.first?.u64.map { Date(timeIntervalSince1970: Double($0)) } ?? Date()
        ingestIncomingChat(text: text, from: from, time: stamp, ordinal: 0)
    }

    private func ingestIncomingChat(text: String, from: UInt64, time: Date, ordinal: UInt64) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var invite = Self.parseInvite(trimmed, from: from, time: time, ordinal: ordinal) else { return }
        if invite.appID == nil || invite.appID == 0, let app = friends[from]?.appID, app != 0 {
            invite.appID = app
        }
        if invite.lobbyID == nil, let lobby = friends[from]?.joinableLobbyID {
            invite.lobbyID = lobby
        }
        SteamLog.event("[steam-friends] live invite from=\(from) app=\(invite.appID ?? 0) args=\(invite.arguments ?? "")")
        mergeInvites([invite], isLivePush: true)
    }

    private func mergeInvites(_ incoming: [SteamGameInvite], isLivePush: Bool = false) {
        let now = Date()
        var byID: [String: SteamGameInvite] = [:]
        for inv in invites { byID[inv.id] = inv }
        var newestFreshInvite: SteamGameInvite?

        for var inv in incoming {
            if inv.appID == nil || inv.appID == 0, let app = friends[inv.from]?.appID, app != 0 {
                inv.appID = app
            }
            if inv.lobbyID == nil, let lobby = friends[inv.from]?.joinableLobbyID {
                inv.lobbyID = lobby
            }
            byID[inv.id] = inv
            let isFirstSeen = !seenInviteIDs.contains(inv.id)
            seenInviteIDs.insert(inv.id)
            if isFirstSeen {
                let age = now.timeIntervalSince(inv.time)
                if isLivePush || age <= Self.freshBannerWindow || seededSeenInvites {
                    if newestFreshInvite == nil || inv.time > newestFreshInvite!.time {
                        newestFreshInvite = inv
                    }
                }
            }
        }
        seededSeenInvites = true
        invites = byID.values.sorted { $0.time > $1.time }

        if let banner = newestFreshInvite {
            presentBanner(banner)
        }
    }

    func presentBanner(_ invite: SteamGameInvite) {
        activeBannerInvite = invite
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard !Task.isCancelled, self?.activeBannerInvite?.id == invite.id else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self?.activeBannerInvite = nil
            }
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            activeBannerInvite = nil
        }
    }

    private func recentInvites(_ session: SteamSession) async throws -> [SteamGameInvite] {
        let since = UInt32(max(0, Date().timeIntervalSince1970 - Self.inviteWindow))
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: since)     // lastmessage_since
        request.writeBool(fieldNumber: 2, value: true)        // only_sessions_with_messages
        let sessions = try await session.callServiceMethod(method: .friendMessagesActiveSessions, body: request.data, timeout: 15)
        var found: [SteamGameInvite] = []
        let me = session.steamID & 0xFFFFFFFF
        // 1 message_sessions { 1 accountid_friend, 2 last_message }
        for chat in Proto.messages(sessions, 1).prefix(25) {
            let c = Proto.fields(chat)
            guard let account = c[1]?.first?.u64, let last = c[2]?.first?.u64, last >= UInt64(since) else { continue }
            let friend = Self.steamID64Base + account
            var r = ProtobufEncoder()
            r.writeFixed64(fieldNumber: 1, value: session.steamID)   // steamid1
            r.writeFixed64(fieldNumber: 2, value: friend)            // steamid2
            r.writeUInt32(fieldNumber: 3, value: 30)                 // count
            r.writeBool(fieldNumber: 6, value: true)                 // bbcode_format
            guard let messages = try? await session.callServiceMethod(method: .friendMessagesRecent, body: r.data, timeout: 15) else { continue }
            // 1 messages { 1 accountid, 2 timestamp, 3 message, 4 ordinal }
            for message in Proto.messages(messages, 1) {
                let m = Proto.fields(message)
                guard let from = m[1]?.first?.u64, from != me, let text = m[3]?.first?.string,
                      let stamp = m[2]?.first?.u64, Double(stamp) >= Double(since) else { continue }
                if var invite = Self.parseInvite(text, from: friend, time: Date(timeIntervalSince1970: Double(stamp)),
                                                 ordinal: m[4]?.first?.u64 ?? 0) {
                    if invite.appID == nil, let app = friends[friend]?.appID, app != 0 { invite.appID = app }
                    if invite.lobbyID == nil, let lobby = friends[friend]?.joinableLobbyID { invite.lobbyID = lobby }
                    found.append(invite)
                }
            }
        }
        return found.sorted { $0.time > $1.time }
    }

    /// Parses a game invite from BBCode (`[lobbyinvite ...]`, `[gameinvite ...]`),
    /// `steam://joinlobby/<app>/<lobby>/<friend>`, `steam://connect/<addr>`, or `+connect_lobby <id>`.
    static func parseInvite(_ text: String, from: UInt64, time: Date, ordinal: UInt64) -> SteamGameInvite? {
        var invite = SteamGameInvite(id: "\(from)-\(Int(time.timeIntervalSince1970))-\(ordinal)", from: from, time: time)

        if let tag = text.range(of: #"\[(\w*invite)\b([^\]]*)\]"#, options: [.regularExpression, .caseInsensitive]) {
            let body = String(text[tag])
            var attrs: [String: String] = [:]
            let regex = try? NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]+))"#)
            for match in regex?.matches(in: body, range: NSRange(body.startIndex..., in: body)) ?? [] {
                guard let k = Range(match.range(at: 1), in: body) else { continue }
                let vRange = [2, 3, 4].compactMap { Range(match.range(at: $0), in: body) }.first
                if let vRange {
                    attrs[String(body[k]).lowercased()] = String(body[vRange])
                }
            }
            invite.lobbyID = attrs["lobbyid"].flatMap { UInt64($0) }
            invite.connect = attrs["connect"].flatMap { $0.isEmpty ? nil : $0 }
            invite.appID = attrs["appid"].flatMap { Int($0) }
            if invite.lobbyID == nil, let c = invite.connect {
                invite.lobbyID = SteamInvites.extractLobbyID(from: c)
            }
            SteamLog.event("[steam-friends] invite tag \(body.prefix(160))")
            if invite.arguments != nil { return invite }
        }

        // steam://joinlobby/<appid>/<lobbyid>[/<friendid>]
        if let match = text.range(of: #"steam://joinlobby/(\d+)/(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let parts = String(text[match]).split(separator: "/")
            if parts.count >= 4, let app = Int(parts[2]), let lobby = UInt64(parts[3]) {
                invite.appID = app
                invite.lobbyID = lobby
                SteamLog.event("[steam-friends] joinlobby URI app=\(app) lobby=\(lobby)")
                return invite
            }
        }

        // steam://connect/<ip:port>
        if let match = text.range(of: #"steam://connect/([^\s\]]+)"#, options: [.regularExpression, .caseInsensitive]) {
            let addr = String(text[match]).replacingOccurrences(of: "steam://connect/", with: "")
            if !addr.isEmpty {
                invite.connect = "+connect \(addr)"
                return invite
            }
        }

        // Direct +connect_lobby <id>
        if let lobby = SteamInvites.extractLobbyID(from: text) {
            invite.lobbyID = lobby
            return invite
        }

        return nil
    }

    // MARK: Sending Invites to Friends

    /// Whether the user is currently in a Steam game and can send invites to friends.
    var canSendInvite: Bool {
        if let currentApp = LibraryModel.shared.activeEntry?.steamAppID, currentApp != 0 { return true }
        if let me = selfPersona, me.appID != 0 { return true }
        return false
    }

    /// Sends a Steam game/lobby invite to a friend over `FriendMessages.SendMessage#1`.
    func sendInvite(to friendID: UInt64) async {
        let appID = LibraryModel.shared.activeEntry?.steamAppID ?? selfPersona?.appID ?? 0
        guard appID != 0 else {
            statusNotice = "Start a Steam game first to invite friends."
            return
        }
        do {
            try await chatSession.ensureConnected()
            if let myID = chatSession.steamID as UInt64?, myID != 0 {
                try? await requestPersonas(chatSession, [myID])
            }
            let messageText: String
            if let lobbyID = selfPersona?.joinableLobbyID, lobbyID != 0 {
                messageText = "[lobbyinvite appid=\"\(appID)\" lobbyid=\"\(lobbyID)\"][/lobbyinvite]"
            } else if let connect = selfPersona?.connect, !connect.isEmpty {
                messageText = "[gameinvite appid=\"\(appID)\" connect=\"\(connect)\"][/gameinvite]"
            } else {
                let gameTitle = SteamOwnedLibrary.shared.game(appID)?.name ?? LibraryModel.shared.activeEntry?.title ?? "App \(appID)"
                messageText = "[gameinvite appid=\"\(appID)\" connect=\"+connect_steamid \(chatSession.steamID)\"][/gameinvite] Join me in \(gameTitle)!"
            }

            // CFriendMessages_SendMessage_Request:
            // 1 steamid (fixed64), 2 chat_entry_type (1 = ChatMsg), 3 message (string), 4 contains_bbcode (bool)
            var req = ProtobufEncoder()
            req.writeFixed64(fieldNumber: 1, value: friendID)
            req.writeInt32(fieldNumber: 2, value: 1)
            req.writeString(fieldNumber: 3, value: messageText)
            req.writeBool(fieldNumber: 4, value: true)
            _ = try await chatSession.callServiceMethod(method: .friendMessagesSendMessage, body: req.data, timeout: 15)
            statusNotice = "Sent game invite to \(name(friendID))."
            SteamLog.event("[steam-friends] sent invite to=\(friendID) app=\(appID)")
        } catch {
            statusNotice = "Could not send invite: \(error.localizedDescription)"
            SteamLog.event("[steam-friends] sendInvite failed: \(error)")
        }
    }

    // MARK: Native Callback File (C:\madeira\steam_join_cb.bin)

    private static var joinCallbackURL: URL {
        MadeiraDock.drive.appendingPathComponent("madeira/steam_join_cb.bin")
    }

    /// Writes `C:\madeira\steam_join_cb.bin` so `tftrace-x64.dll`'s `st_BGetCallback` hook
    /// injects `GameLobbyJoinRequested_t` (333) or `GameRichPresenceJoinRequested_t` (337)
    /// into the running game process.
    static func writeJoinCallback(appID: Int, lobbyID: UInt64?, friendID: UInt64, arguments: String) {
        let resolvedLobby = lobbyID ?? SteamInvites.extractLobbyID(from: arguments) ?? 0
        let resolvedFriend = friendID != 0 ? friendID : (SteamFriendsModel.shared.chatSession.steamID != 0 ? SteamFriendsModel.shared.chatSession.steamID : steamID64Base + 1)
        let callbackID: Int32 = resolvedLobby != 0 ? 333 : 337

        var data = Data(capacity: 280)
        var magic: UInt32 = 0x4D4A4E31 // 'MJN1'
        var cbID: Int32 = callbackID
        var lobby: UInt64 = resolvedLobby
        var friend: UInt64 = resolvedFriend
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &cbID) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &lobby) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &friend) { data.append(contentsOf: $0) }

        var connectBytes = Array(arguments.utf8.prefix(255))
        connectBytes.append(contentsOf: repeatElement(UInt8(0), count: 256 - connectBytes.count))
        data.append(contentsOf: connectBytes)

        let url = joinCallbackURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        SteamLog.event("[steam-friends] wrote steam_join_cb.bin cb=\(callbackID) lobby=\(resolvedLobby) friend=\(resolvedFriend)")
    }

    static func clearJoinCallback() {
        try? FileManager.default.removeItem(at: joinCallbackURL)
    }

    // MARK: Join

    /// Ensure a LibraryEntry exists for an installed Steam game even if the user hasn't opened its details sheet yet.
    private func ensureLibraryEntry(for appID: Int) -> LibraryEntry? {
        if let existing = LibraryModel.shared.entries.first(where: { $0.steamAppID == appID }) {
            return existing
        }
        let dockGame = SteamGamesModel.shared.games.first(where: { $0.id == appID && $0.installed })
            ?? MadeiraDock.games(drive: MadeiraDock.drive).first(where: { $0.id == appID && $0.installed })
        guard let dockGame else { return nil }
        let title = SteamOwnedLibrary.shared.game(appID)?.name ?? dockGame.name
        LibraryModel.shared.upsertSteam(dockGame, title: title)
        return LibraryModel.shared.entries.first(where: { $0.steamAppID == appID })
    }

    /// Starts or notifies the invite's game in EmuPC with the arguments/callback that join it.
    /// Returns a problem to show, or nil once the join is under way.
    func join(appID: Int?, arguments: String, friendID: UInt64 = 0, lobbyID: UInt64? = nil, forceRestart: Bool = false) -> String? {
        let resolvedAppID: Int? = {
            if let appID, appID != 0 { return appID }
            if friendID != 0, let friendApp = friends[friendID]?.appID, friendApp != 0 { return friendApp }
            if let currentApp = LibraryModel.shared.activeEntry?.steamAppID, currentApp != 0 { return currentApp }
            return nil
        }()
        guard let targetAppID = resolvedAppID, targetAppID != 0 else {
            return "EmuPC can't tell which game this invite is for. Ask your friend to invite you again while they're in the game."
        }
        guard let entry = ensureLibraryEntry(for: targetAppID) else {
            let name = SteamOwnedLibrary.shared.game(targetAppID)?.name ?? "This game"
            return "\(name) isn't installed in EmuPC. Download it first, then join."
        }

        let resolvedLobby = lobbyID ?? SteamInvites.extractLobbyID(from: arguments)
        SteamInvites.set(arguments, for: targetAppID, friendID: friendID, lobbyID: resolvedLobby)
        dismissBanner()

        // Case 1: The target Steam game is already running right now!
        if !forceRestart,
           SteamOwnedLibrary.shared.gameSessionRunning,
           LibraryModel.shared.activeEntry?.steamAppID == targetAppID {
            Self.writeJoinCallback(appID: targetAppID, lobbyID: resolvedLobby, friendID: friendID, arguments: arguments)
            let inviteRecord = SteamGameInvite(
                id: "live-\(friendID)-\(Int(Date().timeIntervalSince1970))",
                from: friendID,
                time: Date(),
                appID: targetAppID,
                lobbyID: resolvedLobby,
                connect: arguments
            )
            lastInGameJoinedInvite = inviteRecord
            let friendLabel = friendID != 0 ? name(friendID) : "your friend"
            statusNotice = "Sent lobby join to running game (\(friendLabel)). Switch back to the game to join!"
            SteamLog.event("[steam-friends] live in-game join app=\(targetAppID) lobby=\(resolvedLobby ?? 0) args=\(arguments)")
            return nil
        }

        // Case 2: A different game is running (or user asked to restart into the lobby).
        if SteamOwnedLibrary.shared.gameSessionRunning || LibraryModel.shared.current != nil {
            Task { await chatSession.disconnectGracefully() }
            NextSteamApp.set(targetAppID)
            SteamLog.event("[steam-friends] relaunching into app=\(targetAppID) args=\(arguments)")
            AppRelaunch.closeAndOffer("steam-invite")
            return nil
        }

        // Case 3: No game is running — disconnect chatSession first so Dock owns the CM session, then launch.
        Task { await chatSession.disconnectGracefully() }
        SteamLog.event("[steam-friends] join cold launch app=\(targetAppID) args=\(arguments)")
        ShortcutRouter.shared.start(entry: entry.id)
        return nil
    }
}

// MARK: - A small protobuf reader

/// Every field of a message by number, values in wire form.
enum Proto {
    struct Value {
        var u64: UInt64?
        var bytes: Data?
        var string: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func fields(_ data: Data) -> [UInt32: [Value]] {
        var out: [UInt32: [Value]] = [:]
        var d = ProtobufDecoder(data)
        while !d.isAtEnd {
            guard let tag = try? d.readTag() else { break }
            var v = Value()
            switch tag.wireType {
            case .varint: v.u64 = try? d.readVarint()
            case .fixed64: v.u64 = try? d.readFixed64()
            case .fixed32: v.u64 = (try? d.readFixed32()).map(UInt64.init)
            case .lengthDelimited: v.bytes = try? d.readBytes()
            }
            out[tag.fieldNumber, default: []].append(v)
        }
        return out
    }

    static func messages(_ data: Data, _ field: UInt32) -> [Data] { fields(data)[field]?.compactMap(\.bytes) ?? [] }
}

// MARK: - In-Game Steam Invite Toast Banner

/// Steam Overlay-style invite toast shown at the top-right when a friend sends a game invite.
struct SteamInviteBanner: View {
    @ObservedObject private var model = SteamFriendsModel.shared
    @State private var problem: String?

    var body: some View {
        if let invite = model.activeBannerInvite {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green)
                    .frame(width: 4, height: 44)

                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.name(invite.from)) invited you to play")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(gameName(invite.appID, from: invite.from))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.56, green: 0.88, blue: 0.42))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Button {
                    if let args = invite.arguments {
                        if let err = model.join(appID: invite.appID, arguments: args, friendID: invite.from, lobbyID: invite.lobbyID) {
                            problem = err
                        }
                    }
                } label: {
                    Text("Join")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    model.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 390)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.11, green: 0.16, blue: 0.24).opacity(0.96),
                                Color(red: 0.08, green: 0.11, blue: 0.17).opacity(0.96),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .alert("Can't join", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
    }

    private func gameName(_ appID: Int?, from friendID: UInt64) -> String {
        let resolved = (appID != nil && appID != 0) ? appID : model.friends[friendID]?.appID
        guard let resolved, resolved != 0 else { return "Steam Game" }
        if let friendGame = model.friends[friendID]?.gameName, !friendGame.isEmpty { return friendGame }
        return SteamOwnedLibrary.shared.game(resolved)?.name ?? "App \(resolved)"
    }
}

// MARK: - The Steam Overlay Friends & Invites Sheet

/// Whether the friends overlay is up: the screens under it leave the controller alone
/// while it is (SteamFriendsView reads the pad itself).
@MainActor enum SteamOverlayPad { static var open = false }

struct SteamFriendsView: View {
    @ObservedObject private var model = SteamFriendsModel.shared
    @ObservedObject private var pad = LibraryController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    /// The focused row, for the controller.
    @State private var focus = 0

    /// One row of the overlay, in the order shown: invites, open lobbies, then friends.
    private enum Row: Identifiable {
        case invite(SteamGameInvite), lobby(SteamFriend), friend(SteamFriend)
        var id: String {
            switch self {
            case .invite(let i): return "i" + i.id
            case .lobby(let f): return "l\(f.id)"
            case .friend(let f): return "f\(f.id)"
            }
        }
    }

    private var lobbies: [SteamFriend] {
        model.joinableFriends.filter { friend in
            !model.invites.contains(where: { $0.from == friend.id && Date().timeIntervalSince($0.time) < 1800 })
        }
    }

    private var rows: [Row] {
        model.invites.map(Row.invite) + lobbies.map(Row.lobby) + model.sortedFriends.map(Row.friend)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let notice = model.statusNotice { noticeCard(notice) }
                        if let error = model.error {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        let all = rows
                        section("Game invites & open lobbies") {
                            if model.invites.isEmpty && lobbies.isEmpty {
                                Text(model.loading ? "Looking for invites and joinable lobbies…" : "No game invites or joinable lobbies right now.")
                                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
                            }
                            ForEach(Array(all.enumerated()).filter { if case .friend = $0.element { return false }; return true }, id: \.element.id) { index, row in
                                rowView(row, focused: pad.connected && focus == index).id(row.id)
                                    .onTapGesture { focus = index; primary(row) }
                            }
                        }
                        section("Friends · \(model.sortedFriends.filter(\.online).count) online") {
                            ForEach(Array(all.enumerated()).filter { if case .friend = $0.element { return true }; return false }, id: \.element.id) { index, row in
                                rowView(row, focused: pad.connected && focus == index).id(row.id)
                                    .onTapGesture { focus = index }
                            }
                        }
                        Text(SteamOwnedLibrary.shared.gameSessionRunning
                             ? "Joining the game you are playing sends the lobby invite straight to it, without closing it."
                             : "Join starts the game in EmuPC and connects you straight to your friend's lobby.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
                .onChange(of: focus) { _, index in
                    let all = rows
                    guard all.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(all[index].id, anchor: .center) }
                }
            }
            .safeAreaInset(edge: .bottom) { if pad.connected { hintBar } }
            .background(LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.18), Color(red: 0.04, green: 0.05, blue: 0.08)],
                                       startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("Friends").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    if model.loading { ProgressView() } else {
                        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .task {
                if SteamOwnedLibrary.shared.gameSessionRunning {
                    if model.friends.isEmpty {
                        await model.refresh()
                        await model.chatSession.disconnectGracefully()
                    }
                    return
                }
                // Fresh on open, then every 12 s while the overlay is open in the library.
                while !Task.isCancelled, !SteamOwnedLibrary.shared.gameSessionRunning {
                    await model.refresh()
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                }
            }
            .onAppear { SteamOverlayPad.open = true }
            .onDisappear {
                SteamOverlayPad.open = false
                if SteamOwnedLibrary.shared.gameSessionRunning {
                    Task { await model.chatSession.disconnectGracefully() }
                }
            }
            .onReceive(LibraryController.shared.commands) { command(_: $0) }
            .alert("Can't join", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Controller

    private func command(_ command: String) {
        if problem != nil { if ["accept", "back"].contains(command) { problem = nil }; return }
        let count = rows.count
        switch command {
        case "up": if focus > 0 { focus -= 1; tick() }
        case "down": if focus < count - 1 { focus += 1; tick() }
        case "tabBack": focus = 0; tick()
        case "tab": focus = max(count - 1, 0); tick()
        case "accept": if rows.indices.contains(focus) { primary(rows[focus]) }
        case "add": if rows.indices.contains(focus), case .friend(let f) = rows[focus], f.online, model.canSendInvite {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await model.sendInvite(to: f.id) }
        }
        case "x": Task { await model.refresh() }
        case "back", "guide", "menu": dismiss()
        default: break
        }
    }

    private func tick() { UISelectionFeedbackGenerator().selectionChanged() }

    /// A: join what the row offers.
    private func primary(_ row: Row) {
        switch row {
        case .invite(let i): join(i.appID, i.arguments, friendID: i.from, lobbyID: i.lobbyID)
        case .lobby(let f), .friend(let f):
            if f.inGame, let connect = f.connect { join(f.appID, connect, friendID: f.id, lobbyID: f.joinableLobbyID) }
        }
    }

    // MARK: Pieces

    private var hintBar: some View {
        HStack(spacing: 18) {
            ButtonHint(glyph: "a.circle.fill", label: "Join")
            if model.canSendInvite { ButtonHint(glyph: "y.circle.fill", label: "Invite") }
            ButtonHint(glyph: "x.circle.fill", label: "Refresh")
            ButtonHint(glyph: "b.circle.fill", label: "Close")
        }
        .font(.subheadline)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 8)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.secondary).padding(.leading, 4)
            content()
        }
    }

    private func noticeCard(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(notice).font(.subheadline)
                Spacer()
                Button { model.statusNotice = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            if let last = model.lastInGameJoinedInvite, let args = last.arguments, SteamOwnedLibrary.shared.gameSessionRunning {
                Button {
                    _ = model.join(appID: last.appID, arguments: args, friendID: last.from, lobbyID: last.lobbyID, forceRestart: true)
                } label: {
                    Label("Game didn't switch lobbies? Restart into the lobby", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                }.buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func rowView(_ row: Row, focused: Bool) -> some View {
        let (friend, invite): (SteamFriend?, SteamGameInvite?) = {
            switch row {
            case .invite(let i): return (model.friends[i.from], i)
            case .lobby(let f), .friend(let f): return (f, nil)
            }
        }()
        let id = invite?.from ?? friend?.id ?? 0
        let name = invite != nil ? model.name(id) : ((friend?.name.isEmpty ?? true) ? "A friend" : friend!.name)
        let inGame = friend?.inGame ?? false
        let dot: Color = invite != nil || inGame ? .green : (friend?.online ?? false) ? .blue : .gray
        return HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(.white.opacity(0.1)).frame(width: 44, height: 44)
                    .overlay(Text(String(name.prefix(1)).uppercased()).font(.headline))
                Circle().fill(dot).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.semibold)).lineLimit(1)
                    if case .lobby = row { tag("OPEN LOBBY") }
                    if invite != nil { tag("INVITE") }
                }
                Group {
                    if let invite {
                        Text("\(gameName(invite.appID, from: invite.from)) · \(invite.time.formatted(.relative(presentation: .named)))")
                    } else if let friend, inGame {
                        Text(friend.gameName.isEmpty ? gameName(friend.appID, from: friend.id) : friend.gameName).foregroundStyle(.green)
                    } else {
                        Text((friend?.online ?? false) ? "Online" : "Offline")
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if invite == nil, let detail = friend?.presenceDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if invite != nil || (inGame && friend?.connect != nil) {
                Button("Join") { primary(row) }.buttonStyle(.borderedProminent).tint(.green)
            }
            if case .friend(let f) = row, f.online, model.canSendInvite {
                Button("Invite") { Task { await model.sendInvite(to: f.id) } }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(focused ? Color.white.opacity(0.16) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(focused ? Color.white.opacity(0.9) : .clear, lineWidth: 2))
        .shadow(color: focused ? .white.opacity(0.18) : .clear, radius: 10)
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: focused)
        .contentShape(Rectangle())
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.green.opacity(0.2), in: Capsule()).foregroundStyle(.green)
    }

    private func gameName(_ appID: Int?, from friendID: UInt64 = 0) -> String {
        let resolved = (appID != nil && appID != 0) ? appID : (friendID != 0 ? model.friends[friendID]?.appID : nil)
        guard let resolved, resolved != 0 else { return "A game" }
        if friendID != 0, let name = model.friends[friendID]?.gameName, !name.isEmpty { return name }
        return SteamOwnedLibrary.shared.game(resolved)?.name ?? "App \(resolved)"
    }

    private func join(_ appID: Int?, _ arguments: String?, friendID: UInt64 = 0, lobbyID: UInt64? = nil) {
        guard let arguments else { return }
        let wasAlreadyInSameGame = SteamOwnedLibrary.shared.gameSessionRunning && LibraryModel.shared.activeEntry?.steamAppID == appID
        if let p = model.join(appID: appID, arguments: arguments, friendID: friendID, lobbyID: lobbyID) {
            problem = p
        } else if !wasAlreadyInSameGame {
            dismiss()
        }
    }
}
