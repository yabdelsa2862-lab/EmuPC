// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MABD local: the player's profile, console style. A name and a picture (a photo
// or one of the built-in avatars), shown in the controller home's top bar and
// guide, set up in onboarding and Settings › Profile. The profile page sums up
// the library: games installed, their size, the last one played, and which
// stores are signed in.

final class ProfileSettings: ObservableObject {
    static let shared = ProfileSettings()
    static let nameKey = "madeiraProfileName", avatarKey = "madeiraProfileAvatar"

    struct Avatar { let symbol: String; let color: Color }
    static let avatars: [Avatar] = [
        Avatar(symbol: "gamecontroller.fill", color: Color(red: 0.06, green: 0.73, blue: 0.27)),
        Avatar(symbol: "bolt.fill", color: Color(red: 0.0, green: 0.47, blue: 0.95)),
        Avatar(symbol: "flame.fill", color: Color(red: 0.98, green: 0.45, blue: 0.1)),
        Avatar(symbol: "star.fill", color: Color(red: 0.98, green: 0.78, blue: 0.1)),
        Avatar(symbol: "crown.fill", color: Color(red: 0.55, green: 0.32, blue: 0.95)),
        Avatar(symbol: "moon.stars.fill", color: Color(red: 0.2, green: 0.25, blue: 0.6)),
        Avatar(symbol: "hare.fill", color: Color(red: 0.96, green: 0.3, blue: 0.62)),
        Avatar(symbol: "leaf.fill", color: Color(red: 0.0, green: 0.62, blue: 0.5)),
        Avatar(symbol: "sparkles", color: Color(red: 0.0, green: 0.7, blue: 0.72)),
        Avatar(symbol: "skull.fill", color: Color(red: 0.25, green: 0.25, blue: 0.28)),
    ]

    @Published var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }
    /// The built-in avatar; ignored while a photo is set.
    @Published var avatar: Int {
        didSet { UserDefaults.standard.set(avatar, forKey: Self.avatarKey) }
    }
    @Published private(set) var photo: UIImage?

    static var photoURL: URL { LibraryModel.documents.appendingPathComponent("madeira-profile.jpg") }

    init() {
        name = UserDefaults.standard.string(forKey: Self.nameKey) ?? "Player 1"
        avatar = UserDefaults.standard.integer(forKey: Self.avatarKey)
        photo = UIImage(contentsOfFile: Self.photoURL.path)
    }

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Player 1" : name }

    func setPhoto(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: Self.photoURL)
            photo = nil
            return
        }
        // A square, 512 px, is plenty for the avatar.
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
        let square = renderer.image { _ in
            image.draw(in: CGRect(x: -crop.minX * 512 / side, y: -crop.minY * 512 / side,
                                  width: image.size.width * 512 / side, height: image.size.height * 512 / side))
        }
        try? square.jpegData(compressionQuality: 0.85)?.write(to: Self.photoURL, options: .atomic)
        photo = square
    }

    func cycleAvatar(_ d: Int) {
        if photo != nil { setPhoto(nil) }
        avatar = (avatar + (d < 0 ? Self.avatars.count - 1 : 1)) % Self.avatars.count
    }
}

struct ProfileAvatar: View {
    var size: CGFloat
    @ObservedObject private var profile = ProfileSettings.shared

    var body: some View {
        Group {
            if let photo = profile.photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                let a = ProfileSettings.avatars[min(profile.avatar, ProfileSettings.avatars.count - 1)]
                ZStack {
                    Circle().fill(a.color.gradient)
                    Image(systemName: a.symbol).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: max(2, size / 20)))
    }
}

/// Name, photo and built-in avatars (onboarding and Settings › Profile).
struct ProfileEditor: View {
    @ObservedObject private var profile = ProfileSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ProfileAvatar(size: 76)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Your name", text: $profile.name)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                    HStack {
                        Button {
                            PhotoPick.present { profile.setPhoto($0) }
                        } label: {
                            Label(profile.photo == nil ? "Choose a photo" : "Change photo", systemImage: "photo")
                        }
                        if profile.photo != nil {
                            Button("Remove", role: .destructive) { profile.setPhoto(nil) }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            Text("Or pick an avatar").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                ForEach(ProfileSettings.avatars.indices, id: \.self) { i in
                    let a = ProfileSettings.avatars[i]
                    ZStack {
                        Circle().fill(a.color.gradient)
                        Image(systemName: a.symbol).font(.title3.weight(.bold)).foregroundStyle(.white)
                    }
                    .frame(width: 50, height: 50)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: profile.photo == nil && profile.avatar == i ? 3 : 0).padding(-4))
                    .onTapGesture { profile.setPhoto(nil); profile.avatar = i }
                }
            }
        }
    }
}

/// Settings › Profile in the touch library.
struct ProfileSettingsSection: View {
    var body: some View {
        Section { ProfileEditor().padding(.vertical, 6) } header: { Text("Profile") } footer: {
            Text("Shown in the controller home and its guide.")
        }
    }
}

/// The profile page's controller focus (ControllerHome drives it).
final class ProfilePageModel: ObservableObject {
    static let shared = ProfilePageModel()
    /// 0 name, 1 photo, 2 avatar.
    @Published var focus = 0
    @Published var editingName = false
    @Published var pickingPhoto = false
    static let rows = 3

    func command(_ c: String, profile: ProfileSettings, close: () -> Void) {
        switch c {
        case "up": focus = max(focus - 1, 0)
        case "down": focus = min(focus + 1, Self.rows - 1)
        case "left": if focus == 2 { profile.cycleAvatar(-1) }
        case "right": if focus == 2 { profile.cycleAvatar(1) }
        case "accept":
            switch focus {
            case 0: editingName = true
            case 1: pickingPhoto = true
            default: profile.cycleAvatar(1)
            }
        case "back", "menu": editingName = false; close()
        default: break
        }
    }
}

