// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// EmuPC: a keyboard typed with the controller, for games that ask for a name,
// a chat line or a server address while there is no touch keyboard at hand.
//
//   - Opened by clicking both sticks (L3 + R3) in a game, from the in-game
//     guide (Keyboard) or the session menu when a controller is connected;
//     without one the iOS keyboard opens instead.
//   - D-pad or stick moves, A types the key, B deletes, Y is space, X is
//     Shift, Menu is Enter, LB switches to symbols, RB types @, the Xbox
//     button, L3 + R3 or Done closes it. Keys can be tapped too.
//   - Full width and low, like a console keyboard: letters with numbers,
//     @ . _ - on the first layer, every other symbol on the second (#+=).
//   - Keys go to the game as key presses (winios_post_key), the same path the
//     iOS keyboard uses.
//
// Log tag: [pad-keyboard].

@MainActor
final class ControllerKeyboard: ObservableObject {
    static let shared = ControllerKeyboard()

    @Published private(set) var open = false
    @Published var row = 1
    @Published var column = 0
    @Published var shift = false
    /// The symbols layer (#+=) instead of letters.
    @Published var symbols = false

    /// A key: what it shows and what it does.
    enum Key: Hashable {
        case char(Character), shift, space, backspace, enter, escape, tab, done, layer

        /// In key widths; every row adds up to 11.
        var width: CGFloat {
            switch self {
            case .space: return 4
            case .enter: return 2
            case .char, .escape, .tab: return 1
            default: return 1.5
            }
        }
    }

    static let columns: CGFloat = 11

    private static func chars(_ text: String) -> [Key] { text.map { .char($0) } }
    private static let bottom: [Key] = [.layer, .escape, .tab, .space, .enter, .done]
    private static let letters: [[Key]] = [
        chars("1234567890-"),
        chars("qwertyuiop@"),
        chars("asdfghjkl._"),
        [.shift] + chars("zxcvbnm,") + [.backspace],
        bottom,
    ]
    private static let symbolRows: [[Key]] = [
        chars("!@#$%^&*()="),
        chars("~`+[]{}\\|:;"),
        chars("\"'<>?/-_.,!"),
        [.shift] + chars("1234567.") + [.backspace],
        bottom,
    ]
    var rows: [[Key]] { symbols ? Self.symbolRows : Self.letters }

    private init() {}

    /// The guide's Keyboard: this one with a controller, the iOS keyboard without.
    static func openForSession() {
        if LibraryController.shared.connected { shared.show() } else { LibraryKeyboard.show() }
    }

    func show() {
        guard !open else { return }
        LibraryKeyboard.hide()
        row = 1; column = 0
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { open = true }
        LogStore.shared.log("[pad-keyboard] opened")
    }

    func hide() {
        guard open else { return }
        if shift { shift = false }
        symbols = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { open = false }
        LogStore.shared.log("[pad-keyboard] closed")
    }

    /// Controller input while the keyboard is open.
    func handle(_ command: String) {
        switch command {
        case "up": move(rowBy: -1)
        case "down": move(rowBy: 1)
        case "left": column = (column + rows[row].count - 1) % rows[row].count; tick()
        case "right": column = (column + 1) % rows[row].count; tick()
        case "accept": press(rows[row][column])
        case "back": press(.backspace)
        case "add": press(.space)
        case "x": press(.shift)
        case "menu": press(.enter)
        case "tabBack": press(.layer)
        case "tab": press(.char("@"))
        case "guide", "keyboard": hide()
        default: break
        }
    }

    /// Up and down keep the column's position across rows of different lengths.
    private func move(rowBy delta: Int) {
        let next = min(max(row + delta, 0), rows.count - 1)
        guard next != row else { return }
        let fraction = (Double(column) + 0.5) / Double(rows[row].count)
        row = next
        column = min(Int(fraction * Double(rows[row].count)), rows[row].count - 1)
        tick()
    }

    func press(_ key: Key) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch key {
        case .char(let c):
            let ch = shift ? Character(c.uppercased()) : c
            guard let (vk, needsShift) = MetalBackedView.vkForChar(ch) else { return }
            if needsShift { winios_post_key(0x10, 1) }
            tap(vk)
            if needsShift { winios_post_key(0x10, 0) }
            if shift { shift = false }
        case .shift: shift.toggle()
        case .space: tap(0x20)
        case .backspace: tap(0x08)
        case .enter: tap(0x0D)
        case .escape: tap(0x1B)
        case .tab: tap(0x09)
        case .done: hide()
        case .layer: symbols.toggle(); column = min(column, rows[row].count - 1)
        }
    }

    private func tap(_ vk: Int32) { winios_post_key(vk, 1); winios_post_key(vk, 0) }

    private let selection = UISelectionFeedbackGenerator()
    private func tick() { selection.selectionChanged() }
}

/// The keyboard panel along the bottom of the game: as wide as the screen allows, low.
struct ControllerKeyboardView: View {
    @ObservedObject private var keyboard = ControllerKeyboard.shared
    private let spacing: CGFloat = 6
    private let keyHeight: CGFloat = 34

    var body: some View {
        if keyboard.open {
            let screen = UIScreen.main.bounds.width
            let margins = IslandMargins.current()
            let width = min(screen - margins.leading - margins.trailing, 980)
            let unit = (width - 24 - spacing * (ControllerKeyboard.columns - 1)) / ControllerKeyboard.columns
            VStack(spacing: spacing) {
                ForEach(keyboard.rows.indices, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(keyboard.rows[r].indices, id: \.self) { c in
                            let key = keyboard.rows[r][c]
                            keyView(key, focused: keyboard.row == r && keyboard.column == c)
                                .frame(width: unit * key.width + spacing * (key.width - 1), height: keyHeight)
                                .onTapGesture { keyboard.row = r; keyboard.column = c; keyboard.press(key) }
                        }
                    }
                }
                HStack(spacing: 14) {
                    ButtonHint(glyph: "a.circle.fill", label: "Type")
                    ButtonHint(glyph: "b.circle.fill", label: "Delete")
                    ButtonHint(glyph: "y.circle.fill", label: "Space")
                    ButtonHint(glyph: "x.circle.fill", label: "Shift")
                    ButtonHint(glyph: "line.3.horizontal.circle.fill", label: "Enter")
                    Text("LB #+=   RB @").foregroundStyle(.white.opacity(0.7))
                }
                .font(.caption2)
            }
            .padding(12)
            .frame(width: width)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            .environment(\.colorScheme, .dark)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func keyView(_ key: ControllerKeyboard.Key, focused: Bool) -> some View {
        Group {
            switch key {
            case .char(let c): Text(String(keyboard.shift ? Character(c.uppercased()) : c)).font(.body.weight(.medium))
            case .shift: Image(systemName: keyboard.shift ? "shift.fill" : "shift")
            case .space: Text("space").font(.footnote)
            case .backspace: Image(systemName: "delete.left")
            case .enter: Label("enter", systemImage: "return").font(.footnote)
            case .escape: Text("esc").font(.footnote)
            case .tab: Text("tab").font(.footnote)
            case .done: Image(systemName: "keyboard.chevron.compact.down")
            case .layer: Text(keyboard.symbols ? "ABC" : "#+=").font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(focused ? .black : .white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(focused ? Color.white : Color.white.opacity(isAction(key) ? 0.2 : 0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .scaleEffect(focused ? 1.06 : 1)
        .shadow(color: focused ? .white.opacity(0.35) : .clear, radius: 6)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: focused)
    }

    private func isAction(_ key: ControllerKeyboard.Key) -> Bool {
        if case .char = key { return false }
        return true
    }
}
