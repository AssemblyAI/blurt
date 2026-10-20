import BlurtEngine
import Foundation

/// Ready-made output styles (Professional, Casual, Ultracasual): a starting
/// point a user adds in one tap and can then edit like any style of their own. Each
/// becomes an ordinary `StyleProfile` (its instructions ride the cleanup
/// rewrite on top of the base instruction), so nothing downstream knows it
/// began as a preset.
///
/// The wording is a starting point, not eval-scored like the base instruction;
/// run it through `evals/dictation-prompt` before treating it as tuned.
package nonisolated enum StylePreset: String, CaseIterable, Identifiable, Sendable {
  case professional = "Professional"
  case casual = "Casual"
  case ultracasual = "Ultracasual"

  package var id: String { rawValue }
  package var name: String { rawValue }

  package var symbol: String {
    switch self {
    case .professional: "briefcase"
    case .casual: "cup.and.saucer"
    case .ultracasual: "face.smiling"
    }
  }

  package var instructions: String {
    switch self {
    case .professional:
      "Use a clear, polished, professional tone suitable for work email. Write complete sentences "
        + "with standard capitalization and punctuation. No slang and no emojis."
    case .casual:
      "Use a relaxed, friendly tone, like a message to a coworker you get along with. Contractions "
        + "are fine. Keep standard capitalization and punctuation. No emojis."
    case .ultracasual:
      "Write like a quick text to a close friend: all lowercase, light punctuation, and no period "
        + "at the end. Keep it short and natural. An emoji is fine when it fits."
    }
  }

  /// The user's style this preset already became, if any: matched by name,
  /// whatever its instructions have been edited to since.
  package func added(in profiles: [StyleProfile]) -> StyleProfile? {
    profiles.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
  }

  /// `profiles` with this preset added at the end, and the style it became;
  /// the existing one when it was already added. Nil when the list is full.
  package func adding(to profiles: [StyleProfile]) -> (profiles: [StyleProfile], style: StyleProfile)? {
    if let existing = added(in: profiles) { return (profiles, existing) }
    guard profiles.count < StyleProfileStore.profileLimit else { return nil }
    let style = StyleProfile(name: name, instructions: instructions)
    return (profiles + [style], style)
  }
}
