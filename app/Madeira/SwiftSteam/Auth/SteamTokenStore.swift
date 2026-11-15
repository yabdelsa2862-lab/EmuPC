// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance").

import Foundation
import Security

/// Securely stores Steam authentication tokens in the Keychain
class SteamTokenStore {
    private let serviceName = "madeira.steam.tokens"

    struct StoredTokens: Codable {
        var accountName: String
        var refreshToken: String
        var accessToken: String
        var steamID: UInt64
        var savedAt: Date
    }

    // MARK: - Public API

    /// Save tokens to Keychain
    func saveTokens(accountName: String, refreshToken: String, accessToken: String, steamID: UInt64) {
        let tokens = StoredTokens(
            accountName: accountName,
            refreshToken: refreshToken,
            accessToken: accessToken,
            steamID: steamID,
            savedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(tokens) else {
            SteamLog.trace("Failed to encode tokens for storage")
            return
        }

        // Update in place (StoreKeychain): never delete first, so a failed save
        // can't lose the sign-in.
        if StoreKeychain.write(data, service: serviceName, account: "steam_tokens") {
            SteamLog.trace("Tokens saved to Keychain")
        } else {
            SteamLog.trace("Failed to save tokens to Keychain")
        }
    }

    /// Load tokens from Keychain
    func loadTokens() -> StoredTokens? {
        guard case .found(let data) = StoreKeychain.read(service: serviceName, account: "steam_tokens"),
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            return nil
        }

        return tokens
    }

    /// Clear all stored tokens (sign out)
    func clearTokens() {
        deleteKeychainItem()
        SteamLog.trace("Tokens cleared from Keychain")
    }

    /// Check if we have stored tokens
    var hasTokens: Bool {
        loadTokens() != nil
    }

    // MARK: - Private

    private func deleteKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "steam_tokens"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
