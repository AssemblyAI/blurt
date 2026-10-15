import Testing

@testable import BlurtiOSCore

@Suite("First-run setup")
struct SetupProgressTests {
  @Test("no key always means the setup screen; a key plus finishing or every step done means the tabs")
  func routing() {
    #expect(SetupProgress.needsSetup(hasKey: false, isSetUp: false, finished: true))
    #expect(SetupProgress.needsSetup(hasKey: false, isSetUp: true, finished: true))
    #expect(SetupProgress.needsSetup(hasKey: true, isSetUp: false, finished: false))
    #expect(!SetupProgress.needsSetup(hasKey: true, isSetUp: false, finished: true))
    #expect(!SetupProgress.needsSetup(hasKey: true, isSetUp: true, finished: false))
  }
}
