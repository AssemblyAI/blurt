#if UITEST_HOOKS
  import BlurtEngine

  // The rewrite, compose and command keys' stand-ins under UI testing
  // (`UITestRewriter`, `UITestComposer`, `UITestPlanner`, `UITestPerformer`),
  // beside the pipeline doubles (see `UITestMode`): no gateway, nothing acted on.

  /// Stub rewriter: the rewrite a spoken instruction asks for, as a marked
  /// echo, so a test sees the instruction reach it and the result pasted.
  nonisolated struct UITestRewriter: SelectionRewriting {
    func rewrite(_ selection: String, as request: String) -> String {
      "Rewritten (\(request)): \(selection)"
    }
  }
#endif
