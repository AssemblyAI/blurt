#if UITEST_HOOKS
  import BlurtEngine

  /// Stub composer: the instructions as a marked echo, so a test sees them
  /// reach it and the result pasted.
  nonisolated struct UITestComposer: MessageComposing {
    func compose(_ instructions: String, for _: String?) -> String {
      "Composed (\(instructions))"
    }
  }
#endif
