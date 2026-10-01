#!/usr/bin/env swift
// Checks an update archive's EdDSA signature against a Sparkle public key — the
// same Ed25519 verification Sparkle performs before it installs an update.
// release-build.sh runs it with the SUPublicEDKey read out of the *built*
// app's Info.plist, so a release whose appcast signature the shipped app would
// reject (a wrong or rotated private key, a placeholder public key) fails the
// build instead of stranding every user on the version they already have.
// Usage: swift scripts/verify-sparkle-signature.swift <public-key-b64> <signature-b64> <archive>

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
  print("usage: verify-sparkle-signature.swift <public-key-b64> <signature-b64> <archive>")
  exit(2)
}

guard let publicKeyData = Data(base64Encoded: CommandLine.arguments[1]),
  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
else {
  print("error: the public key is not a base64 Ed25519 key")
  exit(1)
}
guard let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
  print("error: the signature is not base64")
  exit(1)
}
guard let archive = FileManager.default.contents(atPath: CommandLine.arguments[3]) else {
  print("error: could not read \(CommandLine.arguments[3])")
  exit(1)
}

guard publicKey.isValidSignature(signature, for: archive) else {
  print("error: the signature does not verify against the public key")
  exit(1)
}
print("EdDSA signature verifies against the app's public key")
