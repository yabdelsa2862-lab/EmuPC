import AppIntents
// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import os
import UserNotifications

// MABD local: why the last game closed, and what to change.
//
// iOS ends an app that goes over its memory limit (jetsam) without telling it,
// so a game that "just closed" leaves no exit report. While a library game runs,
// this keeps a small record in Documents/session-active.json: the game, the peak
// memory footprint and how close the app came to iOS's limit
// (os_proc_available_memory), and whether Madeira was in the background. A
// session that ends inside Madeira deletes it. If the file is still there at
// the next start, the session ended with the app: the report names the likely
// cause and offers fixes that apply to that game only (lower resolution, 30 FPS,
// memory swap, Fast CPU mode off). While the game runs, the HUD warns once when
// iOS's limit is close. Log tag: [doctor].

struct SessionRecord: Codable {
    var id: UUID
    var title: String
    var started: Date
    var updated: Date
    var peakMB: Int
    var lastMB: Int
    /// The least headroom seen before iOS's limit, in MB (os_proc_available_memory).
    var minAvailableMB: Int
    var lastAvailableMB: Int
    var background: Bool
    var fastCPU: Bool
}

struct SessionReport: Identifiable {
    enum Cause { case memory, background, crash }
    let id = UUID()
    var record: SessionRecord
    var cause: Cause

    var title: String {
        switch cause {
        case .memory: return "\(record.title) ran out of memory"
        case .background: return "\(record.title) was closed in the background"
        case .crash: return "\(record.title) closed unexpectedly"
        }
    }

    var message: String {
        let minutes = max(1, Int(record.updated.timeIntervalSince(record.started) / 60))
        let peak = "It used up to \(String(format: "%.1f", Double(record.peakMB) / 1024)) GB after \(minutes) min."
        switch cause {
        case .memory:
            return "\(peak) iOS closes an app that goes over its memory limit. Use less memory for this game: a lower resolution, 30 FPS, and memory swap."
        case .background:
            return "\(peak) iOS can close a game while EmuPC is in the background. Keep EmuPC open while playing."
        case .crash:
            return record.fastCPU
                ? "\(peak) Fast CPU mode is on for this game and can make games crash. Turn it off and try again."
                : "\(peak) EmuPC closed without running out of memory. The diagnostic log has the details."
        }
    }
}

final class SessionDoctor: ObservableObject {
    static let shared = SessionDoctor()

    /// The last session's report, shown once on the home screen.
    @Published var report: SessionReport?
    /// The in-game warning that iOS's limit is close.
    @Published var lowMemory = false

    /// The heat guard: while the phone is hot, the game runs at 30 FPS.
    static let thermalKey = "madeiraThermalGuard"
    static var thermalGuard: Bool { UserDefaults.standard.object(forKey: thermalKey) as? Bool ?? true }
    /// The heat guard has the game at 30 FPS right now.
    @Published var cooling = false

