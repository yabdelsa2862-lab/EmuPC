// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UniformTypeIdentifiers
import zlib

// The library's Download games tab: the Steam games the account owns that are
// not installed, each with its download button (SteamOwnedLibrary's own
// downloader, docs/STEAM_LIBRARY.md), and games from a link or from Files: a
// .zip, a Windows program or a game folder, put in C:\Games\<name> and added
// to the library like a game added with +. Nothing here needs a computer.
// Log tag: [download-games] (phases and sizes, never URLs or names).

// MARK: - Import (link or file -> C:\Games -> library entry)

@MainActor
final class GameImporter: ObservableObject {
    static let shared = GameImporter()

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double?, bytes: Int64)
        case installing(fraction: Double)
        case done(title: String)
        case failed(String)

        var busy: Bool {
            switch self {
            case .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// The entry the last import added, so the page can open it.
    @Published private(set) var added: LibraryEntry?
    /// Install to the external drive (ExternalDrive.swift) instead of this iPhone.
    /// Remembered between launches.
    @Published var toExternal = UserDefaults.standard.bool(forKey: "madeiraInstallToExternal") {
        didSet { UserDefaults.standard.set(toExternal, forKey: "madeiraInstallToExternal") }
    }
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    nonisolated static var gamesFolder: URL { LibraryModel.drive.appendingPathComponent("Games", isDirectory: true) }

    /// C:\Games on this iPhone, or Games on the external drive (C:\External\Games).
    nonisolated static func gamesFolder(external: Bool) throws -> URL {
        guard external else { return gamesFolder }
        guard let root = ExternalDrive.rootPath else {
            throw LibraryError.message("The external drive isn't connected. Plug it in, or install to this iPhone.")
        }
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Games", isDirectory: true)
    }

    func reset() { if !phase.busy { phase = .idle; added = nil } }

    /// Downloads `text` (an http(s) link) and installs what arrives.
    func download(_ text: String) {
        guard !phase.busy else { return }
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.contains("://") { link = "https://" + link }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            phase = .failed("That doesn't look like a web link."); return
        }
        phase = .downloading(fraction: nil, bytes: 0)
        let external = toExternal
        LogStore.shared.log("[download-games] download started external=\(external ? 1 : 0)")
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("madeira-import-\(UUID().uuidString)")
        let t = URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, error in
            // The temporary file only exists inside this handler: move it first.
            var moved: URL?
            var failure = error?.localizedDescription
            if let tmp, failure == nil {
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    failure = "The server answered \(http.statusCode)."
                } else {
                    let name = Self.fileName(response: response, url: url)
                    try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let dest = staging.appendingPathComponent(name)
                    do { try FileManager.default.moveItem(at: tmp, to: dest); moved = dest }
                    catch { failure = error.localizedDescription }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.observation = nil; self.task = nil
                if let moved { self.install(moved, cleanup: staging, external: external) }
                else {
                    try? FileManager.default.removeItem(at: staging)
                    self.phase = .failed(failure ?? "The download did not finish.")
                    LogStore.shared.log("[download-games] download failed", level: .error)
                }
            }
        }
        observation = t.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let total = p.totalUnitCount, done = p.completedUnitCount
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction: total > 0 ? p.fractionCompleted : nil, bytes: done)
            }
        }
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel(); task = nil; observation = nil
        if case .downloading = phase { phase = .idle }
    }

    /// A file or folder picked in Files (security-scoped) is copied in first.
    func importPicked(_ url: URL) {
        guard !phase.busy else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let external = toExternal
        phase = .installing(fraction: 0)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("madeira-import-\(UUID().uuidString)")
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let copy = staging.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                await MainActor.run { self.install(copy, cleanup: staging, external: external) }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Unpacks or moves `file` into C:\Games\<name>, then adds its program.
    private func install(_ file: URL, cleanup: URL, external: Bool) {
        phase = .installing(fraction: 0)
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: cleanup) }
            do {
                let entry = try Self.place(file, into: Self.gamesFolder(external: external)) { fraction in
                    Task { @MainActor in self.phase = .installing(fraction: fraction) }
                }
                await MainActor.run {
                    LibraryModel.shared.save(entry)
                    self.added = entry
                    self.phase = .done(title: entry.title)
                    LogStore.shared.log("[download-games] installed bits=\(entry.bits)")
                }
            } catch {
                await MainActor.run {
                    self.phase = .failed(error.localizedDescription)
                    LogStore.shared.log("[download-games] install failed", level: .error)
                }
            }
        }
    }

    // MARK: Placing files

    nonisolated static func fileName(response: URLResponse?, url: URL) -> String {
        let suggested = response?.suggestedFilename ?? ""
        let name = suggested.isEmpty || suggested == "Unknown" ? url.lastPathComponent : suggested
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return safe.isEmpty ? "download" : safe
    }

    /// A folder name under C:\Games that is not taken yet.
    nonisolated static func freshFolder(for base: String, in games: URL) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: games, withIntermediateDirectories: true)
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Game" : base
        var folder = games.appendingPathComponent(clean, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = games.appendingPathComponent("\(clean) \(n)", isDirectory: true); n += 1
        }
        return folder
    }

    nonisolated static func place(_ file: URL, into games: URL, progress: @escaping (Double) -> Void) throws -> LibraryEntry {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: file.path, isDirectory: &isDir)
        let ext = file.pathExtension.lowercased()
        let base = file.deletingPathExtension().lastPathComponent
        let folder: URL
        if isDir.boolValue {
            folder = freshFolder(for: file.lastPathComponent, in: games)
            try fm.moveItem(at: file, to: folder)
        } else if ext == "zip" {
            folder = freshFolder(for: base, in: games)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do { try ZipExtractor.extract(file, into: folder, progress: progress) }
            catch { try? fm.removeItem(at: folder); throw error }
        } else if LibraryModel.programExtensions.contains(ext) {
            folder = freshFolder(for: base, in: games)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.moveItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        } else {
            throw LibraryError.message("EmuPC can install .zip archives, Windows programs (.exe) and game folders. \(ext.isEmpty ? "This file" : "A .\(ext) file") can't be installed. If it's a .rar or .7z, unpack it in the Files app first.")
        }
        progress(1)
        guard let program = bestProgram(in: folder) else {
            throw LibraryError.message("The files were put in the \(folder.lastPathComponent) folder, but no Windows program (.exe) was found in them. Add one with + in the Library.")
        }
        var entry = try LibraryModel.inspect(program)
        entry.title = folder.lastPathComponent
        return entry
    }

    /// The most likely main program: Unreal's -Shipping binary, then a name
    /// like the folder's, then the largest; installers' helpers are skipped.
    nonisolated static func bestProgram(in folder: URL) -> URL? {
        let junk = ["unins", "crash", "redist", "dxsetup", "vcredist", "vc_redist", "helper", "report", "dotnet",
                    "easyanticheat", "be_service", "update", "launcherhelper", "ue4prereq", "ueprereq"]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                         options: [.skipsHiddenFiles]) else { return nil }
        let key = folder.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }
        var best: (url: URL, score: Int)?
        for case let url as URL in walker {
            if walker.level > 6 { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if junk.contains(where: { name.contains($0) }) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var score = size >> 20
            if name.hasSuffix("-shipping") { score += 10_000 }
            let n = name.filter { $0.isLetter || $0.isNumber }
            if !key.isEmpty, n == key || n.hasPrefix(key) || key.hasPrefix(n) { score += 5_000 }
            if name.hasPrefix("setup") || name.hasPrefix("install") { score += 1_000 }   // an installer is the thing to run
            if best == nil || score > best!.score { best = (url, score) }
        }
        return best?.url
    }
}

