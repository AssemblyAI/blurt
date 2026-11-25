import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A speaker that reports `levels` meter readings, as audio playing does, then
/// finishes.
struct LevelSpeaker: ReadAloudSpeaker {
  let levels: Int

  func speak(_: String, style _: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?) {
    for _ in 0..<levels { onLevel?(0.5) }
  }

  func answer(
    _: String, about _: String, style _: ReadAloudStyle, onLevel _: (@Sendable (Float) -> Void)?
  ) {
    // Answers play nothing in the suites that use this speaker.
  }
}
