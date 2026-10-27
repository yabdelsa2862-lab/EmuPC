// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import PhotosUI
import SwiftUI

// MABD local: the controller home's look, console style. An accent colour for
// focus and selection, a background behind the home, and a startup animation
// when Madeira opens in the controller interface. Settings › Theme (controller
// and touch) chooses; stored in UserDefaults.

enum ThemeAccent: String, CaseIterable, Identifiable {
    case green, blue, purple, pink, red, orange, yellow, teal, white
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .green: return Color(red: 0.06, green: 0.73, blue: 0.27)
        case .blue: return Color(red: 0.0, green: 0.47, blue: 0.95)
        case .purple: return Color(red: 0.55, green: 0.32, blue: 0.95)
        case .pink: return Color(red: 0.96, green: 0.3, blue: 0.62)
        case .red: return Color(red: 0.92, green: 0.2, blue: 0.22)
        case .orange: return Color(red: 0.98, green: 0.52, blue: 0.1)
        case .yellow: return Color(red: 0.98, green: 0.8, blue: 0.12)
        case .teal: return Color(red: 0.0, green: 0.7, blue: 0.72)
        case .white: return .white
        }
    }
    /// Text on the accent: dark on the light accents.
    var onAccent: Color { [.yellow, .white].contains(self) ? .black : .white }
}

enum ThemeBackground: String, CaseIterable, Identifiable {
    case gameArt, waves, orbs, aurora, particles, glow, dark, photo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gameArt: return "Game art"
        case .waves: return "Waves"
        case .orbs: return "Orbs"
        case .aurora: return "Aurora"
        case .particles: return "Particles"
        case .glow: return "Accent glow"
        case .dark: return "Dark"
        case .photo: return "Your photo"
        }
    }
}

final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()
    static let accentKey = "madeiraThemeAccent", backgroundKey = "madeiraThemeBackground", startupKey = "madeiraStartupAnimation"

    @Published var accent: ThemeAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey) }
    }
    @Published var background: ThemeBackground {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: Self.backgroundKey) }
    }
    @Published var startup: Bool {
        didSet { UserDefaults.standard.set(startup, forKey: Self.startupKey) }
    }
    /// The photo behind the home (Background: Your photo).
    @Published private(set) var photo: UIImage?
    static var photoURL: URL { LibraryModel.documents.appendingPathComponent("madeira-background.jpg") }

    func setPhoto(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: Self.photoURL); photo = nil
            if background == .photo { background = .waves }
            return
        }
        // Long side 2048 px.
        let scale = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: Self.photoURL, options: .atomic)
        photo = resized
        background = .photo
    }

    init() {
        let d = UserDefaults.standard
        accent = d.string(forKey: Self.accentKey).flatMap(ThemeAccent.init(rawValue:)) ?? .green
        background = d.string(forKey: Self.backgroundKey).flatMap(ThemeBackground.init(rawValue:)) ?? .gameArt
        startup = d.object(forKey: Self.startupKey) as? Bool ?? true
        photo = UIImage(contentsOfFile: Self.photoURL.path)
    }

    func cycleAccent(_ d: Int) {
        let all = ThemeAccent.allCases
        let i = all.firstIndex(of: accent) ?? 0
        accent = all[(i + (d < 0 ? all.count - 1 : 1)) % all.count]
    }

    func cycleBackground(_ d: Int) {
        // Your photo only once one is chosen (touch Settings › Theme).
        let all = ThemeBackground.allCases.filter { $0 != .photo || photo != nil }
        let i = all.firstIndex(of: background) ?? 0
        background = all[(i + (d < 0 ? all.count - 1 : 1)) % all.count]
    }
}

/// The home's background when it is not game art.
struct ThemeBackdrop: View {
    @ObservedObject private var theme = ThemeSettings.shared

    /// Used for Game art when there is no art to show (no games yet).
    var fallback: ThemeBackground = .waves