    private var record: SessionRecord?
    private var timer: Timer?
    private var warned = false
    private var lastWrite = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("session-active.json")
    }

    /// Below this much headroom the HUD warns; a session that ended with less is
    /// reported as out of memory.
    static let warnMB = 350
    static let memoryCauseMB = 600

    // MARK: Session

    func begin(_ entry: LibraryEntry) {
        let now = Date()
        record = SessionRecord(id: entry.id, title: entry.title, started: now, updated: now, peakMB: 0, lastMB: 0,
                               minAvailableMB: Int.max, lastAvailableMB: Int.max, background: false,
                               fastCPU: entry.fastCPU == true)
        warned = false; lowMemory = false
        sample(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setBackground(true)
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setBackground(false)
            })
        }
        LogStore.shared.log("[doctor] watching \(entry.title)")
    }

    /// From .serious on iOS lowers the clocks anyway, and an uncapped game then
    /// stutters; a steady 30 FPS makes less heat. The game's own limit comes back
    /// once the phone is down to .fair. Only for games above 30 FPS.
    private func applyThermalGuard() {
        let state = ProcessInfo.processInfo.thermalState
        let model = LibraryModel.shared
        if !cooling, Self.thermalGuard, state.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
           model.fpsMode != 3, ProMotionIntent.has30Cap {
            cooling = true
            madeira_set_vsync_locked(3); ProMotionIntent.apply(mode: 3)
            LogStore.shared.log("[doctor] heat guard: phone is hot, 30 FPS until it cools")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if self?.cooling == true { self?.objectWillChange.send() }
            }
        } else if cooling, state.rawValue <= ProcessInfo.ThermalState.fair.rawValue || !Self.thermalGuard {
            cooling = false
            let mode = ProMotionIntent.supportedMode(model.fpsMode)
            madeira_set_vsync_locked(mode); ProMotionIntent.apply(mode: mode)
            LogStore.shared.log("[doctor] heat guard: cooled down, FPS limit back to the game's")
        }
    }

    /// The session ended inside Madeira (or Madeira is closing it on purpose).
    func end() {
        cooling = false
        timer?.invalidate(); timer = nil
        if let record { LogStore.shared.log("[doctor] ended \(record.title) peak=\(record.peakMB)MB min-available=\(record.minAvailableMB == Int.max ? -1 : record.minAvailableMB)MB") }
        record = nil; lowMemory = false
        try? FileManager.default.removeItem(at: Self.url)
    }

    private func setBackground(_ on: Bool) {
        guard record != nil else { return }
        record?.background = on
        sample(force: true)
    }

    private func sample(force: Bool = false) {
        guard var record else { return }
        let footprint = Self.footprintMB()
        let available = Int(os_proc_available_memory() / 1_048_576)
        record.lastMB = footprint; record.peakMB = max(record.peakMB, footprint)
        if available > 0 { record.lastAvailableMB = available; record.minAvailableMB = min(record.minAvailableMB, available) }
        record.updated = Date()
        self.record = record
        applyThermalGuard()
        if available > 0, available < Self.warnMB, !warned {
            warned = true; lowMemory = true
            LogStore.shared.log("[doctor] low memory: \(available)MB left before iOS's limit, footprint \(footprint)MB")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.lowMemory = false }
        }
        // Written every 2 s while memory is tight, otherwise every 6 s.
        let tight = available > 0 && available < Self.memoryCauseMB * 2
        if force || tight || Date().timeIntervalSince(lastWrite) > 6 {
            lastWrite = Date()
            if let data = try? JSONEncoder().encode(record) { try? data.write(to: Self.url, options: .atomic) }
        }
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    // MARK: Next start

    /// Called once at launch: a record left behind means the last session ended
    /// with the app.
    func checkPreviousSession() {
        guard let data = try? Data(contentsOf: Self.url),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return }
        try? FileManager.default.removeItem(at: Self.url)
        let cause: SessionReport.Cause
        if record.minAvailableMB < Self.memoryCauseMB || record.lastAvailableMB < Self.memoryCauseMB {
            cause = .memory
        } else if record.background {
            cause = .background
        } else {
            cause = .crash
        }
        LogStore.shared.log("[doctor] last session \(record.title) ended with the app: cause=\(cause) peak=\(record.peakMB)MB min-available=\(record.minAvailableMB)MB background=\(record.background ? 1 : 0)")
        report = SessionReport(record: record, cause: cause)
    }

    // MARK: Fixes

    /// Lower resolution, 30 FPS and memory swap for the reported game.
    func applyMemoryFixes(_ report: SessionReport) {
        let model = LibraryModel.shared
        guard var entry = model.entries.first(where: { $0.id == report.record.id }) else { return }
        // The largest of this screen's shapes with fewer pixels than now.
        let current = entry.resolution.split(separator: "x").compactMap { Int($0) }
        if current.count == 2, let own = ResolutionChoices.groups().first?.choices,
           let smaller = own.filter({ $0.w * $0.h < current[0] * current[1] }).max(by: { $0.w * $0.h < $1.w * $1.h }) {
            entry.resolution = smaller.value
        }
        entry.fpsMode = 3
        var lines = (entry.config ?? "").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !lines.contains(where: { $0.hasPrefix("swap-mb") }) { lines.append("swap-mb = 4096") }
        if !lines.contains(where: { $0.hasPrefix("env.MADEIRA_SWAP_COVERAGE") }) { lines.append("env.MADEIRA_SWAP_COVERAGE = broad") }
        entry.config = lines.joined(separator: "\n")
        model.save(entry)
        LogStore.shared.log("[doctor] memory fixes for \(entry.title): resolution=\(entry.resolution) fps=30 swap")
        self.report = nil
    }

    func turnOffFastCPU(_ report: SessionReport) {
        let model = LibraryModel.shared
        guard var entry = model.entries.first(where: { $0.id == report.record.id }) else { return }
        entry.fastCPU = nil
        model.save(entry)
        LogStore.shared.log("[doctor] Fast CPU mode off for \(entry.title)")
        self.report = nil
    }
}

