import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// A speaker that records each call and "plays" until stopped or released. A
/// stopped one reports one more meter level as it unwinds — a tick already on
/// its way — before throwing.
final class GatedSpeaker: ReadAloudSpeaker, Sendable {
  struct Call: Sendable {
    let kind: String
    let style: ReadAloudStyle
  }

  private struct State {
    var calls: [Call] = []
    var cancellations = 0
    var released = false
  }

  private let state = Mutex(State())
  private let fails: Bool

  var calls: [Call] { state.withLock(\.calls) }
  var cancellations: Int { state.withLock(\.cancellations) }

  init(fails: Bool = false) { self.fails = fails }

  /// Lets every read playing now, and any later, finish on its own.
  func finishAll() { state.withLock { $0.released = true } }

  func speak(_ text: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?) async throws {
    try await play(Call(kind: "speak: \(text)", style: style), onLevel: onLevel)
  }

  func answer(
    _ request: String, about _: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?
  ) async throws {
    try await play(Call(kind: "answer: \(request)", style: style), onLevel: onLevel)
  }

  private func play(_ call: Call, onLevel: (@Sendable (Float) -> Void)?) async throws {
    state.withLock { $0.calls.append(call) }
    if fails { throw URLError(.badServerResponse) }
    while !state.withLock(\.released) {
      do {
        // wall-clock-ok: a fake that waits until the test releases or cancels it
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        state.withLock { $0.cancellations += 1 }
        onLevel?(0.7)
        throw error
      }
    }
  }
}
