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

  /// The value an unset key reads as. Public so the Settings toggle's `@AppStorage`
  /// default comes from here instead of restating `true` — the view and the
  /// transcriber have to agree about the empty slot, and when both spelled it out
  /// the view's answer drove the UI while this one drove the request.
  public static let defaultValue = true

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Unset means **on** — the cleanup rewrite is the product's default
  /// behavior, so only an explicit opt-out disables it. That inverts the
  /// usual `bool(forKey:)` shape (which reads a missing key as false), hence
  /// the presence check.
  ///
  /// Read-only for the same reason as `DeveloperModeStore.isEnabled`: the Settings
  /// toggle writes the slot through `@AppStorage`, so a setter here had no
  /// production caller. Seed the slot to change the switch.
  var isEnabled: Bool {
    defaults.object(forKey: Self.defaultsKey) as? Bool ?? Self.defaultValue
  }
}