/// The profile page in the controller home: who you are, what you have, and
/// changing your name, photo or avatar (touch or controller).
struct ProfilePage: View {
    var close: () -> Void
    @ObservedObject private var profile = ProfileSettings.shared
    @ObservedObject private var page = ProfilePageModel.shared
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var theme = ThemeSettings.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @FocusState private var nameField: Bool

    private var games: [LibraryEntry] { model.entries.filter { $0.desktop != true } }
    private var totalBytes: Int64 { games.compactMap(\.folderBytes).reduce(0, +) }
    private var lastPlayed: LibraryEntry? { games.filter { $0.lastPlayed != nil }.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) } }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.7).ignoresSafeArea().onTapGesture { nameField = false; close() }
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 26) {
                        // Left: who you are, and changing it.
                        VStack(spacing: 12) {
                            ProfileAvatar(size: min(110, geo.size.height * 0.24))
                            row(0, title: "Name") {
                                TextField("Your name", text: $profile.name)
                                    .focused($nameField)
                                    .submitLabel(.done)
                                    .onSubmit { page.editingName = false }
                                    .multilineTextAlignment(.trailing)
                                    .font(.headline)
                            }
                            row(1, title: "Photo") {
                                Text(profile.photo == nil ? "Choose…" : "Change…").font(.headline)
                            }
                            .onTapGesture { page.focus = 1; page.pickingPhoto = true }
                            row(2, title: "Avatar") {
                                HStack(spacing: 10) {
                                    Image(systemName: "chevron.left").onTapGesture { profile.cycleAvatar(-1) }
                                    Text(profile.photo == nil ? "\(profile.avatar + 1) of \(ProfileSettings.avatars.count)" : "Photo")
                                        .font(.headline).monospacedDigit()
                                    Image(systemName: "chevron.right").onTapGesture { profile.cycleAvatar(1) }
                                }
                            }
                            if profile.photo != nil {
                                Button("Remove photo", role: .destructive) { profile.setPhoto(nil) }.font(.subheadline)
                            }
                        }
                        .frame(width: min(330, geo.size.width * 0.42))
                        // Right: what you have.
                        VStack(alignment: .leading, spacing: 12) {
                            Text(profile.displayName).font(.largeTitle.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.5)
                            HStack(spacing: 10) {
                                stat("\(games.count)", "games")
                                stat(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file), "installed")
                            }
                            stat(lastPlayed?.title ?? "—", "last played")
                            HStack(spacing: 8) {
                                account("Steam", steam.signedIn)
                                account("GOG", gog.signedIn)
                                account("Epic", epic.signedIn)
                            }
                            HStack(spacing: 20) {
                                ButtonHint(glyph: "a.circle.fill", label: page.focus == 2 ? "Next avatar" : "Change")
                                ButtonHint(glyph: "b.circle.fill", label: "Close")
                            }
                            .padding(.top, 4)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(theme.accent.color.opacity(0.6), lineWidth: 2))
                    .frame(maxWidth: 820)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        .onChange(of: page.editingName) { _, on in nameField = on }
        .onChange(of: nameField) { _, on in if !on { page.editingName = false } }
        .onChange(of: page.pickingPhoto) { _, on in
            guard on else { return }
            page.pickingPhoto = false
            PhotoPick.present { profile.setPhoto($0) }
        }
    }

    private func row<Value: View>(_ index: Int, title: String, @ViewBuilder value: () -> Value) -> some View {
        let on = page.focus == index
        return HStack {
            Text(title).font(.headline)
            Spacer(minLength: 12)
            value()
        }
        .foregroundStyle(on ? theme.accent.onAccent : .white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(on ? theme.accent.color : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { page.focus = index; if index == 0 { page.editingName = true } }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func account(_ name: String, _ on: Bool) -> some View {
        Label(name, systemImage: on ? "checkmark.circle.fill" : "circle")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(on ? theme.accent.color : .white.opacity(0.5))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}


/// MABD local: the system photo picker, presented from the top of the key
/// window rather than from a SwiftUI view, so it opens from any overlay (the
/// controller home's profile page sits in a ZStack, where `.photosPicker`
/// did not reliably open or deliver). Loads the image itself (HEIC and iCloud
/// photos included) and logs a failure instead of dropping it.
@MainActor
enum PhotoPick {
    /// A picker is up: the controller home ignores pad commands meanwhile.
    static var showing: Bool { live != nil }
    private static var live: Delegate?

    static func present(_ done: @escaping (Data) -> Void) {
        guard live == nil else { return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        let delegate = Delegate(done: done)
        picker.delegate = delegate
        guard let top = topController() else {
            LogStore.shared.log("[photo] no window to present the picker from")
            return
        }
        live = delegate
        top.present(picker, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    final class Delegate: NSObject, PHPickerViewControllerDelegate {
        let done: (Data) -> Void
        init(done: @escaping (Data) -> Void) { self.done = done }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            PhotoPick.live = nil
            guard let provider = results.first?.itemProvider else { return }
            let done = self.done
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    let data = (object as? UIImage)?.jpegData(compressionQuality: 0.92)
                    DispatchQueue.main.async {
                        if let data { done(data) } else { LogStore.shared.log("[photo] could not load the image: \(error?.localizedDescription ?? "no image")") }
                    }
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    DispatchQueue.main.async {
                        if let data { done(data) } else { LogStore.shared.log("[photo] could not load the image: \(error?.localizedDescription ?? "no data")") }
                    }
                }
            }
        }
    }
}
