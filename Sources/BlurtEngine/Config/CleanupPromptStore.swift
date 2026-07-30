import Foundation

/// Persists the user's custom **cleanup instruction** in `UserDefaults` — the
/// text sent as the dictation request's `llm.instruction` when a *cleaned*
/// dictation runs (`DictationMode.cleaned`). Blank or unset means "use the
/// service's default cleanup instruction", so the request carries an empty `llm`
/// block and the server-owned default rewrite applies. `AssemblyAITranscriber`
/// reads this at each request, so an edit in Settings applies to the very next
/// dictation. Same shape as `SoundPackStore` / `TriggerKeyStore`.
public struct CleanupPromptStore {
  /// UserDefaults key holding the instruction. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtCleanupPrompt"
  /// Defensive upper bound on the persisted instruction, so a runaway paste
  /// into the Settings editor can't store an unbounded blob that then rides
  /// every request. Generous for a cleanup directive; the service enforces its
  /// own request limits regardless.
  static let characterCap = 4096
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The stored instruction. The **getter** trims to non-empty — nil when unset
  /// or blank — so the transcriber can treat "no custom prompt" as one case. The
  /// **setter** removes the key when the value is blank (after trimming) and
  /// otherwise stores the value *raw* (untrimmed), capped at `characterCap`.
  /// Storing raw rather than trimmed matters for the Settings editor's binding:
  /// a normalizing write would bounce a trimmed string back through
  /// `@AppStorage` and eat a trailing space the moment the user typed it — the
  /// same reason `KeyTermsStore` normalizes on read, not write.
  public var instruction: String? {
    get { defaults.string(forKey: Self.defaultsKey).trimmedNonEmpty() }
    nonmutating set {
      guard newValue.trimmedNonEmpty() != nil, let value = newValue else {
        defaults.removeObject(forKey: Self.defaultsKey)
        return
      }
      defaults.set(String(value.prefix(Self.characterCap)), forKey: Self.defaultsKey)
    }
  }
}
