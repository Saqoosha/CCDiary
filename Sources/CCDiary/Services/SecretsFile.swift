import Foundation
import os.log

/// File-based secrets fallback that lets `ccdiary-cli` run from launchd
/// without triggering Keychain ACL prompts.
///
/// macOS Keychain ACLs are tied to the calling binary's code signature.
/// Each Release rebuild changes the ad-hoc signature, so the LaunchAgent
/// gets prompted at 04:00 and waits indefinitely. A plain file under
/// `~/.config/ccdiary/secrets` (chmod 600) sidesteps the prompt entirely.
///
/// Format: `KEY=value` per line. Blank lines and lines starting with `#`
/// are ignored. Values may be wrapped in single or double quotes.
enum SecretsFile {
    private static let logger = Logger(subsystem: "CCDiary", category: "SecretsFile")
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: [String: String]?

    /// Default location: `$XDG_CONFIG_HOME/ccdiary/secrets` or `~/.config/ccdiary/secrets`.
    static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["CCDIARY_SECRETS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base: URL
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        return base.appendingPathComponent("ccdiary").appendingPathComponent("secrets")
    }

    /// Returns the value for `key`, or nil if the file is missing/unreadable
    /// or doesn't define the key. Trims whitespace and treats empty as missing.
    static func value(for key: String) -> String? {
        guard let dict = load() else { return nil }
        guard let raw = dict[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drops the in-memory cache so the next `value(for:)` re-reads the file.
    /// Mainly useful in tests.
    static func resetCache() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    private static func load() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let url = defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            cached = [:]
            return cached
        }

        // Warn (but still load) when permissions are too open. The file holds
        // bot tokens and bearer tokens; group/world readability is a leak.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let perms = attrs[.posixPermissions] as? NSNumber,
           perms.uint16Value & 0o077 != 0 {
            logger.notice("Secrets file \(url.path, privacy: .public) has loose permissions \(String(perms.uint16Value, radix: 8), privacy: .public); recommend chmod 600.")
        }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to read secrets file at \(url.path, privacy: .public)")
            cached = [:]
            return cached
        }

        var dict: [String: String] = [:]
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                let first = value.first!
                let last = value.last!
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if !key.isEmpty {
                dict[key] = value
            }
        }
        cached = dict
        return cached
    }
}

/// Resolves a secret in the canonical order: process env → secrets file → Keychain.
/// Centralizes the lookup so every call site picks up the same precedence.
enum SecretResolver {
    static func value(envKey: String, keychainService: String?) -> String? {
        if let env = ProcessInfo.processInfo.environment[envKey],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        if let fileValue = SecretsFile.value(for: envKey) {
            return fileValue
        }
        if let keychainService, let key = KeychainHelper.load(service: keychainService) {
            return key
        }
        return nil
    }
}
