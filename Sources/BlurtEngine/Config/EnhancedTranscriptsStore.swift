import Foundation

/// Persists the "enhanced transcripts" switch in `UserDefaults`. On by
/// default; the Settings window's Transcription section flips it. While on,
/// every dictation request carries the `llm` block asking the dictation API
/// for its server-side cleanup rewrite (remove disfluencies, fix punctuation);
/// turned off, the request omits the block and the verbatim transcript is
/// pasted exactly as spoken. `AssemblyAITranscriber` reads this at each
/// request, so a change applies to the very next dictation.
/// Same shape as `DeveloperModeStore` / `SoundPackStore`.
public struct EnhancedTranscriptsStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtEnhancedTranscripts"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Unset means **on** — the cleanup rewrite is the product's default
  /// behavior, so only an explicit opt-out disables it. That inverts the
  /// usual `bool(forKey:)` shape (which reads a missing key as false), hence
  /// the presence check.
  var isEnabled: Bool {
    get { defaults.object(forKey: Self.defaultsKey) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
  }
}
