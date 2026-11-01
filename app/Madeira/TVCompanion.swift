// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Combine
import GameController
import SwiftUI
import UIKit
import os

// EmuPC: while a game plays on a TV (ExternalDisplay: AirPlay or a cable),
// the phone becomes a companion instead of a black screen with loose controls:
//
//   - no controller connected: a full-screen Xbox-style controller, fed into
//     player 1 through the touch path (GamepadInput.touch), so the phone IS the
//     controller;
//   - a controller connected: a performance monitor (FPS, frame time, CPU, GPU,
//     memory, battery, temperature) in large type.
//
// The choice follows the controller automatically until the player picks one
// at the top of the screen; that pick lasts until the TV disconnects.
// MADEIRA_TV_COMPANION=0 turns it off. Log tag: [tv-companion].

final class TVCompanionModel: ObservableObject {
    static let shared = TVCompanionModel()
    static let enabled = GamepadInput.flag("MADEIRA_TV_COMPANION")

    enum Mode: String { case controller, monitor }

    @Published private(set) var controllerConnected = false
    /// The player's pick; nil follows the controller.
    @Published var pick: Mode?

    var mode: Mode { pick ?? (controllerConnected ? .monitor : .controller) }

    private var observers: [NSObjectProtocol] = []
    private var external: AnyCancellable?

    private init() {
        refreshControllers()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshControllers()
            })
        }
        // A new TV session starts on automatic again.
        external = ExternalDisplay.shared.$window.receive(on: DispatchQueue.main).sink { [weak self] window in
            if window == nil { self?.pick = nil; Self.phonePadNavigates = false }
            LogStore.shared.log("[tv-companion] external display \(window == nil ? "gone" : "connected")")
        }
    }

    private func refreshControllers() {
        let now = GCController.controllers().contains { $0.extendedGamepad != nil }
        guard now != controllerConnected else { return }
        controllerConnected = now
        LogStore.shared.log("[tv-companion] controller \(now ? "connected" : "disconnected"): \(mode.rawValue)")
    }

    /// Whether the companion replaces the phone's screen right now.
    @MainActor func showing(session: Bool) -> Bool {
        Self.enabled && session && ExternalDisplay.shared.hostView != nil
    }

    /// A TV is connected and the companion is on: between games the TV shows
    /// the controller home (TVHome) and the phone the companion.
    @MainActor var tvActive: Bool { Self.enabled && ExternalDisplay.shared.hostView != nil }

    /// Read on GamepadInput's queue: the phone's controller also feeds the
    /// library's controller navigation (the TV's home screen).
    nonisolated(unsafe) static var phonePadNavigates = false

    /// The controller's touch IDs, for GamepadInput.configureTouch, while it is shown.
    @MainActor func padIDs(session: Bool) -> [UUID] {
        (showing(session: session) || tvActive) && mode == .controller ? Array(TVPad.ids.values) : []
    }

    /// Between games on a TV: the phone's controller drives the TV's home screen.
    @MainActor func configureIdlePad() {
        let ids = padIDs(session: false)
        Self.phonePadNavigates = !ids.isEmpty
        GamepadInput.shared.configureTouch(controls: Set(ids), acceptingInput: true)
    }
}

/// The companion controller's controls: one fixed ID per button and stick.
enum TVPad {
    static let names = ["A", "B", "X", "Y", "D↑", "D↓", "D←", "D→", "LB", "RB", "LT", "RT",
                        "LS", "RS", "Menu", "View"]
    static let ids: [String: UUID] = Dictionary(uniqueKeysWithValues: names.map { ($0, UUID()) })
}

