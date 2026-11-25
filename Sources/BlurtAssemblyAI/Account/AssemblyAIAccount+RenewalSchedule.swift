public import Foundation

// The bounds `runRenewal` and `keyWasRejected` schedule renewals within.
extension AssemblyAIAccount {
  /// The longest `runRenewal` sleeps between checks. A renewal is normally
  /// due days away, and the loop sleeps until then; the cap bounds how long a
  /// sign-in made while it sleeps waits for its schedule, and how far a
  /// changed system clock can throw it.
  public static let longestRenewalSleep: TimeInterval = 24 * 60 * 60
  /// The shortest: a renewal that keeps failing (offline) retries no faster.
  public static let shortestRenewalSleep: TimeInterval = 60
  /// How soon `runRenewal` looks again at a session item it couldn't read (a
  /// locked Keychain): soon enough that a key due in the meantime still
  /// renews, and the status catches up once the Keychain unlocks.
  public static let unreadableSessionRecheck: TimeInterval = 5 * 60
  /// A rejected key renews at once, but no more often than this, so repeated
  /// dictation failures can't hammer the token endpoint.
  public static let rejectedKeyRenewalSpacing: TimeInterval = 15 * 60
}
