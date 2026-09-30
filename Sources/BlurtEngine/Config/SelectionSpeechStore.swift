import Foundation

/// Persists the experimental "read selection aloud" switch in `UserDefaults`.
/// Off by default; the Settings window's Advanced pane flips it. While on, a
/// trigger press over selected text reads that text aloud through AssemblyAI's
/// streaming TTS (`SelectionSpeaker`) instead of starting a dictation — a press
/// with nothing selected still dictates as usual.
///
/// Opt-in, for the reason `AssemblyAISpeechSynthesizer` gives. Same shape as
/// `DeveloperModeStore`.
public struct SelectionSpeechStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.selectionSpeech.key }
  private let defaults: UserDefaults

  public init() {
    self.init(defaults: .standard)
  }

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  /// Read-only for the same reason as `DeveloperModeStore.isEnabled`: the
  /// Settings toggle writes the slot through `@AppStorage`.
  public var isEnabled: Bool {
    defaults.bool(forKey: Self.defaultsKey)
  }
}
