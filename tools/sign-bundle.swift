#!/usr/bin/env swift
// Sign rule bundles with ed25519. The app refuses any bundle whose signature
// doesn't verify against its public key (Resources/rules-signing.pub.raw).
//
// Canonicalisation is RuleVerifier.canonicalize in ios/NoScroll/Core/RuleBundle.swift,
// copied verbatim: drop `signature`, serialise with sorted keys and unescaped
// slashes. Using the same Foundation call on both sides is what guarantees the
// bytes agree.
//
// Usage (from the repo root):
//   swift tools/sign-bundle.swift keygen               -> keys/rules-signing.private.raw
//                                                         + the app's public key
//   swift tools/sign-bundle.swift sign rules/*.json    -> signs in place, then copies
//                                                         each bundle into the app
//   swift tools/sign-bundle.swift verify <files...>
//
// keys/*.raw is gitignored. Back up the private key: losing it means every
// copy of the app in the wild can only ever load its baked rules.

import CryptoKit
import Foundation

// getcwd() can fail outright in sandboxed shells; the shell's PWD is exact.
let cwdPath = ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
let cwd = URL(fileURLWithPath: cwdPath, isDirectory: true)
let root = cwd
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("ios/NoScroll").path) else {
    FileHandle.standardError.write(Data("error: run this from the repo root\n".utf8))
    exit(1)
}
let privateKeyURL = root.appendingPathComponent("keys/rules-signing.private.raw")
let appPublicKeyURL = root.appendingPathComponent("ios/NoScroll/Resources/rules-signing.pub.raw")
let appRulesDir = "ios/NoScroll/Resources/Rules"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func canonicalize(_ raw: Data) throws -> Data {
    guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        fail("top level is not an object")
    }
    obj.removeValue(forKey: "signature")
    return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
}

func publicKey() throws -> Curve25519.Signing.PublicKey {
    try Curve25519.Signing.PublicKey(rawRepresentation: Data(contentsOf: appPublicKeyURL))
}

/// Rewrites only the signature value, so the file keeps its hand formatting.
func replaceSignature(in text: String, with signature: String) -> String {
    let pattern = #""signature"\s*:\s*"[^"]*""#
    guard let range = text.range(of: pattern, options: .regularExpression) else {
        fail("no \"signature\" field to replace")
    }
    return text.replacingCharacters(in: range, with: "\"signature\": \"\(signature)\"")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: keygen | sign <files> | verify <files>") }
let files = args.dropFirst().map { URL(fileURLWithPath: $0, relativeTo: cwd).absoluteURL }

switch command {
case "keygen":
    if FileManager.default.fileExists(atPath: privateKeyURL.path) {
        fail("\(privateKeyURL.path) already exists; refusing to overwrite it")
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: privateKeyURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try key.rawRepresentation.write(to: privateKeyURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
    try key.publicKey.rawRepresentation.write(to: appPublicKeyURL)
    print("private key: \(privateKeyURL.path)")
    print("public key:  \(appPublicKeyURL.path) (the app now trusts only this key)")

case "sign":
    guard let keyData = try? Data(contentsOf: privateKeyURL) else { fail("no private key; run keygen first") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    guard key.publicKey.rawRepresentation == (try? Data(contentsOf: appPublicKeyURL)) else {
        fail("private key does not match the app's public key")
    }
    for file in files {
        let raw = try Data(contentsOf: file)
        let signature = try key.signature(for: canonicalize(raw)).base64EncodedString()
        let signed = replaceSignature(in: String(decoding: raw, as: UTF8.self), with: signature)
        try Data(signed.utf8).write(to: file)
        let copy = root.appendingPathComponent(appRulesDir).appendingPathComponent(file.lastPathComponent)
        try Data(signed.utf8).write(to: copy)
        print("signed \(file.lastPathComponent)")
    }

case "verify":
    let key = try publicKey()
    var bad = 0
    for file in files {
        let raw = try Data(contentsOf: file)
        guard let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let b64 = obj["signature"] as? String, let sig = Data(base64Encoded: b64),
              key.isValidSignature(sig, for: try canonicalize(raw))
        else { print("BAD  \(file.lastPathComponent)"); bad += 1; continue }
        print("ok   \(file.lastPathComponent)")
    }
    if bad > 0 { exit(1) }

default:
    fail("unknown command \(command)")
}