/// The report, as an alert on either home screen.
struct SessionDoctorAlert: ViewModifier {
    @ObservedObject private var doctor = SessionDoctor.shared

    func body(content: Content) -> some View {
        content.alert(doctor.report?.title ?? "", isPresented: Binding(
            get: { doctor.report != nil && LibraryModel.shared.current == nil },
            set: { if !$0 { doctor.report = nil } })) {
            if let report = doctor.report {
                switch report.cause {
                case .memory:
                    Button("Use less memory") { doctor.applyMemoryFixes(report) }
                case .crash where report.record.fastCPU:
                    Button("Turn off Fast CPU mode") { doctor.turnOffFastCPU(report) }
                default:
                    EmptyView()
                }
            }
            Button("OK", role: .cancel) { doctor.report = nil }
        } message: {
            Text(doctor.report?.message ?? "")
        }
    }
}

/// The in-game warning that iOS's memory limit is close.
struct LowMemoryBanner: View {
    @ObservedObject private var doctor = SessionDoctor.shared
    @State private var showCooling = false

    var body: some View {
        VStack(spacing: 6) {
            if showCooling {
                banner("Phone is hot: 30 FPS until it cools down", symbol: "thermometer.high", color: .orange)
            }
            if doctor.lowMemory {
                banner("Memory almost full: iOS may close the game", symbol: "memorychip", color: .red)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: doctor.cooling) { _, on in
            guard on else { withAnimation { showCooling = false }; return }
            withAnimation { showCooling = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { withAnimation { showCooling = false } }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color.opacity(0.88), in: Capsule())
            .foregroundStyle(.white)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Settings › Heat guard.
struct HeatGuardSettingsSection: View {
    @AppStorage(SessionDoctor.thermalKey) private var on = true

    var body: some View {
        Section {
            Toggle("Heat guard", isOn: $on)
        } header: { Text("Heat") } footer: {
            Text("When the iPhone gets hot, the game runs at 30 FPS until it cools down. iOS slows a hot phone anyway, and a steady 30 stutters less than an uneven 40–60.")
        }
    }
}

// MARK: - Reopen after closing


/// MABD local: iOS does not let an app start itself again. When Madeira has to
/// close (a game that will not stop, a restart between games, a JIT pool it
/// cannot use), it first leaves a notification, "tap to open Madeira again",
/// which brings it straight back. Nothing can be done when iOS itself ends the
/// app (out of memory): there is no warning.
enum AppRelaunch {
    static let identifier = "madeira.reopen"

    /// Set while Madeira is in front and when it closes itself; cleared when the
    /// player leaves on purpose (the scene goes to the background). A Shortcuts
    /// automation "When Madeira is closed" asks `ClosedByItselfIntent` and
    /// reopens Madeira only when this is set (a crash, iOS closing it for
    /// memory, or a restart from the guide).
    static let wantedKey = "madeiraReopenWanted"
    static func scene(active: Bool) {
        UserDefaults.standard.set(active, forKey: wantedKey)
        active ? Watchdog.start() : Watchdog.stop()
    }

    /// A dead man's switch for closes iOS does not report to Shortcuts (a crash,
    /// a memory kill): while Madeira is in front, a "Madeira closed" notification
    /// stays queued a few seconds ahead and is pushed back from a background
    /// queue. If Madeira dies the pushing stops and it shows. Leaving Madeira
    /// cancels it; while Madeira is in front a delivery is not shown.
    enum Watchdog {
        static let identifier = "madeira.watchdog"
        private static let queue = DispatchQueue(label: "madeira.watchdog", qos: .utility)
        nonisolated(unsafe) private static var timer: DispatchSourceTimer?

        static func start() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                queue.async {
                    guard timer == nil else { return }
                    let t = DispatchSource.makeTimerSource(queue: queue)
                    t.schedule(deadline: .now(), repeating: 4)
                    t.setEventHandler { arm() }
                    t.resume()
                    timer = t
                }
            }
        }

        static func stop() {
            // On the timer's queue, so no arm already under way lands after the removal.
            queue.sync {
                timer?.cancel(); timer = nil
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            }
        }

        private static func arm() {
            let content = UNMutableNotificationContent()
            content.title = "EmuPC closed"
            content.body = "Tap to open EmuPC again."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            // Same identifier: each arm replaces the last, so it fires only once the pushing stops.
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)))
        }
    }

    static func closeAndOffer(_ reason: String) {
        UserDefaults.standard.set(true, forKey: wantedKey)
        Watchdog.stop()   // this close posts its own notification
        LogStore.shared.log("[relaunch] closing (\(reason)); a notification offers to reopen")
        let center = UNUserNotificationCenter.current()
        // Closing goes ahead after a moment even if the notification never answers.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { exit(0) }
            let content = UNMutableNotificationContent()
            content.title = "EmuPC closed"
            content.body = "Tap to open EmuPC again."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let request = UNNotificationRequest(identifier: identifier, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            center.add(request) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            }
        }
    }

    /// Close on the player's request: to the Home Screen as iOS does, then quit.
    /// Not a crash, so no reopen notification and the Shortcuts check says no.
    static func close() {
        LogStore.shared.log("[relaunch] closing on request")
        UserDefaults.standard.set(false, forKey: wantedKey)
        Watchdog.stop()
        clear()
        UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
    }

    /// At launch: the reopen notification has done its job.
    static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier, Watchdog.identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

