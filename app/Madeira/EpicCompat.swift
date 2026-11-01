// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// EmuPC: EmuPC's controller home and store pages (ControllerHome.swift,
// StoreInfo.swift) were written against EmuPC's own Epic integration. Upstream
// Madeira's (EpicLibrary.swift, SwiftEpic/) replaced it in the 2026-10-29
// merge; these are the few names those pages use, in terms of upstream's.

typealias EpicGame = EpicOwnedGame

extension EpicOwnedGame {
    /// Epic's image service resizes on request.
    static func sized(_ url: String?, width: Int, height: Int) -> URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url + (url.contains("?") ? "&" : "?") + "w=\(width)&h=\(height)&resize=1&quality=medium")
    }
    var poster: URL? { Self.sized((cover ?? wide)?.absoluteString, width: 360, height: 480) }
    var banner: URL? { Self.sized((wide ?? cover)?.absoluteString, width: 960, height: 540) }
}

extension EpicLibrary.Download {
    var fraction: Double { progress.fraction }
    var total: Int64 { Int64(progress.totalBytes) }
}

extension EpicLibrary {
    /// Owned games that are not installed (the Store's Epic row).
    var notInstalled: [EpicOwnedGame] { owned.filter { installed[$0.appName] == nil } }
    /// Download sizes are not read ahead of an install here.
    var sizes: [String: StoreSize] { [:] }
    func requestSize(_ app: String) {}
}