// MARK: - Zip extraction (streamed, so a multi-GB archive never sits in memory)

enum ZipExtractor {
    static func extract(_ zip: URL, into folder: URL, progress: (Double) -> Void) throws {
        let entries = try SaveZipReader(url: zip).entries
        let total = max(1, entries.reduce(0) { $0 + $1.size })
        let needed = Int64(entries.reduce(0) { $0 + $1.size })
        // statfs on the folder itself: right for the external drive too.
        if let free = ExternalDrive.freeBytes(atPath: folder.path), free < needed + (256 << 20) {
            throw LibraryError.message("Not enough free space: the game needs \(downloadBytes(needed)) and \(downloadBytes(free)) is free.")
        }
        let input = try FileHandle(forReadingFrom: zip)
        defer { try? input.close() }
        var done = 0
        for entry in entries {
            let name = entry.name.replacingOccurrences(of: "\\", with: "/")
            // Never write outside the game's folder (an absolute name or "../" in a
            // crafted archive). Checked on the name itself: standardizing paths
            // drops /private from some and not others, so prefix tests misfire.
            let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else { continue }
            let out = folder.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true); continue
            }
            if name.hasPrefix("__MACOSX/") { continue }
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeEntry(entry, from: input, to: out)
            done += entry.size
            progress(Double(done) / Double(total))
        }
    }

    private static func writeEntry(_ e: SaveZipReader.Entry, from input: FileHandle, to out: URL) throws {
        try input.seek(toOffset: UInt64(e.localOffset))
        guard let header = try input.read(upToCount: 30), header.count == 30,
              header.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw LibraryError.message("The zip is damaged (\(e.name)).") }
        let nlen = Int(header[26]) | Int(header[27]) << 8
        let elen = Int(header[28]) | Int(header[29]) << 8
        try input.seek(toOffset: UInt64(e.localOffset + 30 + nlen + elen))
        guard FileManager.default.createFile(atPath: out.path, contents: nil) else {
            throw LibraryError.message("Couldn't create \(out.lastPathComponent).")
        }
        let output = try FileHandle(forWritingTo: out)
        defer { try? output.close() }
        var remaining = e.compressedSize
        let chunk = 4 << 20
        switch e.method {
        case 0:
            while remaining > 0 {
                guard let data = try input.read(upToCount: min(chunk, remaining)), !data.isEmpty else {
                    throw LibraryError.message("The zip is truncated.")
                }
                try output.write(contentsOf: data); remaining -= data.count
            }
        case 8:
            var stream = z_stream()
            guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw LibraryError.message("Couldn't start decompressing.")
            }
            defer { inflateEnd(&stream) }
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var status = Z_OK
            while status != Z_STREAM_END {
                guard remaining > 0, let data = try input.read(upToCount: min(chunk, remaining)), !data.isEmpty else {
                    throw LibraryError.message("The zip is truncated (\(e.name)).")
                }
                remaining -= data.count
                try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(data.count)
                    repeat {
                        let produced: Int = try buffer.withUnsafeMutableBufferPointer { out in
                            stream.next_out = out.baseAddress
                            stream.avail_out = uInt(out.count)
                            status = inflate(&stream, Z_NO_FLUSH)
                            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                                throw LibraryError.message("\(e.name) could not be decompressed.")
                            }
                            return out.count - Int(stream.avail_out)
                        }
                        if produced > 0 { try output.write(contentsOf: Data(buffer[0..<produced])) }
                    } while stream.avail_out == 0 && status != Z_STREAM_END
                }
            }
        default:
            throw LibraryError.message("\(e.name) uses a zip compression EmuPC can't unpack (method \(e.method)). Unpack it in the Files app first.")
        }
    }
}

