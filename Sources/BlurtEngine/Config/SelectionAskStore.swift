import Foundation

/// Persists read-aloud's "hold to ask" switch in `UserDefaults`. While it and
/// read-aloud (`SelectionSpeechStore`) are both on, holding the trigger over
/// selected text records a spoken request instead of reading the text, and the
/// answer is read aloud (`SelectionSpeechRouting`, `SelectionSpeaker.answer`).
/// A tap over a selection still reads it.
///
/// **Off by default**, like skip-jargon (`ReadAloudStyleStore`) and for the same
/// reason: asking sends the selection and the spoken request to the LLM
/// Gateway, a second service, so it is its own opt-in rather than riding
/// read-aloud's. The Settings window's Advanced pane writes the slot through
/// `@AppStorage`, so like `EnhancedTranscriptsStore` this store is read-only.
public struct SelectionAskStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.selectionAsk.key }

  /// The value an unset key reads as. Public so the Settings toggle's
  /// `@AppStorage` default comes from here and can't disagree with the router.
  public static let defaultValue = false

  private let defaults: UserDefaults

  public init() {
    self.init(defaults: .standard)
  }

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  /// Unset reads as `defaultValue`.
  public var isEnabled: Bool {
    defaults.object(forKey: Self.defaultsKey) as? Bool ?? Self.defaultValue
  }
}
