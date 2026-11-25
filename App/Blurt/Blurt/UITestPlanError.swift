#if UITEST_HOOKS
  import Foundation

  /// What the stub planner throws for a command it has no plan for.
  nonisolated enum UITestPlanError: Error, LocalizedError {
    case notUnderstood

    var errorDescription: String? { "Blurt can’t do that command." }
  }
#endif