/// "Did Madeira close by itself?" for Shortcuts: yes after a crash, a close by
/// iOS while Madeira was in front, or a restart; no when the player left it.
struct ClosedByItselfIntent: AppIntent {
    static let title: LocalizedStringResource = "Did EmuPC close by itself?"
    static let description = IntentDescription("Yes when EmuPC crashed, was closed by iOS while you were using it, or restarted itself. Use it in a \"When EmuPC is closed\" automation to open EmuPC again.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let wanted = UserDefaults.standard.bool(forKey: AppRelaunch.wantedKey)
        // One reopen per close: the reopened Madeira sets it again while in front.
        UserDefaults.standard.set(false, forKey: AppRelaunch.wantedKey)
        return .result(value: wanted)
    }
}

struct MadeiraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ClosedByItselfIntent(), phrases: ["Did \(.applicationName) close by itself"],
                    shortTitle: "Closed by itself?", systemImageName: "arrow.clockwise")
    }
}

// MARK: - In-game guide

/// MABD local: the in-game menu with a controller, console style: a panel from
/// the left with the game's name and the time, and the things a player reaches
/// for in a game. "All settings" opens the full (touch) session menu.
@MainActor
final class InGameGuide: ObservableObject {
    static let shared = InGameGuide()
    @Published var focus = 0
    /// The full session menu instead of the guide.
    @Published var fullMenu = false

    /// action gets -1 (left), 1 (right) or 0 (A or a tap).
    struct Item { let title: String; let value: String?; let symbol: String; var music = false; let action: (Int) -> Void }

