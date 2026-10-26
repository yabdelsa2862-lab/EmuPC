// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// MABD local: what a GOG or Epic game row shows before downloading, like a
// Steam row: its sizes, and whether it should run. The compatibility estimate
// (GameCompatibility: anti-cheat and Steam's minimum requirements, RAM among
// them) is keyed by Steam app, so the game is looked up on Steam by its title;
// a game not sold on Steam has no estimate.

struct StoreSize: Codable, Equatable {
    var download: Int64
    var disk: Int64

    private static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    static func load(_ name: String) -> [String: StoreSize] {
        (try? JSONDecoder().decode([String: StoreSize].self, from: Data(contentsOf: url(name)))) ?? [:]
    }
    static func save(_ sizes: [String: StoreSize], _ name: String) {
        if let data = try? JSONEncoder().encode(sizes) { try? data.write(to: url(name), options: .atomic) }
    }
}

struct StoreSizeLine: View {
    let size: StoreSize?
    var body: some View {
        if let size {
            Text("Needs \(ByteCountFormatter.string(fromByteCount: size.disk, countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: size.download, countStyle: .file)) download")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Getting size…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Steam app ids by game title, for the compatibility estimate. 0 = not on Steam.
@MainActor
final class SteamTitleMatch: ObservableObject {
    static let shared = SteamTitleMatch()
    @Published private(set) var ids: [String: Int] = (UserDefaults.standard.dictionary(forKey: "madeiraSteamTitleMatch") as? [String: Int]) ?? [:]
    private var asking = Set<String>()

    static func key(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func request(_ title: String) {
        let k = Self.key(title)
        guard ids[k] == nil, !asking.contains(k), !k.isEmpty else { return }
        asking.insert(k)
        Task {
            defer { asking.remove(k) }
            var c = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
            c.queryItems = [URLQueryItem(name: "term", value: title), URLQueryItem(name: "cc", value: "US"), URLQueryItem(name: "l", value: "en")]
            guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return }
            // Only an exact title match: a near miss would show another game's verdict.
            let match = items.first { (($0["name"] as? String).map(Self.key)) == k }?["id"] as? Int
            ids[k] = match ?? 0
            UserDefaults.standard.set(ids, forKey: "madeiraSteamTitleMatch")
        }
    }
}

/// Compatibility for GOG and Epic games from their own stores: GOG's catalog
/// lists requirements for every game; for Epic, the anti-cheat list (matched by
/// Epic namespace), then Steam's requirements when the game is also on Steam,
/// else Epic's store page (store-content by product slug). Judged by the same
/// rules as Steam games (GameCompatibility.judge).
@MainActor
final class StoreCompatibilityModel: ObservableObject {
    static let shared = StoreCompatibilityModel()
    @Published private(set) var reports: [String: GameCompatibility.Report] = [:]
    private var asking = Set<String>()
    private var antiCheat: (byNamespace: [String: (names: [String], status: String)], slugs: [String: String])?

    private func loadAntiCheat() async {
        guard antiCheat == nil else { return }
        var byNamespace: [String: (names: [String], status: String)] = [:], slugs: [String: String] = [:]
        if let url = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for game in list {
                guard let epic = (game["storeIds"] as? [String: Any])?["epic"] as? [String: Any],
                      let ns = epic["namespace"] as? String else { continue }
                byNamespace[ns] = (game["anticheats"] as? [String] ?? [], game["status"] as? String ?? "")
                if let slug = epic["slug"] as? String { slugs[ns] = slug }
            }
        }
        antiCheat = (byNamespace, slugs)
    }

    func requestGOG(_ id: Int) {
        let key = "gog:\(id)"
        guard reports[key] == nil, !asking.contains(key) else { return }
        asking.insert(key)
        Task {
            defer { asking.remove(key) }
            var requirements: GameCompatibility.Requirements?
            if let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://api.gog.com/v2/games/\(id)")!),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let systems = (root["_embedded"] as? [String: Any])?["supportedOperatingSystems"] as? [[String: Any]],
               let windows = systems.first(where: { (($0["operatingSystem"] as? [String: Any])?["name"] as? String) == "windows" }),
               let minimum = (windows["systemRequirements"] as? [[String: Any]])?.first(where: { ($0["type"] as? String) == "minimum" }) ?? (windows["systemRequirements"] as? [[String: Any]])?.first,
               let items = minimum["requirements"] as? [[String: Any]] {
                var text = ""
                for item in items {
                    let value = item["description"] as? String ?? ""
                    switch item["id"] as? String {
                    case "memory": text += " Memory: \(value) "
                    case "directx": text += " DirectX: \(value.filter { $0.isNumber || $0 == "." }.split(separator: ".").first ?? "") "
                    default: text += " \(value) "
                    }
                }
                requirements = GameCompatibility.parseRequirements(text)
            }
            reports[key] = GameCompatibility.judge(anticheats: [], requirements: requirements)
        }
    }

    func requestEpic(_ game: EpicGame) {
        let key = "epic:\(game.appName)"
        guard reports[key] == nil, !asking.contains(key) else { return }
        asking.insert(key)
        Task {
            defer { asking.remove(key) }
            await loadAntiCheat()
            let cheat = antiCheat?.byNamespace[game.namespace]
            var requirements: GameCompatibility.Requirements?
            // Steam's requirements when it sells the same game.
            if let steam = SteamTitleMatch.shared.ids[SteamTitleMatch.key(game.title)], steam > 0 {
                requirements = await GameCompatibility.fetchRequirements(steam)
            }
            // Else Epic's own store page.
            if requirements == nil {
                let derived = game.title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                for slug in [antiCheat?.slugs[game.namespace], derived].compactMap({ $0 }) {
                    guard let url = URL(string: "https://store-content-ipv4.ak.epicgames.com/api/en-US/content/products/\(slug)"),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let page = (root["pages"] as? [[String: Any]])?.first,
                          let systems = ((page["data"] as? [String: Any])?["requirements"] as? [String: Any])?["systems"] as? [[String: Any]],
                          let windows = systems.first(where: { ($0["systemType"] as? String)?.lowercased() == "windows" }),
                          let details = windows["details"] as? [[String: Any]] else { continue }
                    var text = ""
                    for d in details {
                        let title = (d["title"] as? String ?? "").lowercased(), value = d["minimum"] as? String ?? ""
                        if title.contains("memory") { text += " Memory: \(value) " }
                        else if title.contains("directx") { text += " DirectX: \(value.filter { $0.isNumber || $0 == "." }.split(separator: ".").first ?? "") " }
                        else { text += " \(value) " }
                    }
                    requirements = GameCompatibility.parseRequirements(text)
                    break
                }
            }
            var report = GameCompatibility.judge(anticheats: cheat?.names ?? [], status: cheat?.status, requirements: requirements)
            if requirements == nil, let i = report.reasons.firstIndex(where: { $0.hasPrefix("Steam didn't list") }) {
                report.reasons[i] = "Epic didn't list system requirements, so this is a guess."
            }
            reports[key] = report
        }
    }
}

/// The compatibility pill and its first reason, for a GOG or Epic game.
struct StoreCompatibility: View {
    var gogID: Int? = nil
    var epic: EpicGame? = nil
    @ObservedObject private var model = StoreCompatibilityModel.shared
    @ObservedObject private var match = SteamTitleMatch.shared

    private var key: String { gogID.map { "gog:\($0)" } ?? "epic:\(epic?.appName ?? "")" }

    var body: some View {
        Group {
            if let report = model.reports[key] {
                VStack(alignment: .leading, spacing: 2) {
                    Label(report.verdict.title, systemImage: report.verdict.symbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(report.verdict.color)
                    if let reason = report.reasons.first(where: { !$0.hasPrefix("No known blockers") }) ?? report.reasons.first {
                        Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } else {
                Label("Checking compatibility…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: key) {
            if let gogID { model.requestGOG(gogID) }
            else if let epic {
                // The Steam lookup first (its requirements are the most complete).
                match.request(epic.title)
                for _ in 0..<20 where match.ids[SteamTitleMatch.key(epic.title)] == nil {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                model.requestEpic(epic)
            }
        }
    }
}

// MARK: - Store page details

/// A store page's description, developer and screenshots (Steam, GOG or Epic).
struct StoreGameInfo: Equatable, Codable {
    var description: String?
    var developer: String?
    /// Small previews for the page, and the same pictures full size for the viewer.
    var screenshots: [URL] = []
    var fullScreenshots: [URL] = []
}

@MainActor
final class StoreDetailsModel: ObservableObject {
    static let shared = StoreDetailsModel()
    @Published private(set) var info: [String: StoreGameInfo] = [:]
    private var asking = Set<String>()

    /// Saved on the phone for a week, so a page opens with its About at once.
    private struct Saved: Codable { var info: StoreGameInfo; var saved: Date }
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Madeira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store-details.json")
    }
    private var saved: [String: Saved] = [:]

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let all = try? JSONDecoder().decode([String: Saved].self, from: data) {
            saved = all.filter { $0.value.saved > Date().addingTimeInterval(-7 * 86_400) }
            info = saved.mapValues(\.info)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    /// The pictures a page will show, fetched ahead into the image cache.
    private func prefetch(_ urls: [URL]) {
        for url in urls.prefix(4) {
            URLSession.shared.dataTask(with: url).resume()
        }
    }

    private static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<br ?/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func json(_ url: String, token: String? = nil) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        if let token { request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func requestSteam(_ id: Int) {
        load("steam:\(id)") {
            guard let root = await Self.json("https://store.steampowered.com/api/appdetails?appids=\(id)&cc=us&l=english") as? [String: Any],
                  let data = (root["\(id)"] as? [String: Any])?["data"] as? [String: Any] else { return nil }
            return StoreGameInfo(description: (data["short_description"] as? String).map(Self.plain),
                                 developer: (data["developers"] as? [String])?.first,
                                 screenshots: (data["screenshots"] as? [[String: Any]] ?? []).prefix(8)
                                    .compactMap { ($0["path_thumbnail"] as? String).flatMap(URL.init(string:)) },
                                 fullScreenshots: (data["screenshots"] as? [[String: Any]] ?? []).prefix(8)
                                    .compactMap { ($0["path_full"] as? String).flatMap(URL.init(string:)) })
        }
    }

    func requestGOG(_ id: Int) {
        load("gog:\(id)") {
            guard let p = await Self.json("https://api.gog.com/products/\(id)?expand=description,screenshots") as? [String: Any] else { return nil }
            let d = p["description"] as? [String: Any]
            let text = (d?["lead"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (d?["full"] as? String)
            func shots(_ formatter: String) -> [URL] {
                (p["screenshots"] as? [[String: Any]] ?? []).prefix(8).compactMap { s -> URL? in
                    guard var t = s["formatter_template_url"] as? String else { return nil }
                    t = t.replacingOccurrences(of: "{formatter}", with: formatter)
                    return URL(string: t.hasPrefix("//") ? "https:" + t : t)
                }
            }
            return StoreGameInfo(description: text.map(Self.plain).map { String($0.prefix(900)) }, developer: nil,
                                 screenshots: shots("ggvgm"), fullScreenshots: shots("ggvgl_2x"))
        }
    }

    func requestEpic(_ game: EpicGame) {
        load("epic:\(game.appName)") {
            let token = try? await EpicLibrary.shared.tokens().accessToken
            let url = EpicAPI.catalog + "/catalog/api/shared/namespace/\(game.namespace)/bulk/items?id=\(game.catalogItemID)&country=US&locale=en"
            guard let root = await Self.json(url, token: token) as? [String: Any],
                  let item = root[game.catalogItemID] as? [String: Any] else { return nil }
            let images = item["keyImages"] as? [[String: Any]] ?? []
            let raw = images.filter { ($0["type"] as? String)?.lowercased().contains("screenshot") == true }.compactMap { $0["url"] as? String }.prefix(8)
            return StoreGameInfo(description: (item["description"] as? String).map(Self.plain),
                                 developer: item["developer"] as? String,
                                 screenshots: raw.compactMap { EpicGame.sized($0, width: 640, height: 360) },
                                 fullScreenshots: raw.compactMap { EpicGame.sized($0, width: 1920, height: 1080) })
        }
    }

    private func load(_ key: String, _ fetch: @escaping () async -> StoreGameInfo?) {
        guard info[key] == nil, !asking.contains(key) else { return }
        asking.insert(key)
        Task {
            defer { asking.remove(key) }
            guard let fetched = await fetch() else { info[key] = StoreGameInfo(); return }
            info[key] = fetched
            saved[key] = Saved(info: fetched, saved: Date())
            persist()
            prefetch(fetched.screenshots)
        }
    }
}

/// The About and screenshots part of a store page.
struct StoreAboutSection: View {
    let info: StoreGameInfo?
    var onDark = false
    /// A screenshot was tapped: its index, for the full-screen viewer.
    var open: ((Int) -> Void)? = nil
    /// The screenshot the controller is on (controller home), outlined and scrolled to.
    var focused: Int? = nil
    var accent: Color = .white

    var body: some View {
        if let info {
            VStack(alignment: .leading, spacing: 10) {
                if let developer = info.developer {
                    Text(developer).font(.subheadline.weight(.semibold)).foregroundStyle(onDark ? .white.opacity(0.7) : .secondary)
                }
                if !info.screenshots.isEmpty {
                    ScrollViewReader { reader in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(info.screenshots.enumerated()), id: \.offset) { i, url in
                                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                                        .frame(width: 240, height: 135).clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent, lineWidth: focused == i ? 4 : 0))
                                        .scaleEffect(focused == i ? 1.05 : 1)
                                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focused)
                                        .padding(4)
                                        .id(i)
                                        .contentShape(Rectangle())
                                        .onTapGesture { open?(i) }
                                }
                            }
                        }
                        .onChange(of: focused) { _, i in
                            guard let i else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { reader.scrollTo(i, anchor: .center) }
                        }
                    }
                    .id("store-shots")
                }
                if let text = info.description, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundStyle(onDark ? .white.opacity(0.85) : .primary)
                        .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            ProgressView().tint(onDark ? .white : nil)
        }
    }
}

// MARK: - Touch store page (GOG and Epic)

struct StorePageSheet: View {
    var gogID: Int? = nil
    var epicApp: String? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var details = StoreDetailsModel.shared
    @ObservedObject private var compat = StoreCompatibilityModel.shared
    @State private var viewer = false
    @State private var viewerIndex = 0

    private var key: String { gogID.map { "gog:\($0)" } ?? "epic:\(epicApp ?? "")" }
    private var title: String {
        if let gogID { return gog.owned.first { $0.id == gogID }?.title ?? "Game" }
        return epic.owned.first { $0.appName == epicApp }?.title ?? "Game"
    }
    private var hero: URL? {
        if let gogID { return gog.owned.first { $0.id == gogID }?.image.flatMap(URL.init(string:)) }
        return epic.owned.first { $0.appName == epicApp }?.banner
    }
    private var size: StoreSize? { gogID.flatMap { gog.sizes[$0] } ?? epicApp.flatMap { epic.sizes[$0] } }
    private var state: (label: String, fraction: Double?, failed: String?) {
        if let gogID, let d = gog.downloads[gogID] {
            switch d.state {
            case .active, .queued: return ("Pause", d.fraction, nil)
            case .paused: return ("Resume", d.fraction, nil)
            case .failed(let why): return ("Try again", nil, why)
            }
        }
        if let epicApp, let d = epic.downloads[epicApp] {
            switch d.state {
            case .active, .queued: return ("Pause", d.fraction, nil)
            case .paused: return ("Resume", d.fraction, nil)
            case .failed(let why): return ("Try again", nil, why)
            }
        }
        return ("Get", nil, nil)
    }

    private func act() {
        if let gogID {
            if let d = gog.downloads[gogID], d.state == .active || d.state == .queued { gog.pause(gogID) } else { gog.install(gogID) }
        } else if let epicApp {
            if let d = epic.downloads[epicApp], d.state == .active || d.state == .queued { epic.pause(epicApp) } else { epic.install(epicApp) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AsyncImage(url: hero) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                        .frame(height: 200).frame(maxWidth: .infinity).clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { viewerIndex = -1; viewer = true }
                        .overlay(alignment: .bottomLeading) {
                            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        }
                    VStack(alignment: .leading, spacing: 14) {
                        Text(gogID != nil ? "GOG" : "EPIC GAMES").font(.caption.weight(.heavy)).foregroundStyle(.tint)
                        Text(title).font(.largeTitle.weight(.bold))
                        Button(action: act) {
                            Text(state.label).font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        if let f = state.fraction { ProgressView(value: f) }
                        if let why = state.failed { Text(why).font(.footnote).foregroundStyle(.red) }
                        if let size, state.fraction == nil {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Label("Needs " + ByteCountFormatter.string(fromByteCount: size.disk, countStyle: .file) + " of space", systemImage: "internaldrive")
                                    .font(.subheadline.weight(.semibold))
                                Text(ByteCountFormatter.string(fromByteCount: size.download, countStyle: .file) + " download")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let report = compat.reports[key] {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(report.verdict.title, systemImage: report.verdict.symbol)
                                    .font(.headline).foregroundStyle(report.verdict.color)
                                ForEach(report.reasons, id: \.self) { Text("• " + $0).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                        Text("About").font(.title3.weight(.semibold)).padding(.top, 4)
                        StoreAboutSection(info: details.info[key]) { i in viewerIndex = i; viewer = true }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: .top)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $viewer) {
                FullScreenImages(urls: ([hero].compactMap { $0 }) + (details.info[key]?.fullScreenshots ?? []),
                                 index: Binding(get: { viewerIndex + (hero == nil ? 0 : 1) }, set: { viewerIndex = $0 - (hero == nil ? 0 : 1) })) { viewer = false }
            }
            .task {
                if let gogID {
                    details.requestGOG(gogID); gog.requestSize(gogID); compat.requestGOG(gogID)
                } else if let epicApp, let g = epic.owned.first(where: { $0.appName == epicApp }) {
                    details.requestEpic(g); epic.requestSize(epicApp); compat.requestEpic(g)
                }
            }
        }
    }
}

/// A store page selection for `.sheet(item:)`.
struct StorePageID: Identifiable { let value: String; var id: String { value } }

/// The open store page in Download games. Held above the list: a sheet attached
/// to a list section closed itself when the section redrew as the page's size
/// and compatibility arrived (only the first time, before they were cached).
@MainActor
final class StorePageRouter: ObservableObject {
    static let shared = StorePageRouter()
    @Published var page: StorePageID?
}

/// The sheet for the open store page ("gog:<id>" or "epic:<app>").
struct StorePageHost: ViewModifier {
    @ObservedObject private var router = StorePageRouter.shared
    func body(content: Content) -> some View {
        content.sheet(item: $router.page) { sel in
            if sel.value.hasPrefix("gog:") { StorePageSheet(gogID: Int(sel.value.dropFirst(4))) }
            else { StorePageSheet(epicApp: String(sel.value.dropFirst(5))) }
        }
    }
}


// MARK: - Full-screen images

/// A full-screen picture viewer: swipe or tap the sides to move, tap to close.
struct FullScreenImages: View {
    let urls: [URL]
    @Binding var index: Int
    var close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                    AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
            .ignoresSafeArea()
            .onTapGesture { close() }
            VStack {
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .statusBarHidden(true)
    }
}

/// The poster with fallbacks: new Steam games keep their portrait art at a
/// hashed address the guessed one misses, so a missing poster shows the wide art.
struct PosterImage: View {
    let poster: URL?
    let fallback: URL?
    var body: some View {
        AsyncImage(url: poster) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .failure: AsyncImage(url: fallback) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
            default: Color.white.opacity(0.08)
            }
        }
    }
}


/// MABD local: a large shared cache for artwork and screenshots (AsyncImage and
/// URLSession.shared use URLCache.shared, whose default is a few MB). Set once at launch.
enum ImageCache {
    static func configure() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("madeira-images", isDirectory: true)
        URLCache.shared = URLCache(memoryCapacity: 96 * 1024 * 1024, diskCapacity: 768 * 1024 * 1024, directory: dir)
    }
}

/// MABD local: upstream's Steam sizes are UInt64 `downloadBytes` and
/// `installBytes`; the store pages read them as Int64.
extension SteamOwnedGame {
    var diskBytes: Int64? { installBytes.map { Int64(clamping: $0) } }
    var downloadBytes64: Int64? { downloadBytes.map { Int64(clamping: $0) } }
}
