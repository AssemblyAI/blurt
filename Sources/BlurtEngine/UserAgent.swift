import Foundation

/// The `User-Agent` every AssemblyAI request carries: the host's product name
/// and the running build's short version: `Blurt/0.1.54` from a 0.1.54 build.
///
/// Without it the service sees `URLSession`'s default (`Blurt/1 CFNetwork/…
/// Darwin/…`, keyed off `CFBundleVersion`, the opaque build counter), so a
/// report of "dictation got slow in the last release" can't be tied to a
/// release at all. Naming the client and its marketing version is what makes a
/// server-side latency or error-rate regression attributable to the build that
/// introduced it.
///
/// **Not an API parameter.** `AssemblyAITranscriber` only sends fields the
/// dictation reference documents, and the reference documents exactly two
/// headers (`Authorization`, and the multipart `Content-Type`). This is neither
/// an exception to that rule nor a gap in it: `User-Agent` is a standard HTTP
/// request header that the client already sends on every one of these requests
/// — the only question is whether it says something useful.
///
/// Deliberately just those two tokens. macOS version, architecture and locale
/// are the conventional rest of a browser-shaped `User-Agent`, and each would be
/// one more thing about the user going to the service to answer a question
/// nobody has asked yet; the version answers the one that gets asked.
enum UserAgent {
  /// The header this stamps. Named once so the three call sites can't disagree
  /// about the spelling with each other or with the tests.
  static let headerField = "User-Agent"

  /// Resolved once per process, on first use. That makes it a `static let` with
  /// the same ordering requirement as the engine's loggers — it reads
  /// `HostIdentity.current`, so a host that calls `HostIdentity.configure(_:)`
  /// after its first AssemblyAI request would find this already fixed to
  /// `.blurt`'s product name. `configure(_:)` documents that contract for all
  /// of its lazy readers; this is one of them.
  static let current = value(
    product: HostIdentity.current.productName, version: bundleShortVersion())

  /// The pure half, so the formatting is testable without a bundle: `product`
  /// alone when there is no usable version, `product/version` otherwise.
  ///
  /// Spaces in `product` become hyphens because a `User-Agent` product token
  /// may not contain whitespace (RFC 9110) — Blurt's own name has none, but
  /// `HostIdentity` exists so another app can supply its own, and a two-word
  /// one would otherwise put a malformed header on the wire.
  ///
  /// A missing version degrades to the bare product name rather than a
  /// placeholder: `Blurt/unknown` reads like a version and would have to be
  /// special-cased by anything parsing one, while `Blurt` is a complete and
  /// valid `User-Agent` that still identifies the client.
  static func value(product: String, version: String?) -> String {
    let token = product.replacingOccurrences(of: " ", with: "-")
    guard let version = version.trimmedNonEmpty() else { return token }
    return "\(token)/\(version)"
  }

  /// `CFBundleShortVersionString` — the marketing version (`0.1.54`), the same
  /// key the update check compares against GitHub's release tags, not the
  /// `CFBundleVersion` build counter that `URLSession`'s default agent reports.
  ///
  /// Absent when the engine is loaded by something with no versioned bundle,
  /// which in practice means `swift test`; the fallback above is what that
  /// case gets.
  private static func bundleShortVersion() -> String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }
}

extension URLRequest {
  /// Stamp `UserAgent.current` on this request. One call at each of the three
  /// places the engine talks to AssemblyAI (the dictation POST, its warm-up
  /// GET, and the key validator), rather than a `URLSession` configured with
  /// `httpAdditionalHeaders` — the transport is an injected `HTTPTransport`
  /// (`URLSession.shared` in production, a fake in tests), so there is no
  /// session this layer owns to hang a default header off.
  mutating func setUserAgent() {
    setValue(UserAgent.current, forHTTPHeaderField: UserAgent.headerField)
  }
}
