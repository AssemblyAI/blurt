#if os(macOS)
  import Testing

  @testable import BlurtEngine

  @Suite("noTarget phase + overlay mapping")
  struct NoTargetPhaseTests {
    @Test("noTarget is terminal")
    func terminal() {
      #expect(PipelinePhase.noTarget.isTerminal)
    }

    @Test("noTarget maps to the quiet overlay state, not an error")
    func overlayMapping() {
      #expect(PipelinePhase.noTarget.overlayState == .noTarget)
    }
  }
#endif
