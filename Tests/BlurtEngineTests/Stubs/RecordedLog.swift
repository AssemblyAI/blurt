import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// Stands in for `DictationLog` behind the session's log seams, recording what
/// would have been written. Reachable from the `@Sendable` seam closures, hence a
/// `Mutex`-guarded class rather than an actor.
final class RecordedLog: Sendable {
  struct Transcript: Sendable, Equatable {
    let text: String
    let context: TranscriptionContext?
    /// The phase the dictation ended in, which the log names.
    let outcome: PipelinePhase
  }

  struct Failure: Sendable {
    let error: BlurtError
    let context: TranscriptionContext?
  }

  private struct State {
    var transcripts: [Transcript] = []
    var failures: [Failure] = []
  }

  private let state = Mutex(State())

  var transcripts: [Transcript] { state.withLock { $0.transcripts } }
  var failures: [Failure] { state.withLock { $0.failures } }
  /// The stable case labels of the recorded failures — what `errors.jsonl` would
  /// aggregate on, and the readable form for an assertion.
  var failureNames: [String] { failures.map(\.error.diagnosticName) }

  func recordTranscript(_ text: String, context: TranscriptionContext?, outcome: PipelinePhase) {
    state.withLock { $0.transcripts.append(Transcript(text: text, context: context, outcome: outcome)) }
  }

  func recordFailure(_ error: BlurtError, context: TranscriptionContext?) {
    state.withLock { $0.failures.append(Failure(error: error, context: context)) }
  }
}
