// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security

/// One Keychain helper for every store's sign-in (Steam, Epic, GOG, EA, itch.io), so
/// they all stay signed in the way Steam does.
///
/// What used to sign people out:
/// - Items were readable only while the phone was unlocked. A refresh while EmuPC ran
///   in the background with the screen locked read "nothing", and the store treated
///   that as signed out for the rest of the run.
/// - Saving deleted the item, then added the new one. If the add failed (locked),
///   the sign-in was gone. Epic and GOG hand out a new refresh token on every
///   refresh and refuse the old one, so a lost save was a lost account.
///
/// Now: items are readable after the first unlock since boot (still this device
/// only, never synced), saves update in place, and a locked Keychain is reported
/// as `.unavailable`, which callers must not treat as signed out.
enum StoreKeychain {
    enum Read {
        case found(Data)
        case missing
        /// The Keychain couldn't be read right now (locked, or busy). Try again later.
        case unavailable(OSStatus)
    }

    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private static var migrated = Set<String>()
    private static let lock = NSLock()

    static func read(service: String, account: String) -> Read {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .missing }
            migrate(service: service, account: account)
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            LogStore.shared.log("[keychain] \(service) read unavailable status=\(status)")
            return .unavailable(status)
        }
    }

    /// Updates the item in place, or adds it. Never deletes first.
    @discardableResult static func write(_ data: Data, service: String, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query.merging(attributes) { $1 }
            add[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { LogStore.shared.log("[keychain] \(service) save failed status=\(status)") }
        return status == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    /// Items saved by older builds were readable only while unlocked: move them to
    /// after-first-unlock, once per run.
    private static func migrate(service: String, account: String) {
        let key = service + "/" + account
        lock.lock()
        let done = !migrated.insert(key).inserted
        lock.unlock()
        if done { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
    }
}
