// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Games on an external drive (a USB-C SSD or card reader the Files app shows).
// The user picks a folder on the drive once; Madeira keeps a bookmark to it,
// holds its security scope for the life of the process and links it into the
// prefix as C:\External, so Wine, the library and Dock see it as part of C:.
// LibraryModel accepts programs under this folder as well as under drive_c
// (LibraryModel.relativeToDrive). Unplugging the drive leaves the link dangling:
// its games then report missing files until it is back.
// Log tag: [external-drive] (states only, never paths or names).

final class ExternalDrive: ObservableObject, @unchecked Sendable {
    static let shared = ExternalDrive()
    /// The link's name in drive_c: games there are C:\External\...
    static let linkName = "External"
    private static let bookmarkKey = "madeiraExternalDriveBookmark"

    /// The chosen folder, resolved, while it is reachable.
    @Published private(set) var root: URL?
    /// The folder's name as Files shows it, kept while the drive is away.
    @Published private(set) var name: String?
    @Published private(set) var problem: String?

    private let lock = NSLock()
    private var _rootPath: String?
    private var scoped: URL?

    /// The resolved folder path for the library's checks (any thread).
    static var rootPath: String? {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared._rootPath
    }

    var configured: Bool { UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil }

    /// At launch and whenever the library or Download games appears.
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            set(nil, problem: "The external drive isn't connected.")
            return
        }
        activate(url)
        if stale, root != nil, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
    }

    /// A folder picked in Files (DownloadGamesView's folder importer).
    func choose(_ url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        LogStore.shared.log("[external-drive] picked scoped=\(started ? 1 : 0) exists=\(FileManager.default.fileExists(atPath: url.path) ? 1 : 0) writable=\(FileManager.default.isWritableFile(atPath: url.path) ? 1 : 0)")
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            LogStore.shared.log("[external-drive] bookmark failed: \(error.localizedDescription)", level: .error)
            set(nil, problem: "EmuPC couldn't keep access to that folder: \(error.localizedDescription)")
            return
        }
        // Madeira writes games there: say so now rather than at the first install.
        if !FileManager.default.isWritableFile(atPath: url.path) {
            LogStore.shared.log("[external-drive] read-only", level: .error)
        }
        restore()
        LogStore.shared.log("[external-drive] chosen reachable=\(root != nil ? 1 : 0)")
    }

    /// A problem found outside this class (the folder picker failing).
    func report(_ problem: String) { set(root, problem: problem) }

    /// Stops using the drive. Its files stay where they are; the link goes.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        if let scoped { scoped.stopAccessingSecurityScopedResource() }
        scoped = nil
        set(nil, problem: nil)
        name = nil
        try? FileManager.default.removeItem(at: Self.linkURL)
        LogStore.shared.log("[external-drive] forgotten")
    }

    private static var linkURL: URL { LibraryModel.drive.appendingPathComponent(linkName) }

    private func activate(_ url: URL) {
        if scoped?.path != url.path {
            if let scoped { scoped.stopAccessingSecurityScopedResource() }
            scoped = url.startAccessingSecurityScopedResource() ? url : nil
        }
        name = url.lastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            set(nil, problem: "The external drive isn't connected.")
            LogStore.shared.log("[external-drive] unreachable")
            return
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            set(nil, problem: "EmuPC can read this drive but not write to it. It may be formatted as NTFS (read-only on iPhone) or locked: reformat it as exFAT or APFS on a computer.")
            LogStore.shared.log("[external-drive] not writable", level: .error)
            return
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        set(resolved, problem: nil)
        link(to: resolved)
    }

    private func set(_ url: URL?, problem: String?) {
        lock.lock(); _rootPath = url?.path; lock.unlock()
        let apply = { self.root = url; self.problem = problem }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// drive_c/External -> the chosen folder (absolute, so Wine's lookups follow it).
    private func link(to target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: LibraryModel.drive.path) else { return }   // made with the prefix
        let link = Self.linkURL
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path), existing == target.path { return }
        if (try? fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            // A real folder of that name in drive_c is the user's: never replace it.
            set(root, problem: "C:\\External already exists as a folder, so the drive can't be linked there.")
            return
        }
        do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path) }
        catch { set(root, problem: "Couldn't link the drive into C:: \(error.localizedDescription)") }
    }

    /// Free space on the drive, when it is connected.
    var freeBytes: Int64? {
        guard let root else { return nil }
        return Self.freeBytes(atPath: root.path)
    }

    /// Free space of the file system a path is on, asked of that file system
    /// (statfs). URL resource values' "important usage" capacity reports the
    /// iPhone's own storage even for a path on an external drive.
    static func freeBytes(atPath path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let (bytes, overflow) = Int64(info.f_bavail).multipliedReportingOverflow(by: Int64(info.f_bsize))
        return overflow ? Int64.max : bytes
    }
}

// MARK: - Steam games on the external drive

/// A first Steam install with Download games' "Install to" set to the drive:
/// steamapps/common/<installdir> on the phone becomes a link to
/// <drive>/SteamLibrary/common/<installdir>. The downloader writes files in
/// place through it, the install record stays on the phone where Madeira Dock
/// and Valve's client read it, and Wine follows the link like any folder.
/// Uninstall removes both (SteamInstallFiles.delete).
@MainActor
enum SteamExternalInstall {
    /// nil to go ahead, or why the install can't start.
    static func prepare(appID: Int, folderName: String?, steamApps: URL) -> String? {
        guard GameImporter.shared.toExternal, ExternalDrive.shared.configured, let folderName else { return nil }
        let fm = FileManager.default
        let common = steamApps.appendingPathComponent("common", isDirectory: true)
        let link = common.appendingPathComponent(folderName)
        // Installed, partly downloaded or being updated: it stays where it is.
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) { return nil }
        guard let root = ExternalDrive.rootPath else {
            return "The external drive isn't connected. Plug it in, or set Install to: This iPhone in Download games."
        }
        let target = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("SteamLibrary/common", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: common, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        } catch {
            return "Couldn't prepare the external drive: \(error.localizedDescription)"
        }
        LogStore.shared.log("[external-drive] steam app=\(appID) linked")
        return nil
    }

    /// Whether an installed Steam game's folder lives on the external drive.
    static func isExternal(folderName: String, steamApps: URL) -> Bool {
        let link = steamApps.appendingPathComponent("common", isDirectory: true).appendingPathComponent(folderName)
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
    }
}

// MARK: - Document picker (UIKit)

/// UIDocumentPickerViewController presented over the top view controller.
/// SwiftUI's .fileImporter is not used here: the library's tabs carry their own
/// importers, and with several in one hierarchy only one of them presents.
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    private static var current: DocumentPicker?
    private let completion: (URL?) -> Void

    private init(_ completion: @escaping (URL?) -> Void) { self.completion = completion }

    @MainActor
    static func present(types: [UTType], completion: @escaping (URL?) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        let handler = DocumentPicker(completion)
        current = handler
        picker.delegate = handler
        guard let top = topViewController() else {
            LogStore.shared.log("[download-games] picker: no view controller to present from", level: .error)
            current = nil; completion(nil); return
        }
        LogStore.shared.log("[download-games] picker opened types=\(types.map(\.identifier).joined(separator: ","))")
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        LogStore.shared.log("[download-games] picker picked count=\(urls.count)")
        completion(urls.first); Self.current = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        LogStore.shared.log("[download-games] picker cancelled")
        completion(nil); Self.current = nil
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
