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
    /// One gate per read still playing: `finishAll()` opens them all, and a
    /// read's own cancellation opens only its own.
    var playing: [AsyncGate] = []
  }

  private let state = Mutex(State())
  private let fails: Bool

  var calls: [Call] { state.withLock(\.calls) }
  var cancellations: Int { state.withLock(\.cancellations) }

  init(fails: Bool = false) { self.fails = fails }

  /// Lets every read playing now, and any later, finish on its own.
  func finishAll() {
    let playing = state.withLock { state -> [AsyncGate] in
      state.released = true
      defer { state.playing.removeAll() }
      return state.playing
    }
    for gate in playing { gate.open() }
  }

  func speak(_ text: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?) async throws {
    try await play(Call(kind: "speak: \(text)", style: style), onLevel: onLevel)
  }

  func answer(
    _ request: String, about _: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?
  ) async throws {
    try await play(Call(kind: "answer: \(request)", style: style), onLevel: onLevel)
  }

  /// Parks on the read's own gate rather than polling: `AsyncGate.wait()`
  /// doesn't answer cancellation itself, so the cancellation handler opens the
  /// gate, and a read woken while it isn't released was stopped.
  private func play(_ call: Call, onLevel: (@Sendable (Float) -> Void)?) async throws {
    state.withLock { $0.calls.append(call) }
    if fails {
      throw URLError(.badServerResponse)
    }
    let gate = AsyncGate()
    let released = state.withLock { state -> Bool in
      if !state.released { state.playing.append(gate) }
      return state.released
    }
    if released {
      return
    }
    await withTaskCancellationHandler {
      await gate.wait()
    } onCancel: {
      gate.open()
    }
    let stopped = state.withLock { state -> Bool in
      guard !state.released else {
        return false
      }
      state.playing.removeAll { $0 === gate }
      state.cancellations += 1
      return true
    }
    if stopped {
      onLevel?(0.7)
      throw CancellationError()
    }
  }
}