// MARK: - The tab

struct DownloadGamesView: View {
    let search: String
    /// Opens a game's Game details page (the library's details sheet).
    let open: (LibraryEntry) -> Void
    @ObservedObject private var importer = GameImporter.shared
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var games = SteamGamesModel.shared
    @State private var link = ""
    /// Picks go through UIKit's document picker (DocumentPicker, ExternalDrive.swift):
    /// SwiftUI presents only one .fileImporter in a hierarchy, and the other tabs have theirs.
    private enum Pick { case file, folder, drive }
    @ObservedObject private var drive = ExternalDrive.shared
    @State private var showSignIn = false
    @State private var sheetGame: DownloadGameSelection?
    @FocusState private var linkFocused: Bool

    private var steamItems: [SteamGamesRules.Item] {
        // MABD local: a game Steam has a record for but has not finished installing
        // (an interrupted or paused download) belongs here too, as on the controller
        // home's Store: only fully installed games leave the download page.
        let items = SteamGamesRules.items(installed: games.games.filter(\.installed), owned: steam.owned, search: search)
        let groups = SteamGamesRules.groups(items, downloading: Set(steam.downloads.keys))
        return groups.downloading + groups.notInstalled
    }

    /// MABD local: one store at a time, picked at the top, instead of every
    /// store stacked down the page.
    private enum Source: String, CaseIterable { case steam, gog, epic, own
        var label: String { ["Steam", "GOG", "Epic", "Your own"][Self.allCases.firstIndex(of: self)!] }
    }
    @AppStorage("madeiraDownloadSource") private var sourceRaw = Source.steam.rawValue
    private var source: Source { Source(rawValue: sourceRaw) ?? .steam }

