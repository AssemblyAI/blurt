import Foundation

@testable import BlurtEngine

extension DictationSession {
  /// Completes when the session reaches a terminal phase (idle/failed). Lives in
  /// the test target rather than the engine because only tests await terminal
  /// states; the production app drives off `phaseStream()` directly.
  func waitForIdle() async {
    if phase.isTerminal { return }
    for await p in phaseStream() where p.isTerminal { return }
  }
}
