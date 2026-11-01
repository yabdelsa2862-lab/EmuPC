// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import AppIntents
import CoreImage
import Foundation
import UIKit

// EmuPC: games on the Home Screen through the Shortcuts app.
//
//   - "Open Game" (OpenGameIntent) is an EmuPC action in Shortcuts with a game
//     picker listing the library. It opens EmuPC and starts that game, as Play does.
//     Each game also shows up ready-made under EmuPC in Shortcuts ("Play <game> in EmuPC").
//   - Icons/ in EmuPC's folder (Files › On My iPhone › EmuPC › Icons) holds one
//     square PNG per game, made for the Home Screen: Steam's background art with
//     the game's logo, or the whole cover over a blurred copy of itself. In
//     Shortcuts › Add to Home Screen › the icon › Choose File, pick it there.
//
// Log tag: [game-shortcuts].

// MARK: - The action

struct GameEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static let defaultQuery = GameQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        let icon = GameIcons.url(forTitle: title)
        return FileManager.default.fileExists(atPath: icon.path)
            ? DisplayRepresentation(title: "\(title)", image: .init(url: icon))
            : DisplayRepresentation(title: "\(title)")
    }
}

/// The library's games, read from its file (Shortcuts may ask before the app's
/// library is loaded, or with EmuPC not running at all).
struct GameQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [GameEntity] {
        GameShortcuts.games().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [GameEntity] {
        GameShortcuts.games().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [GameEntity] { GameShortcuts.games() }
}

struct OpenGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Game"
    static let description = IntentDescription("Opens EmuPC and starts a game from your library, like Play does.")
    static let openAppWhenRun = true

    @Parameter(title: "Game") var game: GameEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$game) in EmuPC") }

    @MainActor
    func perform() async throws -> some IntentResult {
        LogStore.shared.log("[game-shortcuts] Open Game: \(game.title)")
        if let id = UUID(uuidString: game.id) { ShortcutRouter.shared.start(entry: id) }
        return .result()
    }
}

enum GameShortcuts {
    private struct Document: Decodable { var entries: [LibraryEntry] }

    static func games() -> [GameEntity] {
        let file = LibraryModel.documents.appendingPathComponent("madeira-library.json")
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
        return doc.entries.filter { $0.desktop != true }
            .map { GameEntity(id: $0.id.uuidString, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

// MARK: - Icons

@MainActor
enum GameIcons {
    static var folder: URL { LibraryModel.documents.appendingPathComponent("Icons", isDirectory: true) }

    nonisolated static func url(forTitle title: String) -> URL {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let name = title.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespaces)
        return LibraryModel.documents.appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent((name.isEmpty ? "Game" : name) + ".png")
    }

    private static var running = false

    /// Makes the icon of every game that has none (or whose cover changed), and
    /// lets Shortcuts know the game list changed. Cheap when nothing is missing.
    static func refresh(_ entries: [LibraryEntry]) {
        guard !running else { return }
        running = true
        let games = entries.filter { $0.desktop != true }
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var made = 0
            for entry in games {
                let url = url(forTitle: entry.title)
                let stamp = "\(entry.coverFile ?? "")|\(entry.steamID ?? entry.steamAppID ?? 0)"
                if FileManager.default.fileExists(atPath: url.path), UserDefaults.standard.string(forKey: "icon:" + url.lastPathComponent) == stamp { continue }
                guard let png = await icon(for: entry) else { continue }
                try? png.write(to: url, options: .atomic)
                UserDefaults.standard.set(stamp, forKey: "icon:" + url.lastPathComponent)
                made += 1
            }
            if made > 0 { LogStore.shared.log("[game-shortcuts] \(made) icon(s) written to Icons/") }
            MadeiraShortcuts.updateAppShortcutParameters()
            running = false
        }
    }

    /// One game's icon now (Add to Home Screen on its details page).
    static func ensure(_ entry: LibraryEntry) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let png = await icon(for: entry) { try? png.write(to: url(forTitle: entry.title), options: .atomic) }
        MadeiraShortcuts.updateAppShortcutParameters()
    }

    /// A square app-style icon, 512 px.
    private static func icon(for entry: LibraryEntry) async -> Data? {
        let side: CGFloat = 512
        var cover: UIImage?
        if let file = entry.coverFile {
            cover = UIImage(contentsOfFile: LibraryModel.documents.appendingPathComponent("madeira-art/" + file).path)
        }
        var hero: UIImage?, logo: UIImage?
        if cover == nil, let id = entry.steamID ?? entry.steamAppID {
            hero = await steamImage(id, "library_hero.jpg")
            logo = await steamImage(id, "logo.png")
            if hero == nil || logo == nil { cover = await steamImage(id, "library_600x900.jpg") }
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: square.size, format: format).image { ctx in
            UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1).setFill()
            ctx.fill(square)
            if let hero, let logo, cover == nil {
                hero.draw(in: fill(hero.size, in: square))
                // The logo in the middle 80 %, shadowed so it reads on any background.
                ctx.cgContext.setShadow(offset: .zero, blur: 16, color: UIColor.black.withAlphaComponent(0.6).cgColor)
                logo.draw(in: fit(logo.size, in: square.insetBy(dx: side * 0.1, dy: side * 0.1)))
            } else if let cover {
                if let blurred = blur(cover) { blurred.draw(in: fill(cover.size, in: square)) }
                UIColor.black.withAlphaComponent(0.25).setFill(); ctx.fill(square)
                cover.draw(in: fit(cover.size, in: square))
            } else {
                let letters = entry.title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 200, weight: .bold), .foregroundColor: UIColor.white]
                let size = (letters as NSString).size(withAttributes: attrs)
                (letters as NSString).draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
            }
        }.pngData()
    }

    private static func steamImage(_ id: Int, _ name: String) async -> UIImage? {
        guard let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/\(name)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    private static func fill(_ size: CGSize, in r: CGRect) -> CGRect {
        let s = max(r.width / size.width, r.height / size.height)
        return CGRect(x: r.midX - size.width * s / 2, y: r.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
    }

    private static func fit(_ size: CGSize, in r: CGRect) -> CGRect {
        let s = min(r.width / size.width, r.height / size.height)
        return CGRect(x: r.midX - size.width * s / 2, y: r.midY - size.height * s / 2, width: size.width * s, height: size.height * s)
    }

    private static func blur(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image), let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(24, forKey: kCIInputRadiusKey)
        guard let output = f.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
