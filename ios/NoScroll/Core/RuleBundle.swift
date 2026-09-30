import CryptoKit
import Foundation

/// A rule bundle is DATA: CSS selectors and URL patterns per service, which the
/// injected engine interprets. Verified natively before it reaches the WebView.
struct RuleBundle: Codable, Sendable {
    let minEngine: Int
    var signature: String?
    let services: [String: Service]

    struct Service: Codable, Sendable {
        let surfaces: [String: Surface]
    }

    /// Decoded loosely: the engine is the interpreter, so the shell only needs
    /// the fields it actually shows in settings UI.
    struct Surface: Codable, Sendable {
        var defaultEnabled: Bool?
        var label: String?
    }
}

enum BundleError: Error {
    case badSignature
    case engineTooOld
    case malformed
}

/// Verifies a rule bundle's ed25519 signature before it reaches a web view.
/// Bundles ship inside the app (Resources/Rules) and are signed with
/// tools/sign-bundle.swift; a bundle that doesn't verify is refused.
struct RuleVerifier {
    static let engineVersion = 1

    private let publicKey: Curve25519.Signing.PublicKey

    init(publicKeyRaw: Data) throws {
        self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)
    }

    /// Canonical form for signing: the bundle JSON with `signature` removed,
    /// serialised with sorted keys. Must match tools/sign-bundle.swift exactly.
    ///
    /// `.withoutEscapingSlashes` is NOT optional here. JSONSerialization escapes
    /// every forward slash as `\/` by default, which changes the bytes and makes
    /// every signature fail.
    static func canonicalize(_ raw: Data) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw BundleError.malformed
        }
        obj.removeValue(forKey: "signature")
        return try JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    func verify(_ raw: Data) throws -> RuleBundle {
        let bundle = try JSONDecoder().decode(RuleBundle.self, from: raw)

        guard bundle.minEngine <= Self.engineVersion else {
            throw BundleError.engineTooOld
        }
        guard let sigB64 = bundle.signature, let sig = Data(base64Encoded: sigB64) else {
            throw BundleError.badSignature
        }
        guard publicKey.isValidSignature(sig, for: try Self.canonicalize(raw)) else {
            throw BundleError.badSignature
        }
        return bundle
    }
}
