// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// EmuPC: EmuPC's controller home and store pages (ControllerHome.swift,
// StoreInfo.swift, Profile.swift) were written against EmuPC's own GOG
// downloader. Upstream Madeira's GOG store (GOGLibrary.swift, SwiftGOG/)
// replaced it in the 2026-11-03 merge; these are the few names those pages
// use, in terms of upstream's, as EpicCompat.swift does for Epic.

extension GOGOwnedGame {
    /// The tile picture: GOG's wide one, else the cover.
    var image: String? { (wide ?? cover)?.absoluteString }
}

extension GOGLibrary.Download {
    var fraction: Double { progress.fraction }
    var total: Int64 { Int64(progress.totalBytes) }
}

extension GOGLibrary {
    /// Owned games that are not installed (the Store's GOG row).
    var notInstalled: [GOGOwnedGame] { owned.filter { installed[$0.id] == nil } }
    /// Sizes in the store pages' terms; GOG's own answer is in `sizes`.
    var storeSizes: [String: StoreSize] {
        sizes.compactMapValues { if case .known(let d, let i) = $0 { return StoreSize(download: d, disk: i) } else { return nil } }
    }
    func requestSize(_ id: String) { Task { await loadSize(id) } }
}