    var body: some View {
        List {
            Section {
                Picker("Store", selection: $sourceRaw) {
                    ForEach(Source.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            switch source {
            case .steam: steamSection
            case .gog: GOGDownloadSection(search: search)
            case .epic: EpicDownloadSection(search: search)
            case .own: linkSection
            }
            installToSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await SteamGamesSection.refresh() }
        .onAppear {
            drive.restore()
            if !drive.configured { importer.toExternal = false }
            games.refresh()
            if SteamOwnedLibrary.enabled {
                steam.start()
                if steam.signedIn, !steam.refreshing, !steam.owned.isEmpty,
                   steam.owned.allSatisfy({ $0.downloadBytes == nil && $0.diskBytes == nil }) {
                    Task { await steam.refreshLibrary(interactive: false) }
                }
            }
        }
        .sheet(item: $sheetGame) { game in
            SteamGameSheet(appID: game.id) { entry in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(entry) }
            }
        }
        .sheet(isPresented: $showSignIn) { SteamSignInView() }
        .modifier(StorePageHost())
    }

    // MARK: Link or file

    private var linkSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste a download link", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($linkFocused)
                    .onSubmit(startLink)
                if !link.isEmpty && !importer.phase.busy {
                    Button(action: startLink) { Text("Get").fontWeight(.semibold) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
            if !importer.phase.busy {
                Button { choose(.file) } label: { Label("Choose a file", systemImage: "doc.zipper") }
                Button { choose(.folder) } label: { Label("Choose a game folder", systemImage: "folder") }
            }
            importStatus
        } header: {
            Text("From a link or file")
        } footer: {
            Text("A .zip, a Windows program (.exe) or a game folder, from a direct download link or the Files app (including Safari's downloads). EmuPC puts it in C:\\Games and adds it to your Library. DRM-free stores like GOG and itch.io work best.")
        }
    }

    @ViewBuilder private var importStatus: some View {
        switch importer.phase {
        case .idle:
            EmptyView()
        case .downloading(let fraction, let bytes):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction { ProgressView(value: fraction) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Text(fraction.map { "Downloading \(Int($0 * 100))% · \(downloadBytes(bytes))" } ?? "Downloading · \(downloadBytes(bytes))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Cancel", role: .destructive) { importer.cancel() }.font(.caption)
                }
            }
        case .installing(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("Installing \(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .done(let title):
            HStack {
                Label("\(title) is in your Library", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                if let entry = importer.added {
                    Button("Open") { importer.reset(); open(entry) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                Button("Dismiss") { importer.reset() }.font(.caption)
            }
        }
    }

    private func startLink() {
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        linkFocused = false
        importer.download(link)
        link = ""
    }

    private func choose(_ mode: Pick) {
        let types: [UTType] = mode == .file ? [.zip, .exe, .item] : [.folder]
        DocumentPicker.present(types: types) { url in
            guard let url else { return }
            if mode == .drive {
                drive.choose(url)
                if drive.root != nil { importer.toExternal = true }
            } else {
                importer.importPicked(url)
            }
        }
    }

    // MARK: Install to

    /// Where new games go, for both Steam and links/files. Choosing the external
    /// drive with none set up opens the folder picker for it.
    /// Where new games go, as one row: the place, its free space, and Change.
    private var installToSection: some View {
        let onDrive = importer.toExternal && drive.configured
        return Section {
            HStack(spacing: 12) {
                Image(systemName: onDrive ? (drive.root != nil ? "externaldrive.fill" : "externaldrive.badge.xmark") : "iphone")
                    .font(.title3).foregroundStyle(onDrive && drive.root == nil ? Color.orange : Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installs to \(onDrive ? (drive.name ?? "the external drive") : "this iPhone")").font(.subheadline.weight(.semibold))
                    Group {
                        if onDrive && drive.root == nil {
                            Text("Drive not connected").foregroundStyle(.orange)
                        } else if let free = onDrive ? drive.freeBytes : ExternalDrive.freeBytes(atPath: LibraryModel.drive.path) {
                            Text("\(downloadBytes(free)) free")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button { importer.toExternal = false } label: { Label("This iPhone", systemImage: "iphone") }
                    if drive.configured {
                        Button { importer.toExternal = true } label: { Label(drive.name ?? "External drive", systemImage: "externaldrive") }
                        Button { choose(.drive) } label: { Label("Choose a different drive folder", systemImage: "folder.badge.gearshape") }
                        Button(role: .destructive) { drive.forget(); importer.toExternal = false } label: { Label("Stop using this drive", systemImage: "eject") }
                    } else {
                        Button { DispatchQueue.main.async { choose(.drive) } } label: { Label("Use an external drive…", systemImage: "externaldrive.badge.plus") }
                    }
                } label: { Text("Change").fontWeight(.semibold) }
            }
            if let problem = drive.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Steam

    @ViewBuilder private var steamSection: some View {
        Section {
            if !SteamOwnedLibrary.enabled {
                Text(MadeiraDock.bundled ? "Steam downloads are turned off (env.MADEIRA_DOCK or MADEIRA_STEAM_LIBRARY in madeira.cfg)." : "Steam downloads need Madeira Dock, which this build of EmuPC doesn't include.").foregroundStyle(.secondary)
            } else if !steam.signedIn {
                SteamSignInCard { showSignIn = true }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } else if steamItems.isEmpty {
                if steam.refreshing {
                    HStack { ProgressView(); Text("Loading your Steam library…").foregroundStyle(.secondary) }
                } else {
                    Text(search.isEmpty ? (steam.libraryUpdated == nil ? "Pull down to load your Steam library."
                                           : "Every Windows game you own is installed.")
                         : "No games match \"\(search)\".").foregroundStyle(.secondary)
                }
            } else {
                ForEach(steamItems) { item in steamRow(item) }
            }
        } header: {
            HStack {
                Text("Steam")
                Spacer()
                if steam.refreshing { ProgressView().controlSize(.mini) }
            }
        } footer: {
            if steam.signedIn {
                Text("Games download straight from Steam with your account and keep going in the background. Installed games move to the Library.")
            }
        }
    }

    private func steamRow(_ item: SteamGamesRules.Item) -> some View {
        let download = steam.downloads[item.id]
        return HStack(spacing: 12) {
            Button { sheetGame = DownloadGameSelection(id: item.id) } label: {
                HStack(spacing: 12) {
                    SteamGameArtwork(appID: item.id)
                        .frame(width: 48, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        if let download {
                            SteamDownloadStatus(download: download)
                            if let folder = item.owned?.folderName,
                               SteamExternalInstall.isExternal(folderName: folder, steamApps: SteamOwnedLibrary.steamApps) {
                                Label("Installing to \(drive.name ?? "the external drive")", systemImage: "externaldrive.fill")
                                    .font(.caption).foregroundStyle(.tint)
                            }
                        } else {
                            if let size = item.owned?.diskBytes ?? item.owned?.downloadBytes64 {
                                Text("\(downloadBytes(size)) needed").font(.caption).foregroundStyle(.secondary)
                            } else if steam.refreshing {
                                Text("Getting size…").font(.caption).foregroundStyle(.secondary)
                            }
                            CompatibilityPill(appID: item.id)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            steamButton(item.id, download: download)
        }.padding(.vertical, 2)
    }

    @ViewBuilder private func steamButton(_ appID: Int, download: SteamOwnedLibrary.Download?) -> some View {
        if let download {
            switch download.state {
            case .active, .queued:
                Button { steam.pause(appID) } label: {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: download.progress.fraction)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.tint)
                    }.frame(width: 30, height: 30)
                }.buttonStyle(.plain).accessibilityLabel("Pause download")
            case .paused, .failed:
                Button { steam.install(appID) } label: { Text("Resume").fontWeight(.semibold) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            }
        } else {
            Button { steam.install(appID) } label: { Text("Get").fontWeight(.semibold).frame(minWidth: 44) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                .accessibilityLabel("Download")
        }
    }
}

private struct DownloadGameSelection: Identifiable { let id: Int }

private func downloadBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - Compatibility estimate (before downloading)

/// What can be known about a Steam game before it is downloaded: whether the
/// project has run it, its anti-cheat (the public AreWeAntiCheatYet list), and
/// the store's minimum requirements (memory, DirectX version). An estimate,
/// shown as one; it never blocks a download.
/// Log tag: [download-games] (counts only).
@MainActor
final class GameCompatibility: ObservableObject {
    static let shared = GameCompatibility()

    enum Verdict: String, Codable {
        // MABD local: offlineOnly and blocked tell anti-cheat cases apart.
        case tested, likely, maybe, offlineOnly, unlikely, blocked
        var title: String {
            switch self {
            case .tested: return "Tested"
            case .likely: return "Likely works"
            case .maybe: return "Might work"
            case .offlineOnly: return "Offline only"
            case .unlikely: return "Unlikely to run"
            case .blocked: return "Won't run"
            }
        }
        var symbol: String {
            switch self {
            case .tested: return "checkmark.seal.fill"
            case .likely: return "checkmark.circle.fill"
            case .maybe: return "questionmark.circle.fill"
            case .offlineOnly: return "wifi.slash"
            case .unlikely: return "exclamationmark.triangle.fill"
            case .blocked: return "xmark.octagon.fill"
            }
        }
        var color: Color {
            switch self {
            case .tested, .likely: return .green
            case .maybe, .offlineOnly: return .orange
            case .unlikely, .blocked: return .red
            }
        }
    }

    struct Report: Codable, Equatable {
        var verdict: Verdict
        var reasons: [String]
        var checked: Date
    }

    @Published private(set) var reports: [Int: Report] = [:]
    private var pending: [Int] = []
    private var inFlight: Set<Int> = []
    private var worker: Task<Void, Never>?
    /// Anti-cheat by Steam app: its names and the list's status (Supported,
    /// Running, Planned, Broken, Denied: how it behaves outside Windows).
    private var antiCheat: [Int: (names: [String], status: String)]?
    private var antiCheatTask: Task<Void, Never>?

    /// Games the project's releases name as running (v0.1.x notes, README).
    static let tested: Set<Int> = [356400 /* Thumper */, 1229490 /* ULTRAKILL */, 268910 /* Cuphead */,
                                   1809540 /* Nine Sols */, 1145350 /* Hades II */]

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-compat", isDirectory: true)
    }
    /// Versioned with the rules in judge(): a rule change drops the old verdicts.
    private static var reportsURL: URL { folder.appendingPathComponent("reports-v3.json") }
    private static var antiCheatURL: URL { folder.appendingPathComponent("anticheat.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.reportsURL),
           let saved = try? JSONDecoder().decode([Int: Report].self, from: data) {
            // A week old is old enough to look again (requirements and anti-cheat change).
            reports = saved.filter { $0.value.checked > Date().addingTimeInterval(-7 * 86_400) }
                // Reports saved before the app became EmuPC name it Madeira.
                .mapValues { var r = $0; r.reasons = r.reasons.map { $0.replacingOccurrences(of: "Madeira", with: "EmuPC") }; return r }
        }
    }

    /// Device memory a game can realistically use: the increased-memory-limit
    /// entitlement leaves about all but 2 GB of the phone's RAM to one app.
    nonisolated static var memoryBudgetGB: Double {
        // MABD local: a floor of 2, so a 4 GB iPad is judged by its 2 GB.
        max(2, Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 - 2)
    }

    /// Asks for a report once; rows call this as they appear.
    func request(_ appID: Int) {
        if Self.tested.contains(appID) {
            if reports[appID] == nil {
                reports[appID] = Report(verdict: .tested, reasons: ["Runs in EmuPC (tested by the project)."], checked: Date())
            }
            return
        }
        guard reports[appID] == nil, !inFlight.contains(appID), !pending.contains(appID) else { return }
        pending.append(appID)
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        await loadAntiCheat()
        while !pending.isEmpty {
            let appID = pending.removeFirst()
            inFlight.insert(appID)
            let requirements = await Self.fetchRequirements(appID)
            inFlight.remove(appID)
            let cheat = antiCheat?[appID]
            reports[appID] = Self.judge(anticheats: cheat?.names ?? [], status: cheat?.status, requirements: requirements)
            save()
            // The store API allows about 200 requests in 5 minutes.
            try? await Task.sleep(nanoseconds: 1_600_000_000)
        }
        worker = nil
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(reports).write(to: Self.reportsURL, options: .atomic)
    }

    // MARK: Sources

    private func loadAntiCheat() async {
        if antiCheat != nil { return }
        let fm = FileManager.default
        let url = Self.antiCheatURL
        let fresh = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .map { $0 > Date().addingTimeInterval(-86_400) } ?? false
        var data = fresh ? try? Data(contentsOf: url) : nil
        if data == nil, let remote = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json"),
           let (body, response) = try? await URLSession.shared.data(from: remote),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            data = body
            try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? body.write(to: url, options: .atomic)
        }
        if data == nil { data = try? Data(contentsOf: url) }   // stale beats nothing offline
        var map: [Int: (names: [String], status: String)] = [:]
        if let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for game in list {
                guard let ids = game["storeIds"] as? [String: Any],
                      let steam = (ids["steam"] as? String).flatMap(Int.init) ?? ids["steam"] as? Int,
                      let checks = game["anticheats"] as? [String], !checks.isEmpty else { continue }
                map[steam] = (checks, game["status"] as? String ?? "")
            }
        }
        antiCheat = map
        LogStore.shared.log("[download-games] anti-cheat list games=\(map.count)")
    }

    struct Requirements { var memoryGB: Double?; var directX: Int?; var text: String }

    nonisolated static func fetchRequirements(_ appID: Int) async -> Requirements? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&cc=us&l=english"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["\(appID)"] as? [String: Any],
              let details = entry["data"] as? [String: Any],
              let pc = details["pc_requirements"] as? [String: Any],
              let html = pc["minimum"] as? String else { return nil }
        return parseRequirements(html)
    }

    nonisolated static func parseRequirements(_ html: String) -> Requirements {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        func capture(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
        var memory: Double?
        if let m = capture("Memory:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(GB|MB)"), let value = Double(m[1]) {
            memory = m[2].uppercased() == "MB" ? value / 1024 : value
        }
        var directX: Int?
        if let m = capture("DirectX:?\\s*(?:Version\\s*)?([0-9]+)") { directX = Int(m[1]) }
        else if let m = capture("DirectX\\s*([0-9]+)") { directX = Int(m[1]) }
        return Requirements(memoryGB: memory, directX: directX, text: text)
    }

    nonisolated static func judge(anticheats: [String], status: String? = nil, requirements: Requirements?) -> Report {
        var verdict = Verdict.likely
        var reasons: [String] = []
        func worsen(_ v: Verdict) {
            let order: [Verdict] = [.tested, .likely, .maybe, .offlineOnly, .unlikely, .blocked]
            if order.firstIndex(of: v)! > order.firstIndex(of: verdict)! { verdict = v }
        }
        // VAC is Valve's server-side and user-mode check (it runs under Wine and on
        // Steam Deck); the others on the list are kernel or launcher anti-cheat.
        let anticheats = anticheats.filter { $0.caseInsensitiveCompare("VAC") != .orderedSame }
        if !anticheats.isEmpty {
            let names = anticheats.joined(separator: " and ")
            // MABD local: by how the anti-cheat behaves outside Windows (AreWeAntiCheatYet).
            switch status?.lowercased() {
            case "running":
                // It lets the game run without its Windows driver (Linux and Steam Deck).
                worsen(.maybe)
                reasons.append("Uses \(names), which lets the game start outside Windows. Online play may still be blocked.")
            case "supported":
                // Needs the anti-cheat's own Linux library, which has no iOS version.
                worsen(.offlineOnly)
                reasons.append("Online play needs \(names) support that only exists for Linux, not EmuPC. Single-player or offline modes may work.")
            default:
                worsen(.blocked)
                reasons.append("Uses \(names), which blocks the game outside Windows. It won't start in EmuPC.")
            }
        }
        if let r = requirements {
            let budget = memoryBudgetGB
            if let gb = r.memoryGB {
                let shown = gb == gb.rounded() ? "\(Int(gb))" : String(format: "%.1f", gb)
                // Steam lists the PC's memory, Windows included (about 2 GB of it);
                // the game itself needs roughly the rest.
                let game = max(0.5, gb - 2)
                if game > budget {
                    worsen(.unlikely)
                    reasons.append("Asks for a \(shown) GB PC; EmuPC gets about \(Int(budget)) GB on this iPhone.")
                } else if game > budget * 0.7 {
                    worsen(.maybe)
                    reasons.append("Asks for a \(shown) GB PC, close to the about \(Int(budget)) GB EmuPC gets on this iPhone.")
                } else {
                    reasons.append("Asks for a \(shown) GB PC: fits.")
                }
            }
            if let dx = r.directX {
                if dx >= 12 {
                    worsen(.maybe)
                    reasons.append("Requires DirectX 12, which is still experimental in EmuPC.")
                } else {
                    reasons.append("Uses DirectX \(dx), which EmuPC supports.")
                }
            }
            if r.text.range(of: "vulkan", options: .caseInsensitive) != nil && (r.directX ?? 0) == 0 {
                worsen(.maybe)
                reasons.append("Mentions Vulkan, which EmuPC doesn't support yet.")
            }
        } else {
            reasons.append("Steam didn't list system requirements, so this is a guess.")
        }
        if verdict == .likely { reasons.insert("No known blockers. Performance varies from game to game.", at: 0) }
        return Report(verdict: verdict, reasons: reasons, checked: Date())
    }
}

/// A game's compatibility pill (Download games rows).
struct CompatibilityPill: View {
    let appID: Int
    @ObservedObject private var compat = GameCompatibility.shared
    var body: some View {
        Group {
            if let report = compat.reports[appID] {
                Label(report.verdict.title, systemImage: report.verdict.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(report.verdict.color)
                    .labelStyle(.titleAndIcon)
            } else {
                Label("Checking compatibility…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { compat.request(appID) }
    }
}

/// The download sheet's "Before you download" section: sizes against free
/// space, and the compatibility estimate with its reasons.
struct SteamBeforeDownloadSection: View {
    let appID: Int
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var compat = GameCompatibility.shared
    @ObservedObject private var drive = ExternalDrive.shared
    @ObservedObject private var importer = GameImporter.shared
    @State private var free: Int64?
    /// A first install goes to the external drive (SteamExternalInstall).
    private var external: Bool { importer.toExternal && drive.configured }
    var body: some View {
        let game = steam.owned.first { $0.id == appID }
        Section {
            if drive.configured {
                Picker("Install to", selection: $importer.toExternal) {
                    Text("This iPhone").tag(false)
                    Text(drive.name ?? "External drive").tag(true)
                }
            } else {
                LabeledContent("Install to", value: "This iPhone")
            }
            if let bytes = game?.downloadBytes64 { LabeledContent("Download", value: "about \(downloadBytes(bytes))") }
            if let bytes = game?.diskBytes { LabeledContent("Space needed", value: "about \(downloadBytes(bytes))") }
            if external {
                if let driveFree = drive.freeBytes { LabeledContent("Free on the drive", value: downloadBytes(driveFree)) }
            } else if let free { LabeledContent("Free on this iPhone", value: downloadBytes(free)) }
            if let need = game?.diskBytes ?? game?.downloadBytes64, let room = external ? drive.freeBytes : free, need > room {
                Label("Not enough free space. Free up \(downloadBytes(need - room)) \(external ? "on the drive" : "") to install this game.",
                      systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
            }
            if game?.downloadBytes == nil && game?.diskBytes == nil {
                if steam.refreshing {
                    HStack(spacing: 8) { ProgressView(); Text("Getting the game's size from Steam…").foregroundStyle(.secondary) }
                } else {
                    Text("Steam didn't report a size for this game.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let report = compat.reports[appID] {
                Label(report.verdict.title, systemImage: report.verdict.symbol)
                    .foregroundStyle(report.verdict.color).font(.headline)
                ForEach(report.reasons, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Checking compatibility…").foregroundStyle(.secondary) }
            }
        } header: { Text("Before you download") } footer: {
            Text("Compatibility is an estimate from the game's anti-cheat and Steam's minimum requirements. Sizes are Steam's figures for the Windows version.")
        }
        .onAppear {
            compat.request(appID)
            free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
    }
}
