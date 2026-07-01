import DatadogCore
import DatadogCrashReporting
import DatadogLogs
import Foundation

/// Datadog crash + error monitoring. Replaces the former Sentry integration.
///
/// Started from `AppDelegate` at launch; `start()` no-ops in Debug via the
/// `isReleaseBuild` runtime guard (local dev runs the Debug config, and we don't
/// want developer crashes/usage polluting production data). Blurt never
/// sends dictation text or transcripts. The only identifier attached is a random,
/// locally-generated install id (`@usr.id`) used to count unique installs — it
/// carries no personal information and isn't tied to the user's identity. The
/// diagnostics this ships are disclosed in README.md and SECURITY.md.
///
/// - `CrashReporting` captures crashes — the Sentry crash-reporting equivalent.
/// - A `Logs` logger records handled faults via ``reportError(_:attributes:)`` —
///   the Sentry `capture(error:)` equivalent. Both crashes and error logs feed
///   Datadog Error Tracking.
/// - `start()` also emits one "app launched" log per run so adoption / unique-
///   install counts have baseline volume (not just installs that hit an error).
///
/// Datadog RUM is intentionally not used: it links UIKit and does not build for
/// native (AppKit) macOS, only Mac Catalyst. Logs + Crash Reporting are the
/// supported best-practice stack for a native macOS app.
///
/// `@MainActor` so the one-time `start()` and the `logger` it sets are isolated
/// (both callers — `AppDelegate` launch and `AppCoordinator` — are main-actor).
@MainActor
enum Monitoring {
  // Public identifiers — safe to ship in the binary, like the old Sentry DSN.
  // The client token is from Datadog (US1, datadoghq.com).
  private static let clientToken = "pub13781bb00c1c14ae35f16d2b98550454"
  private static let service = "blurt"
  private static let environment = "production"

  // UserDefaults key holding the anonymous, per-install id set as `@usr.id`.
  private static let installIDKey = "dev.alex.blurt.anonymous-install-id"

  // Release-only gate. A runtime flag (not `#if` at the call site) so `start()`
  // and its config stay reachable for the dead-code scan while execution is still
  // limited to Release builds — dev crashes/usage must never hit production.
  private static var isReleaseBuild: Bool {
    #if DEBUG
      false
    #else
      true
    #endif
  }

  /// Set by `start()`. `reportError` is a no-op until then, so it self-disables
  /// in Debug (where the SDK is never started), just like the old Sentry calls.
  private static var logger: (any LoggerProtocol)?

  /// Initializes the SDK, enables crash reporting + logging, tags telemetry with
  /// the anonymous install id, and logs one launch event. Call once, at launch.
  static func start() {
    guard isReleaseBuild else { return }
    Datadog.initialize(
      with: Datadog.Configuration(
        clientToken: clientToken,
        env: environment,
        site: .us1,
        service: service
      ),
      trackingConsent: .granted
    )
    // Anonymous install id only — no name/email/PII — so unique-install and
    // version-adoption counts work without identifying anyone.
    Datadog.setUserInfo(id: installID)
    CrashReporting.enable()
    Logs.enable()
    let logger = Logger.create(
      with: Logger.Configuration(name: service, networkInfoEnabled: true)
    )
    Self.logger = logger
    // Baseline telemetry: one launch event per run, so adoption / unique-install
    // metrics see every install, not only the ones that hit an error.
    logger.info("app launched")
  }

  /// Reports a handled fault (the app didn't crash) as an error log, with optional
  /// context attributes. A no-op when the SDK was never started (Debug).
  static func reportError(_ error: Error, attributes: [String: any Encodable] = [:]) {
    logger?.error("dictation pipeline fault", error: error, attributes: attributes)
  }

  /// A random UUID minted once per install and persisted, used as the anonymous
  /// `@usr.id`. Not tied to the user's identity; regenerates on a fresh install.
  private static var installID: String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: installIDKey) { return existing }
    let generated = UUID().uuidString
    defaults.set(generated, forKey: installIDKey)
    return generated
  }
}
