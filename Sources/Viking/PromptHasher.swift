import Foundation
import CryptoKit

/// Salted, on-device hash of an LLM request-body prefix. Only the digest
/// ever leaves the device - the prompt content is never stored or sent.
/// The salt is the stable install id, so equal prefixes collide within
/// one install (which is what the cache-off recommendation rule groups
/// on) while the hash is meaningless anywhere else. Format matches the
/// Python SDK's `hash_prompt_prefix` (pfx_ + 32 hex chars).
enum PromptHasher {
    static let defaultPrefixBytes = 4000

    static func prefixHash(
        of body: Data,
        salt: String,
        prefixBytes: Int = defaultPrefixBytes
    ) -> String? {
        guard !body.isEmpty, !salt.isEmpty else { return nil }
        var salted = Data(salt.utf8)
        salted.append(body.prefix(prefixBytes))
        let hex = SHA256.hash(data: salted).map { String(format: "%02x", $0) }.joined()
        return "pfx_" + String(hex.prefix(32))
    }
}
