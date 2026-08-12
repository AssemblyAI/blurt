import Foundation
import Testing

@testable import BlurtEngine

/// Retain-cycle detection. LeakSanitizer is unsupported on Darwin, so we catch
/// leaks the deterministic way: weakly track an instance, drop the strong
/// reference, and assert it deallocated. A surviving instance means something
/// (usually a self-capturing `Task` or closure) formed a cycle.
@Suite("Memory leaks")
struct MemoryLeakTests {

  /// Builds and fully exercises an instance via `build`, then fails if it is
  /// still alive after `build`'s strong reference is released. Polls briefly so
  /// an in-flight task that's winding down isn't mistaken for a leak.
  private func expectNoLeak<T: AnyObject>(_ name: String, _ build: () async -> T) async {
    weak var weakRef: T?
    do {
      let instance = await build()
      weakRef = instance
    }
    for _ in 0..<200 where weakRef != nil {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(weakRef == nil, "\(name) was not deallocated — likely a retain cycle")
  }

  @Test("DictationSession deallocates after a full press → release → inject cycle")
  func dictationSessionNoLeak() async {
    await expectNoLeak("DictationSession") {
      // The same composition the session suites exercise (`makeSession`), so the
      // graph checked for cycles here can't drift from the one they cover. The
      // fixture's own stub references die with this expression; the session holds
      // whatever it actually retains.
      let session = makeSession(mode: .transcript("Hello.")).session
      await session.press()
      await session.release()
      await session.waitForIdle()
      return session
    }
  }

  @Test("KeyInjector deallocates")
  func keyInjectorNoLeak() async {
    await expectNoLeak("KeyInjector") {
      KeyInjector()
    }
  }
}