    var body: some View {
        let style = theme.background == .gameArt ? fallback : theme.background
        switch style {
        case .gameArt, .dark:
            Color.black
        case .photo:
            if let photo = theme.photo {
                GeometryReader { g in
                    Image(uiImage: photo).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                }
            } else { Color.black }
        case .waves:
            // Flowing light bands over deep blue, in the spirit of a console's home.
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .linearGradient(Gradient(colors: [Color(red: 0.02, green: 0.05, blue: 0.2), Color(red: 0.0, green: 0.18, blue: 0.5)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                    for band in 0..<5 {
                        var path = Path()
                        let phase = t * (0.25 + Double(band) * 0.07) + Double(band)
                        let baseY = size.height * (0.45 + Double(band) * 0.08)
                        path.move(to: CGPoint(x: 0, y: baseY))
                        for x in stride(from: 0.0, through: size.width, by: 8) {
                            let y = baseY + sin(x / size.width * .pi * 2 * (1.2 + Double(band) * 0.15) + phase) * size.height * 0.06
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        ctx.stroke(path, with: .color(.white.opacity(0.10 + Double(band) * 0.03)), lineWidth: 1.5 + Double(band))
                    }
                }
            }
        case .orbs:
            // Soft glowing spheres in the accent colour.
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Color(red: 0.02, green: 0.04, blue: 0.03)
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(RadialGradient(colors: [theme.accent.color.opacity(0.75), theme.accent.color.opacity(0)], center: .center, startRadius: 0, endRadius: 220))
                            .frame(width: 440, height: 440)
                            .offset(x: cos(t / Double(9 + i * 3) + Double(i)) * 320, y: sin(t / Double(11 + i * 2) + Double(i) * 2) * 160)
                            .blendMode(.screen)
                    }
                }
            }
        case .particles:
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.03, green: 0.03, blue: 0.08)))
                    for i in 0..<80 {
                        let seed = Double(i) * 12.9898
                        let x = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
                        let speed = 0.01 + abs(cos(seed)) * 0.03
                        let y = (abs((cos(seed * 1.7) * 2378.13).truncatingRemainder(dividingBy: 1)) - t * speed).truncatingRemainder(dividingBy: 1)
                        let px = abs(x) * size.width, py = (y < 0 ? y + 1 : y) * size.height
                        let r = 1 + abs(sin(seed * 3)) * 2.5
                        ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: r, height: r)),
                                 with: .color((i % 3 == 0 ? theme.accent.color : .white).opacity(0.35 + abs(sin(t + seed)) * 0.4)))
                    }
                }
            }
        case .glow:
            ZStack {
                Color.black
                RadialGradient(colors: [theme.accent.color.opacity(0.55), .clear], center: .topTrailing, startRadius: 20, endRadius: 700)
                RadialGradient(colors: [theme.accent.color.opacity(0.25), .clear], center: .bottomLeading, startRadius: 10, endRadius: 500)
            }
        case .aurora:
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Color.black
                    Circle().fill(theme.accent.color.opacity(0.5)).frame(width: 700).blur(radius: 140)
                        .offset(x: cos(t / 7) * 260, y: sin(t / 9) * 120 - 120)
                    Circle().fill(Color.blue.opacity(0.35)).frame(width: 600).blur(radius: 150)
                        .offset(x: sin(t / 11) * 300, y: cos(t / 8) * 140 + 80)
                    Circle().fill(Color.purple.opacity(0.3)).frame(width: 500).blur(radius: 130)
                        .offset(x: cos(t / 13) * -280, y: sin(t / 10) * 100)
                }
            }
        }
    }
}

/// The startup animation: the mark draws in, glows, and the home fades up.
struct StartupAnimation: View {
    var finished: () -> Void
    @ObservedObject private var theme = ThemeSettings.shared
    @State private var ring: CGFloat = 0
    @State private var mark = false
    @State private var glow = false
    @State private var title = false
    @State private var fade = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [theme.accent.color.opacity(glow ? 0.45 : 0), .clear], center: .center, startRadius: 10, endRadius: glow ? 520 : 60)
                .ignoresSafeArea()
            VStack(spacing: 26) {
                ZStack {
                    Circle().trim(from: 0, to: ring)
                        .stroke(theme.accent.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 120, height: 120)
                        .shadow(color: theme.accent.color.opacity(0.9), radius: glow ? 30 : 0)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 52, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(mark ? 1 : 0.4)
                        .opacity(mark ? 1 : 0)
                }
                Text("EMUPC")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .tracking(title ? 12 : 2)
                    .foregroundStyle(.white)
                    .opacity(title ? 1 : 0)
            }
        }
        .opacity(fade ? 0 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7)) { ring = 1 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.45)) { mark = true }
            withAnimation(.easeOut(duration: 0.6).delay(0.6)) { glow = true }
            withAnimation(.easeOut(duration: 0.7).delay(0.8)) { title = true }
            withAnimation(.easeIn(duration: 0.45).delay(1.9)) { fade = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { finished() }
        }
        .accessibilityLabel("EmuPC")
    }
}

/// Settings › Theme in the touch library.
struct ThemeSettingsSection: View {
    @ObservedObject private var theme = ThemeSettings.shared

    var body: some View {
        Section {
            Picker("Accent", selection: $theme.accent) {
                ForEach(ThemeAccent.allCases) { a in
                    Label { Text(a.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(a.color) }.tag(a)
                }
            }
            Picker("Background", selection: $theme.background) {
                ForEach(ThemeBackground.allCases.filter { $0 != .photo || theme.photo != nil }) { Text($0.label).tag($0) }
            }
            Button {
                PhotoPick.present { theme.setPhoto($0) }
            } label: {
                Label(theme.photo == nil ? "Use your own photo…" : "Change background photo", systemImage: "photo")
            }
            if theme.photo != nil {
                Button("Remove background photo", role: .destructive) { theme.setPhoto(nil) }
            }
            Toggle("Startup animation", isOn: $theme.startup)
        } header: { Text("Theme") } footer: {
            Text("The controller home's colours and background, and the animation when EmuPC opens with a controller. With Game art, a game without art (or no games yet) shows Waves.")
        }
    }
}
