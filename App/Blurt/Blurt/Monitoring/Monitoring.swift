import DatadogCore
import DatadogCrashReporting
import DatadogLogs
import Foundation

/// Datadog crash + error monitoring. Replaces the former Sentry integration.
///
/// Started Release-only from `AppDelegate` (local dev runs the Debug config, and
/// we don't want developer crashes/usage polluting production data). Blurt never
/// sends dictation text or transcripts, and no PII is attached — the diagnostics
/// this ships are disclosed in README.md and SECURITY.md.
///
/// - `CrashReporting` captures crashes — the Sentry crash-reporting equivalent.
/// - A `Logs` logger records handled faults via ``reportError(_:attributes:)`` —
///   the Sentry `capture(error:)` equivalent. Both crashes and error logs feed
///   Datadog Error Tracking.
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

  /// Set by `start()`. `reportError` is a no-op until then, so it self-disables
  /// in Debug (where the SDK is never started), just like the old Sentry calls.
  private static var logger: (any LoggerProtocol)?

  /// Initializes the SDK and enables crash reporting + logging. Call once, at launch.
  static func start() {
    Datadog.initialize(
      with: Datadog.Configuration(
        clientToken: clientToken,
        env: environment,
        site: .us1,
        service: service
      ),
      trackingConsent: .granted
    )
    CrashReporting.enable()
    Logs.enable()
    logger = Logger.create(
      with: Logger.Configuration(name: service, networkInfoEnabled: true)
    )
  }

  /// Reports a handled fault (the app didn't crash) as an error log, with optional
  /// context attributes. A no-op when the SDK was never started (Debug).
  static func reportError(_ error: Error, attributes: [String: any Encodable] = [:]) {
    logger?.error("dictation pipeline fault", error: error, attributes: attributes)
  }
}