    func items(_ model: LibraryModel) -> [Item] {
        let fpsModes = [3, 4, 1, 0]
        let fpsNames = [3: "30", 4: "40", 1: "60", 0: "Max", 2: "Uncapped"]
        let controls = TouchControlsModel.shared
        return [
            Item(title: "Resume", value: nil, symbol: "play.fill") { _ in model.menu = false },
            Item(title: "Quit game", value: nil, symbol: "xmark.circle.fill") { _ in model.menu = false; model.stopGame() },
            Item(title: "Music", value: nil, symbol: "music.note", music: true) { d in
                if d == 0 { MusicNow.shared.toggle() } else { MusicNow.shared.skip(d) }
            },
            Item(title: "FPS limit", value: fpsNames[model.fpsMode] ?? "60", symbol: "speedometer") { d in
                let i = fpsModes.firstIndex(of: model.fpsMode) ?? 2
                model.setFPS(fpsModes[(i + (d < 0 ? fpsModes.count - 1 : 1)) % fpsModes.count])
            },
            Item(title: "Performance overlay", value: model.performance ? "On" : "Off", symbol: "gauge.with.dots.needle.50percent") { _ in
                model.performance.toggle(); model.saveCurrentProfile()
            },
            Item(title: "Touch controls", value: controls.visible ? "On" : "Off", symbol: "hand.tap.fill") { _ in
                controls.visible.toggle(); model.saveCurrentProfile()
            },
            Item(title: "All settings", value: nil, symbol: "slider.horizontal.3") { _ in self.fullMenu = true },
            Item(title: "Restart EmuPC", value: nil, symbol: "arrow.clockwise") { _ in AppRelaunch.closeAndOffer("in-game guide") },
            Item(title: "Close EmuPC", value: nil, symbol: "power") { _ in
                // Stop the game first so it gets its normal shutdown, then close.
                model.menu = false; model.stopGame()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppRelaunch.close() }
            },
        ]
    }

    /// Controller input while the guide is open; false when the full menu has it.
    func handle(_ command: String, model: LibraryModel) -> Bool {
        guard !fullMenu else { return false }
        let list = items(model)
        switch command {
        case "up": focus = max(focus - 1, 0)
        case "down": focus = min(focus + 1, list.count - 1)
        case "left": list[focus].action(-1)
        case "right": list[focus].action(1)
        case "accept": list[focus].action(0)
        case "back", "menu": model.menu = false
        default: break
        }
        return true
    }
}

struct InGameGuideView: View {
    @ObservedObject private var guide = InGameGuide.shared
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var theme = ThemeSettings.shared
    @ObservedObject private var controls = TouchControlsModel.shared
    @State private var now = Date()

    var body: some View {
        let items = guide.items(model)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ProfileAvatar(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.activeEntry?.title ?? "Game").font(.headline).lineLimit(1)
                    HStack(spacing: 10) {
                        Text(now.formatted(date: .omitted, time: .shortened))
                        BatteryIndicator(compact: true)
                    }
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.bottom, 10)
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(items.indices, id: \.self) { i in
                        let item = items[i]
                        let on = i == guide.focus
                        Group {
                        if item.music {
                            MusicGuideRow(focused: on)
                        } else {
                        HStack {
                            Label(item.title, systemImage: item.symbol).font(.headline)
                            Spacer()
                            if let value = item.value {
                                HStack(spacing: 6) {
                                    if on { Image(systemName: "chevron.left").font(.caption.bold()) }
                                    Text(value).font(.subheadline.weight(.semibold))
                                    if on { Image(systemName: "chevron.right").font(.caption.bold()) }
                                }
                            }
                        }
                        }
                        }
                        .foregroundStyle(on ? theme.accent.onAccent : .white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(on ? theme.accent.color : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { guide.focus = i; item.action(0) }
                        .id(i)
                    }
                }
            }
            .onChange(of: guide.focus) { _, i in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(i, anchor: .center) } }
            }
            HStack(spacing: 16) {
                ButtonHint(glyph: "a.circle.fill", label: "Select")
                ButtonHint(glyph: "b.circle.fill", label: "Resume")
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: 340)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }
}

