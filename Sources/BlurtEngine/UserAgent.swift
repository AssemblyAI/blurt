import Foundation

/// The `User-Agent` every AssemblyAI request carries: the host's product name,
/// the running build's short version, and a comment naming the OS — plus the
/// channel, for anything that is not a release build.
///
///     Blurt/0.1.54 (macOS 15.5)
///     Blurt/0.1.54 (macOS 15.5; dev)
///
/// Without it the service sees `URLSession`'s default, whose version token is
/// `CFBundleVersion` — the opaque build counter (`Blurt/1`), not the release
/// anyone reports a problem against. So a report of "dictation got slow in the
/// last release" could not be tied to a release at all. These three are the
/// dimensions worth *aggregating* by: which build, which OS, and whether it was
/// a real user at all.
///
/// **Strictly less than the header it replaced.** `URLSession`'s default was
/// `Blurt/1 CFNetwork/3826.x Darwin/24.5.0`, and that `Darwin/24.5.0` is the
/// macOS version in kernel form — so naming the OS here restores what was
/// already going out, in a form a human can read, while dropping the CFNetwork
/// build. The major and minor only: the patch level is finer than any question
/// being asked of this, and Blurt's deployment target spans macOS 15 through 26
/// (`if #available(macOS 26)` gating in the app shell), which is the variance
/// that actually explains a bug.
///
/// **What is deliberately absent.** Architecture — `project.yml` pins
/// `ARCHS: arm64`, so it would be a constant. `CFBundleVersion` —
/// `release-bump.sh` bumps it in lockstep with the short version, so it
/// separates no two shipped builds, and the channel below covers local
/// rebuilds. Locale or language — the dictation config deliberately sends no
/// `language_code(s)` (a settled decision `check-invariants.sh` mechanizes), and
/// a header is not a way around that. And anything per-install: an install id or
/// a session counter is exactly the telemetry the README promises Blurt does not
/// send, and the dictation response's own `session_id` already identifies a
/// single request for support.
///
/// **Not an API parameter.** `AssemblyAITranscriber` only sends fields the
/// dictation reference documents, and the reference documents exactly two
/// headers (`Authorization`, and the multipart `Content-Type`). This is neither
/// an exception to that rule nor a gap in it: `User-Agent` is a standard HTTP
/// request header that the client already sends on every one of these requests
/// — the only question is whether it says something useful.
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
    product: HostIdentity.current.productName,
    version: bundleShortVersion(),
    details: [osDetail(), channelDetail()].compactMap { $0 })

  /// The pure half, so the formatting is testable without a bundle, an OS
  /// version, or a build configuration: `product` alone when there is no usable
  /// version, then `/version`, then `details` as a parenthesized comment joined
  /// with `; ` — the shape RFC 9110 gives a product token and its comment.
  ///
  /// Spaces in `product` become hyphens because a `User-Agent` product token
  /// may not contain whitespace — Blurt's own name has none, but `HostIdentity`
  /// exists so another app can supply its own, and a two-word one would
  /// otherwise put a malformed header on the wire.
  ///
  /// A missing version degrades to the bare product name rather than a
  /// placeholder: `Blurt/unknown` reads like a version and would have to be
  /// special-cased by anything parsing one, while `Blurt` is a complete and
  /// valid `User-Agent` that still identifies the client. Blank details drop
  /// out for the same reason, and no details at all means no empty `()`.
  static func value(product: String, version: String?, details: [String]) -> String {
    let token = product.replacingOccurrences(of: " ", with: "-")
    let name = version.trimmedNonEmpty().map { "\(token)/\($0)" } ?? token
    let comment = details.compactMap { $0.trimmedNonEmpty() }
    guard !comment.isEmpty else { return name }
    return "\(name) (\(comment.joined(separator: "; ")))"
  }

  /// `macOS 15.5` — major and minor, for the reason the type doc gives.
  ///
  /// `ProcessInfo` rather than AppKit's `NSProcessInfo`-adjacent niceties or a
  /// `sw_vers` shell-out, because the engine is a dependency-free Swift package
  /// and this is the one Foundation API that answers it.
  private static func osDetail() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(version.majorVersion).\(version.minorVersion)"
  }

  /// `dev` for anything that isn't a release build, and nothing at all for a
  /// release — absence is the common case, so spending a token on "release"
  /// would be noise.
  ///
  /// This is the detail that keeps `scripts/dev-build.sh` traffic out of the
  /// service-side latency and error-rate baseline the version token exists to
  /// make readable: a local Debug-Local install otherwise looks exactly like a
  /// user's copy.
  ///
  /// Decided by the build configuration, not by comparing
  /// `Bundle.main.bundleIdentifier` against `HostIdentity.current.subsystem`
  /// the way `BlurtApp.init` picks its identity. That comparison is right for
  /// *Blurt*, whose release bundle id happens to equal its log subsystem, but
  /// `HostIdentity` exists precisely so another host can differ — and one whose
  /// two strings aren't identical would have every shipping request labelled
  /// `dev`. Xcode builds a package target with the app's configuration, so
  /// `Release` is the only thing that clears this, `Debug` and `Debug-Local`
  /// both set it, and `swift test` does too — a test run is not user traffic
  /// either.
  private static func channelDetail() -> String? {
    #if DEBUG
      return "dev"
    #else
      return nil
    #endif
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
