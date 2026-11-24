// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import PhotosUI

// iPhone games: games installed on the device as their own apps (Fortnite,
// Minecraft, Roblox...) listed in EmuPC's library as tiles that open them.
// iOS does not let one app run another inside it, and an app cannot list the
// apps installed beside it, so each tile holds how to open its game: the game's
// own link (roblox://), or the name of a Shortcut whose Open App action starts
// it, which works for any app. Saved in Documents/madeira-phone-games.json.
// Log tag: [phone-games] (never titles or links).

struct PhoneGame: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// The game's link ("roblox://"), or a Shortcut's name when viaShortcut.
    var link: String
    var viaShortcut: Bool
    /// A cover picked from Photos, in Documents/madeira-art/.
    var coverFile: String?
    var lastPlayed: Date?

    var url: URL? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if viaShortcut {
            var parts = URLComponents(string: "shortcuts://run-shortcut")
            parts?.queryItems = [URLQueryItem(name: "name", value: text)]
            return parts?.url
        }
        return URL(string: text.contains(":") ? text : text + "://")
    }

    var cover: UIImage? {
        coverFile.flatMap { UIImage(contentsOfFile: LibraryModel.documents.appendingPathComponent("madeira-art/" + $0).path) }
    }

    /// Games whose own link is known. Everything else opens through a Shortcut.
    static let knownLinks: [(title: String, link: String)] = [
        ("Minecraft", "minecraft://"),
        ("Roblox", "roblox://"),
    ]
}

@MainActor
final class PhoneGames: ObservableObject {
    static let shared = PhoneGames()

    @Published private(set) var games: [PhoneGame] = []
    /// Why the last tile did not open, for an alert.
    @Published var failure: String?

    private static var file: URL { LibraryModel.documents.appendingPathComponent("madeira-phone-games.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([PhoneGame].self, from: data) {
            games = saved
        }
    }

    /// Most recently played first, then by name.
    var sorted: [PhoneGame] {
        games.sorted {
            if $0.lastPlayed != $1.lastPlayed { return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func save(_ game: PhoneGame) {
        if let i = games.firstIndex(where: { $0.id == game.id }) { games[i] = game } else { games.append(game) }
        write()
    }

    func remove(_ id: UUID) {
        if let cover = games.first(where: { $0.id == id })?.coverFile {
            try? FileManager.default.removeItem(at: LibraryModel.documents.appendingPathComponent("madeira-art/" + cover))
        }
        games.removeAll { $0.id == id }
        write()
    }

    func open(_ game: PhoneGame) {
        guard let url = game.url else {
            failure = "\(game.title) has no link or Shortcut yet. Edit it and add one."
            return
        }
        let shortcut = game.viaShortcut
        UIApplication.shared.open(url) { [weak self] ok in
            LogStore.shared.log("[phone-games] open shortcut=\(shortcut ? 1 : 0) ok=\(ok ? 1 : 0)")
            guard let self else { return }
            if ok {
                if var played = self.games.first(where: { $0.id == game.id }) {
                    played.lastPlayed = Date()
                    self.save(played)
                }
            } else {
                self.failure = shortcut
                    ? "The Shortcuts app didn't open."
                    : "\(game.title) didn't open. Check that it's installed, or open it with a Shortcut instead (edit the tile)."
            }
        }
    }

    /// Saves a picked cover as a JPEG in madeira-art and returns its file name.
    func storeCover(_ image: UIImage, for id: UUID) -> String? {
        let folder = LibraryModel.documents.appendingPathComponent("madeira-art", isDirectory: true)
        let name = "phone-\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).jpg"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            LogStore.shared.log("[phone-games] cover was not saved: \(error.localizedDescription)")
            return nil
        }
    }

    private func write() {
        do {
            try JSONEncoder().encode(games).write(to: Self.file, options: .atomic)
        } catch {
            LogStore.shared.log("[phone-games] list was not saved: \(error.localizedDescription)")
        }
    }
}

// MARK: - Tile

/// A 2:3 tile: the picked cover, or the game's name on a gradient.
struct PhoneGameTile: View {
    let game: PhoneGame

    var body: some View {
        ZStack {
            if let cover = game.cover {
                Image(uiImage: cover).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Self.tint(for: game.title), .black.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 30, weight: .semibold))
                    Text(game.title)
                        .font(.headline.weight(.heavy))
                        .multilineTextAlignment(.center)
                        .lineLimit(3).minimumScaleFactor(0.6)
                        .padding(.horizontal, 8)
                }
                .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(6).background(.black.opacity(0.45), in: Circle())
                .padding(6)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.title)
        .accessibilityHint("Opens the app")
    }