/// The "Stop launching?" question while a game starts (B, then A to stop).
struct StopLaunchPrompt: View {
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var controller = LibraryController.shared
    var body: some View {
        if model.launching && !model.confirmStop && controller.connected {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "b.circle.fill").font(.title2)
                    Text("Stop launching").font(.headline)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        if model.launching && model.confirmStop {
            ZStack {
                Color.black.opacity(0.7).ignoresSafeArea().onTapGesture { model.confirmStop = false }
                VStack(spacing: 14) {
                    Text("Stop launching?").font(.title2.bold())
                    Text("The game will be closed.").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        Button { model.stopGame(grace: 3) } label: { Label("Stop", systemImage: "a.circle.fill").font(.headline) }.tint(.red)
                        Button { model.confirmStop = false } label: { Label("Keep waiting", systemImage: "b.circle.fill").font(.headline) }
                    }
                }
                .padding(28)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Music

/// MABD local: the player's own music while they play. Game sound mixes with
/// it (instead of stopping it), and the guides show Apple Music's song with
/// play/pause and skip. iOS gives no other app's playback to EmuPC, so this is
/// the Music app only.
@MainActor
final class MusicNow: ObservableObject {
    static let shared = MusicNow()
    static let mixKey = "madeiraMixMusic"

    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var playing = false
    @Published private(set) var allowed = MPMediaLibrary.authorizationStatus() == .authorized

    private lazy var player = MPMusicPlayerController.systemMusicPlayer
    private var observers: [NSObjectProtocol] = []
    /// The music frameworks set up their account state on first use; until that
    /// has happened off the main thread, the player is left alone.
    private var ready = false

    /// Game sound plays alongside the player's music (on by default).
    static var mix: Bool {
        get { UserDefaults.standard.object(forKey: mixKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: mixKey); applyMix() }
    }

    /// A game already running picks the change up straight away.
    static func applyMix() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: mix ? [.mixWithOthers] : [])
    }

    private init() {
        // First use sets up iTunesCloud's account store, which posts defaults
        // changes and waits for listeners. Done here on a background queue so
        // the main thread is free; the main thread then never waits on it.
        DispatchQueue.global(qos: .utility).async {
            _ = MPMediaLibrary.default().lastModifiedDate
            DispatchQueue.main.async { MainActor.assumeIsolated { MusicNow.shared.start() } }
        }
    }

    private func start() {
        ready = true
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private var itemID: MPMediaEntityPersistentID?

    func refresh() {
        guard ready else { return }
        let now = player.playbackState == .playing
        if playing != now { playing = now }
        let item = allowed ? player.nowPlayingItem : nil
        guard item?.persistentID != itemID || (item == nil) != (title == nil) else { return }
        itemID = item?.persistentID
        title = item?.title
        artist = item?.artist
        artwork = item?.artwork?.image(at: CGSize(width: 96, height: 96))
    }

    /// The row's text: the song, or what A does.
    var label: String { title ?? (allowed ? (playing ? "Music" : "Play music") : "Music (A to allow)") }

    /// A: play or pause. Asks for access to the Music app once.
    func toggle() {
        guard ready else { return }
        guard allowed else {
            // iOS answers on a background queue: a closure that inherits the main
            // actor traps there (and, with the JIT debugger attached, freezes EmuPC).
            let answered: @Sendable (MPMediaLibraryAuthorizationStatus) -> Void = { status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        MusicNow.shared.allowed = status == .authorized
                        MusicNow.shared.refresh()
                    }
                }
            }
            MPMediaLibrary.requestAuthorization(answered)
            return
        }
        if player.playbackState == .playing { player.pause() } else { player.play() }
        refresh()
    }

    /// Left: previous song (or the start of this one), right: next song.
    func skip(_ d: Int) {
        guard ready else { return }
        guard allowed else { toggle(); return }
        if d < 0 {
            if player.currentPlaybackTime > 4 { player.skipToBeginning() } else { player.skipToPreviousItem() }
        } else {
            player.skipToNextItem()
        }
        refresh()
    }
}

/// The music row in the home and in-game guides.
struct MusicGuideRow: View {
    @ObservedObject private var music = MusicNow.shared
    let focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let art = music.artwork {
                    Image(uiImage: art).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.headline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.12))
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(music.label).font(.headline).lineLimit(1)
                if let artist = music.artist {
                    Text(artist).font(.caption).opacity(0.75).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                if focused { Image(systemName: "backward.fill").font(.caption) }
                Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.subheadline)
                if focused { Image(systemName: "forward.fill").font(.caption) }
            }
        }
        .onAppear { music.refresh() }
    }
}

/// Touch Settings › Music.
struct MusicSettingsSection: View {
    @State private var mix = MusicNow.mix
    var body: some View {
        Section {
            Toggle("Keep my music playing", isOn: $mix)
        } header: { Text("Music") } footer: {
            Text("Game sound plays alongside music from other apps instead of stopping it. The controller guide (Xbox button) has play, pause and skip for Apple Music.")
        }
        .onChange(of: mix) { _, on in MusicNow.mix = on }
    }
}
