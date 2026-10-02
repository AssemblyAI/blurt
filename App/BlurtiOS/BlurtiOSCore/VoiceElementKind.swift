/// The mic control's face — the one part of the keyboard that says what is
/// happening, without a word. Three concepts are built side by side behind
/// this seam so they can be judged on sight from the same states, the same
/// level and the same landing moment; the one that ships stays, the others
/// go. Pick with `-BlurtGalleryVoice a|b|c` (DESIGN.md › The voice element).
package nonisolated enum VoiceElementKind: String, CaseIterable, Sendable {
  /// A: the grille — a dot-matrix mic head that lights as a stepped meter.
  case grille = "a"
  /// B: the ribs — the thin wave asleep as a ribbed grille, awake as the wave.
  case ribs = "b"
  /// C: the streak — a hairline with a bright point that blooms into a light streak.
  case streak = "c"

  package static let shipped = VoiceElementKind.grille

  /// `-BlurtGalleryVoice a|b|c`, or nil when the arguments don't say.
  package static func parse(_ arguments: [String]) -> VoiceElementKind? {
    guard let flag = arguments.firstIndex(of: "-BlurtGalleryVoice"), arguments.count > flag + 1 else { return nil }
    return VoiceElementKind(rawValue: arguments[flag + 1])
  }
}
