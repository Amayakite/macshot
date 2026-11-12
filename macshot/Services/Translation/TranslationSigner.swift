import CryptoKit
import Foundation

/// Request signing for the vendors that never send their secret over the wire:
/// each request carries a digest over its own parameters instead.
///
/// Pure string → string functions on purpose. Signing is the part of these APIs
/// that fails most quietly (a wrong digest comes back as "invalid sign" with no
/// hint about which parameter was wrong), so it is kept trivially testable.
enum TranslationSigner {

    /// Baidu: `md5(appid + query + salt + secret)`.
    static func md5Hex(_ input: String) -> String {
        hex(Insecure.MD5.hash(data: Data(input.utf8)))
    }

    /// Youdao v3: `sha256(appKey + queryFingerprint + salt + curtime + secret)`.
    static func sha256Hex(_ input: String) -> String {
        hex(SHA256.hash(data: Data(input.utf8)))
    }

    /// Youdao hashes a shortened form of the query, not the query itself: inputs
    /// up to 20 characters are used whole, longer ones become
    /// `first 10 + character count + last 10`.
    static func youdaoQueryFingerprint(_ query: String) -> String {
        guard query.count > 20 else { return query }
        let first = String(query.prefix(10))
        let last = String(query.suffix(10))
        return "\(first)\(query.count)\(last)"
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
