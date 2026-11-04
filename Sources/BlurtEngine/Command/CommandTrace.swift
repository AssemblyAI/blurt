import Foundation
import Synchronization

/// What one planning call saw and said, for the developer-mode command log:
/// the user turn exactly as sent (the element list, fenced), every reply as
/// it came back (two when the plan was asked for again), the model, and a
/// short version of the instruction and schema, so a behaviour can be tied to
/// the prompt that produced it. Filled by the planner as it goes — it can
/// throw part way, and what it saw is most of the diagnosis then.
public final class PlanTrace: Sendable {
  public struct Snapshot: Sendable, Equatable {
    public var prompt: String?
    public var replies: [String] = []
    public var model: String?
    public var promptVersion: String?

    public init(prompt: String? = nil, replies: [String] = [], model: String? = nil, promptVersion: String? = nil) {
      self.prompt = prompt
      self.replies = replies
      self.model = model
      self.promptVersion = promptVersion
    }
  }

  private let state = Mutex(Snapshot())

  public init() {}

  public var snapshot: Snapshot { state.withLock { $0 } }

  func record(prompt: String, model: String, promptVersion: String) {
    state.withLock {
      $0.prompt = prompt
      $0.model = model
      $0.promptVersion = promptVersion
    }
  }

  func record(reply: String) { state.withLock { $0.replies.append(reply) } }
}

/// How one step of a command ran, for the command log: the step as planned,
/// how the performer carried it out ("AXPress, then click"), how long it took,
/// and the error it ended the command with, if any.
public struct StepRecord: Sendable, Equatable, Encodable {
  public let step: String
  public let how: String?
  public let milliseconds: Int
  public let error: String?
}

/// A short, stable fingerprint of a text — the planner's instruction and
/// schema — for the log: 64-bit FNV-1a, in hex. Not security, just "which
/// prompt was this".
enum PromptVersion {
  static func of(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}

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
    let words = NameMatch.normalized(utterance).replacingOccurrences(of: "’", with: "'")
      .split { !$0.isLetter && $0 != "'" }.joined(separator: " ")
    guard words.split(separator: " ").count <= 10 else { return false }
    return complaints.contains { " \(words) ".contains(" \($0) ") }
  }
}
