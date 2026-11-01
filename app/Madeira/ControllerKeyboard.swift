// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// EmuPC: a keyboard typed with the controller, for games that ask for a name,
// a chat line or a server address while there is no touch keyboard at hand.
//
//   - Opened from the in-game guide (Keyboard) or the session menu when a
//     controller is connected; without one the iOS keyboard opens instead.
//   - D-pad or stick moves, A types the key, B deletes, Y is space, X is
//     Shift, Menu is Enter, LB/RB move the game's cursor, the Xbox button
//     (or Done) closes it. Keys can be tapped too.
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

    /// A key: what it shows and what it does.
    enum Key: Hashable {
        case char(Character), shift, space, backspace, enter, escape, tab, done

        var width: CGFloat {
            switch self {
            case .space: return 4
            case .char: return 1
            default: return 1.5
            }
        }
    }

    let rows: [[Key]] = [
        Array("1234567890").map { .char($0) },
        Array("qwertyuiop").map { .char($0) },
        Array("asdfghjkl'").map { .char($0) },
        Array("zxcvbnm,.-").map { .char($0) },
        [.escape, .tab, .shift, .space, .backspace, .enter, .done],
    ]

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
        case "tabBack": tap(0x25)   // VK_LEFT
        case "tab": tap(0x27)       // VK_RIGHT
        case "guide": hide()
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
        }
    }

    private func tap(_ vk: Int32) { winios_post_key(vk, 1); winios_post_key(vk, 0) }

    private let selection = UISelectionFeedbackGenerator()
    private func tick() { selection.selectionChanged() }
}

/// The keyboard panel along the bottom of the game.
struct ControllerKeyboardView: View {
    @ObservedObject private var keyboard = ControllerKeyboard.shared

    var body: some View {
        if keyboard.open {
            VStack(spacing: 10) {
                ForEach(keyboard.rows.indices, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(keyboard.rows[r].indices, id: \.self) { c in
                            keyView(keyboard.rows[r][c], focused: keyboard.row == r && keyboard.column == c)
                                .onTapGesture { keyboard.row = r; keyboard.column = c; keyboard.press(keyboard.rows[r][c]) }
                        }
                    }
                }
                HStack(spacing: 16) {
                    ButtonHint(glyph: "a.circle.fill", label: "Type")
                    ButtonHint(glyph: "b.circle.fill", label: "Delete")
                    ButtonHint(glyph: "y.circle.fill", label: "Space")
                    ButtonHint(glyph: "x.circle.fill", label: "Shift")
                    ButtonHint(glyph: "line.3.horizontal.circle.fill", label: "Enter")
                }
                .font(.caption)
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: 640)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            .environment(\.colorScheme, .dark)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func keyView(_ key: ControllerKeyboard.Key, focused: Bool) -> some View {
        Group {
            switch key {
            case .char(let c): Text(String(keyboard.shift ? Character(c.uppercased()) : c)).font(.title3.weight(.medium))
            case .shift: Image(systemName: keyboard.shift ? "shift.fill" : "shift")
            case .space: Text("space").font(.subheadline)
            case .backspace: Image(systemName: "delete.left")
            case .enter: Image(systemName: "return")
            case .escape: Text("esc").font(.subheadline)
            case .tab: Image(systemName: "arrow.right.to.line")
            case .done: Image(systemName: "keyboard.chevron.compact.down")
            }
        }
        .foregroundStyle(focused ? .black : .white)
        .frame(width: 44 * key.width + 6 * (key.width - 1), height: 42)
        .background(focused ? Color.white : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .scaleEffect(focused ? 1.08 : 1)
        .shadow(color: focused ? .white.opacity(0.35) : .clear, radius: 8)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}
