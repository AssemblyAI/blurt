import Foundation
import Testing

@testable import BlurtEngine

/// The read side, against an isolated defaults suite like every other store's.
/// Each case writes the defaults slot directly, which is exactly how production
/// writes it: the store has no setter, and the Settings field's `@AppStorage`
/// binding is the only writer. The combination with the base cleanup
/// instruction is `CleanupInstructionTests`' job; the length cap the field
/// enforces is pinned there too (`customStyleBudgetIsTheHeadroom`).
@Suite("CustomStyleStore")
struct CustomStyleStoreTests {
  /// A store over a throwaway suite holding `stored` (or nothing).
  private func makeStore(_ stored: String?) -> CustomStyleStore {
    let defaults = freshDefaults()
    if let stored { defaults.set(stored, forKey: CustomStyleStore.defaultsKey) }
    return CustomStyleStore(defaults: defaults)
  }

  @Test("unset reads as no instructions")
  func unsetIsNil() {
    #expect(makeStore(nil).instructions == nil)
  }

  /// A cleared or space-padded field must mean "send the base instruction
  /// untouched" — trimming lives here rather than on write (see the store doc).
  @Test("blank stored text reads as no instructions", arguments: ["", "   \n "])
  func blankIsNil(stored: String) {
    #expect(makeStore(stored).instructions == nil)
  }

  @Test("stored instructions read back trimmed")
  func readsBackTrimmed() {
    #expect(makeStore("  always write in lowercase \n").instructions == "always write in lowercase")
  }
}
