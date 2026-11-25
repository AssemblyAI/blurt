import Foundation

/// Telling a complaint about the last command ("that didn't work") from a
/// command: said to the Control Your Mac key, it's feedback to log against
/// the command before it, not something to plan.
enum CommandFeedback {
  /// What a complaint says, as whole words of the folded utterance.
  static let complaints = [
    "didn't work", "did not work", "doesn't work", "does not work", "not working", "that's wrong", "that was wrong",
    "that is wrong", "wrong thing", "not what i", "that failed", "it failed", "broken", "you got it wrong",
    "nothing works", "nothing happened", "didn't do anything", "did nothing",
  ]

  /// Whether `utterance` is a complaint about the last command: short, and
  /// saying one of `complaints`. A long sentence with "wrong" in it is a
  /// command ("type: the wrong answer is 4"), which is why there's a length cap.
  static func isComplaint(_ utterance: String) -> Bool {
    let straightened = NameMatch.normalized(utterance).replacingOccurrences(of: "’", with: "'")
    let words = straightened.split { !$0.isLetter && $0 != "'" }.joined(separator: " ")
    guard words.split(separator: " ").count <= 10 else {
      return false
    }
    return complaints.contains { " \(words) ".contains(" \($0) ") }
  }
}