struct TVCompanionView: View {
    @ObservedObject private var model = TVCompanionModel.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black
                Group {
                    if model.mode == .controller {
                        TVControllerPad(size: geo.size)
                    } else {
                        TVMonitor()
                            .padding(.top, 70)
                            .padding(.horizontal, 20)
                    }
                }
                Picker("Phone shows", selection: Binding(get: { model.mode }, set: { model.pick = $0 })) {
                    Label("Controller", systemImage: "gamecontroller").tag(TVCompanionModel.Mode.controller)
                    Label("Monitor", systemImage: "gauge.with.dots.needle.67percent").tag(TVCompanionModel.Mode.monitor)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .padding(.top, max(12, geo.safeAreaInsets.top))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Controller

private struct TVControllerPad: View {
    let size: CGSize

    var body: some View {
        let landscape = size.width > size.height
        let unit = min(size.width, size.height) / (landscape ? 4.6 : 5.6)
        ZStack {
            // Shoulders along the top corners.
            shoulder("LT", x: unit * 1.0, y: unit * 0.95, unit: unit)
            shoulder("LB", x: unit * 2.25, y: unit * 0.95, unit: unit)
            shoulder("RB", x: size.width - unit * 2.25, y: unit * 0.95, unit: unit)
            shoulder("RT", x: size.width - unit * 1.0, y: unit * 0.95, unit: unit)

            // Left: stick over the D-pad. Right: face buttons over the stick.
            TVStick(name: "LS", diameter: unit * 1.9)
                .position(x: unit * 1.7, y: size.height * (landscape ? 0.48 : 0.42))
            dpad(center: CGPoint(x: unit * (landscape ? 3.4 : 1.7), y: size.height * (landscape ? 0.8 : 0.72)), unit: unit)
            face(center: CGPoint(x: size.width - unit * 1.7, y: size.height * (landscape ? 0.48 : 0.42)), unit: unit)
            TVStick(name: "RS", diameter: unit * 1.9)
                .position(x: size.width - unit * (landscape ? 3.4 : 1.7), y: size.height * (landscape ? 0.8 : 0.72))

            // View and Menu in the middle.
            TVButton(name: "View", label: "", glyph: "rectangle.on.rectangle", tint: .gray, size: CGSize(width: unit * 0.75, height: unit * 0.5))
                .position(x: size.width / 2 - unit * 0.6, y: size.height * 0.45)
            TVButton(name: "Menu", label: "", glyph: "line.3.horizontal", tint: .gray, size: CGSize(width: unit * 0.75, height: unit * 0.5))
                .position(x: size.width / 2 + unit * 0.6, y: size.height * 0.45)
        }
    }

    private func shoulder(_ name: String, x: CGFloat, y: CGFloat, unit: CGFloat) -> some View {
        TVButton(name: name, label: name, glyph: nil, tint: .gray, size: CGSize(width: unit * 1.1, height: unit * 0.55))
            .position(x: x, y: y)
    }

    private func dpad(center c: CGPoint, unit: CGFloat) -> some View {
        let s = CGSize(width: unit * 0.62, height: unit * 0.62), d = unit * 0.62
        return ZStack {
            TVButton(name: "D↑", label: "", glyph: "arrowtriangle.up.fill", tint: .gray, size: s).position(x: c.x, y: c.y - d)
            TVButton(name: "D↓", label: "", glyph: "arrowtriangle.down.fill", tint: .gray, size: s).position(x: c.x, y: c.y + d)
            TVButton(name: "D←", label: "", glyph: "arrowtriangle.left.fill", tint: .gray, size: s).position(x: c.x - d, y: c.y)
            TVButton(name: "D→", label: "", glyph: "arrowtriangle.right.fill", tint: .gray, size: s).position(x: c.x + d, y: c.y)
        }
    }

    private func face(center c: CGPoint, unit: CGFloat) -> some View {
        let s = CGSize(width: unit * 0.72, height: unit * 0.72), d = unit * 0.7
        return ZStack {
            TVButton(name: "Y", label: "Y", glyph: nil, tint: .yellow, size: s).position(x: c.x, y: c.y - d)
            TVButton(name: "A", label: "A", glyph: nil, tint: .green, size: s).position(x: c.x, y: c.y + d)
            TVButton(name: "X", label: "X", glyph: nil, tint: .blue, size: s).position(x: c.x - d, y: c.y)
            TVButton(name: "B", label: "B", glyph: nil, tint: .red, size: s).position(x: c.x + d, y: c.y)
        }
    }
}

private struct TVButton: View {
    let name: String
    let label: String
    let glyph: String?
    let tint: Color
    let size: CGSize
    @State private var down = false

    var body: some View {
        let round = abs(size.width - size.height) < 1
        ZStack {
            RoundedRectangle(cornerRadius: round ? size.height / 2 : size.height * 0.3)
                .fill(tint.opacity(down ? 0.75 : 0.28))
                .overlay(RoundedRectangle(cornerRadius: round ? size.height / 2 : size.height * 0.3)
                    .stroke(tint.opacity(0.9), lineWidth: 2))
            if let glyph {
                Image(systemName: glyph).font(.system(size: size.height * 0.38, weight: .semibold))
            } else {
                Text(label).font(.system(size: size.height * (label.count > 1 ? 0.34 : 0.45), weight: .bold, design: .rounded))
            }
            TouchPadSurface(control: TVPad.ids[name]!, action: name) { _, held in
                if held != down {
                    down = held
                    if held { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
    }
}

private struct TVStick: View {
    let name: String
    let diameter: CGFloat
    @State private var offset = CGSize.zero

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08)).overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2))
            Circle().fill(.white.opacity(0.32))
                .frame(width: diameter * 0.45, height: diameter * 0.45)
                .offset(x: offset.width * diameter * 0.3, y: offset.height * diameter * 0.3)
            Text(name).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
                .offset(y: diameter * 0.42)
            TouchPadSurface(control: TVPad.ids[name]!, action: name) { vector, _ in offset = vector }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Monitor

private struct TVMonitor: View {
    @State private var lastCount: UInt64 = 0
    @State private var lastTime = Date()
    @State private var fps = 0.0
    @State private var memory = 0
    @State private var available = 0
    @State private var battery = -1
    @State private var charging = false
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var cpuMeter = CPUMeter()
    @State private var cpu: (total: Double, top: Double)?
    @State private var lastGPUBusy = 0.0
    @State private var lastGPUBuffers: UInt64 = 0
    @State private var gpu = -1.0
    private let ticks = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                tile("FPS", String(format: "%.0f", fps), fps >= 50 ? .green : fps >= 30 ? .yellow : .orange)
                tile("Frame time", fps > 0 ? String(format: "%.1f ms", 1000 / fps) : "—", .white)
                tile("CPU", cpu.map { String(format: "%.0f%%", $0.total) } ?? "—", .white,
                     cpu.map { String(format: "busiest thread %.0f%%", $0.top) })
                tile("GPU", gpu < 0 ? "—" : String(format: "%.0f%%", gpu), .white)
                tile("Memory", "\(memory) MB", memoryColor, available > 0 ? "\(available) MB left before iOS steps in" : nil)
                tile("Battery", battery < 0 ? "—" : "\(battery)%", battery >= 0 && battery < 20 && !charging ? .red : .white,
                     charging ? "charging" : nil)
                tile("Temperature", thermalName, thermalColor)
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            lastCount = madeira_get_present_count(); lastTime = Date()
            UIDevice.current.isBatteryMonitoringEnabled = true
            madeira_gpu_meter_enable(1)
            lastGPUBusy = madeira_gpu_meter_busy_seconds(); lastGPUBuffers = madeira_gpu_meter_cmdbufs()
            sample(Date())
        }
        .onDisappear { madeira_gpu_meter_enable(0) }
        .onReceive(ticks) { sample($0) }
    }

    private func sample(_ now: Date) {
        let count = madeira_get_present_count(), dt = now.timeIntervalSince(lastTime)
        if dt > 0.2 {
            fps = Double(count >= lastCount ? count - lastCount : 0) / dt
            let busy = madeira_gpu_meter_busy_seconds(), buffers = madeira_gpu_meter_cmdbufs()
            gpu = buffers > lastGPUBuffers ? min(100, max(0, busy - lastGPUBusy) / dt * 100) : -1
            lastGPUBusy = busy; lastGPUBuffers = buffers
        }
        lastCount = count; lastTime = now
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        if result == KERN_SUCCESS { memory = Int(info.phys_footprint / 1048576) }
        available = Int(os_proc_available_memory() / 1048576)
        battery = UIDevice.current.batteryLevel < 0 ? -1 : Int(UIDevice.current.batteryLevel * 100)
        charging = [.charging, .full].contains(UIDevice.current.batteryState)
        thermal = ProcessInfo.processInfo.thermalState
        cpu = cpuMeter.sample() ?? cpu
    }

    private var memoryColor: Color {
        available == 0 ? .white : available > 768 ? .green : available > 384 ? .yellow : available > 128 ? .orange : .red
    }
    private var thermalName: String {
        switch thermal {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "—"
        }
    }
    private var thermalColor: Color {
        switch thermal {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }

    private func tile(_ title: String, _ value: String, _ color: Color, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color).minimumScaleFactor(0.5).lineLimit(1)
            Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }
}

// MARK: - The TV's home screen

/// What the TV shows between games: the controller home (ControllerHome.swift),
/// driven by player 1's pad or the phone's controller. Hidden while a game runs,
/// so the game's view and layers underneath show.
struct TVHome: View {
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        if library.current == nil && library.preparing == nil {
            ControllerHome(play: { TVHomeBridge.play?($0) }, enableJIT: { TVHomeBridge.enableJIT?() }, openLibrary: {})
                .preferredColorScheme(.dark)
        } else {
            Color.clear
        }
    }
}

/// The phone's start actions (ContentView), for the TV's home screen.
enum TVHomeBridge {
    @MainActor static var play: ((LibraryEntry) -> Void)?
    @MainActor static var enableJIT: (() -> Void)?
}