    /// A steady colour per title, so tiles without covers differ.
    static func tint(for title: String) -> Color {
        let hues: [Double] = [0.58, 0.0, 0.33, 0.08, 0.75, 0.5, 0.92]
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hue: hues[abs(sum) % hues.count], saturation: 0.65, brightness: 0.55)
    }
}

// MARK: - Touch library row

/// "iPhone games" in the touch library: the tiles in one row, + to add one,
/// a long press to edit. A fixed height, so the zoomable page's cached header
/// height stays right as games are added.
struct PhoneGamesRow: View {
    @ObservedObject private var model = PhoneGames.shared
    @State private var editing: PhoneGame?

    static let height: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("iPhone games").font(.title3.weight(.bold))
                Spacer()
                Button { editing = PhoneGame(title: "", link: "", viaShortcut: true) } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.bordered).buttonBorderShape(.circle)
                .accessibilityLabel("Add iPhone game")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if model.games.isEmpty {
                        Button { editing = PhoneGame(title: "", link: "", viaShortcut: true) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "iphone.gen3.badge.plus").font(.title2)
                                Text("Open Fortnite, Minecraft and other games on this iPhone from EmuPC")
                                    .font(.subheadline).multilineTextAlignment(.leading)
                            }
                            .padding(14)
                            .frame(maxWidth: 320, maxHeight: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(model.sorted) { game in
                        Button { model.open(game) } label: {
                            PhoneGameTile(game: game)
                                .frame(width: 70, height: 105)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { editing = game } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { model.remove(game.id) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }
            .frame(height: 105)
        }
        .frame(height: Self.height, alignment: .top)
        .sheet(item: $editing) { game in PhoneGameEditor(game: game) }
        .alert("Couldn't open the game", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.failure ?? "") }
    }
}

// MARK: - Add / edit

struct PhoneGameEditor: View {
    @State var game: PhoneGame
    @ObservedObject private var model = PhoneGames.shared
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var cover: UIImage?

    private var isNew: Bool { !model.games.contains { $0.id == game.id } }
    private var canSave: Bool {
        !game.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !game.link.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $game.title)
                        .textInputAutocapitalization(.words)
                        .onChange(of: game.title) { old, new in
                            // The Shortcut's name follows the game's until it's typed in.
                            if game.viaShortcut, game.link == old { game.link = new }
                        }
                } footer: {
                    Text("EmuPC opens the game as its own app. iOS doesn't let one app run another inside it.")
                }

                Section {
                    Picker("Open with", selection: $game.viaShortcut) {
                        Text("Shortcut").tag(true)
                        Text("App link").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if game.viaShortcut {
                        TextField("Shortcut name", text: $game.link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        TextField("Link, e.g. roblox://", text: $game.link)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(PhoneGame.knownLinks, id: \.link) { known in
                                    Button(known.title) {
                                        game.link = known.link
                                        if game.title.isEmpty { game.title = known.title }
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                } header: {
                    Text("How EmuPC opens it")
                } footer: {
                    if game.viaShortcut {
                        Text("Works with any app. In the Shortcuts app, make a new shortcut with the **Open App** action, choose the game, and give the shortcut this name.")
                    } else {
                        Text("Only works if the game has its own link. If it doesn't open, use a Shortcut instead.")
                    }
                }

                Section {
                    if game.viaShortcut {
                        Button { open("shortcuts://create-shortcut") } label: { Label("Make the Shortcut", systemImage: "square.2.layers.3d") }
                    }
                    Button { model.open(game) } label: { Label("Test", systemImage: "play.fill") }
                        .disabled(!canSave)
                }

                Section("Cover") {
                    HStack(spacing: 14) {
                        PhoneGameTile(game: game)
                            .overlay { if let cover { Image(uiImage: cover).resizable().scaledToFill() } }
                            .frame(width: 60, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label(game.coverFile == nil && cover == nil ? "Choose a cover" : "Change cover", systemImage: "photo")
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button("Remove from EmuPC", role: .destructive) {
                            model.remove(game.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add iPhone game" : game.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let cover, let file = model.storeCover(cover, for: game.id) {
                            if let old = game.coverFile, old != file {
                                try? FileManager.default.removeItem(at: LibraryModel.documents.appendingPathComponent("madeira-art/" + old))
                            }
                            game.coverFile = file
                        }
                        game.title = game.title.trimmingCharacters(in: .whitespaces)
                        model.save(game)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: photo) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        cover = image
                    }
                }
            }
        }
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
}
