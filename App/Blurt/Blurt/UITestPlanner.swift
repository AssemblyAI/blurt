#if UITEST_HOOKS
  import BlurtEngine
  import Foundation

  /// Stub planner: a few canned commands, each a fixed plan, so the router's
  /// whole command path runs with no gateway. "Open X" opens X; "type X"
  /// types it; "mute" mutes; anything else is a command Blurt can't do.
  nonisolated struct UITestPlanner: VoiceCommandPlanning {
    func plan(_ command: String, context _: ScreenContext, trace _: PlanTrace) async throws -> [VoiceCommandStep] {
      await MainActor.run { UITestState.shared.recordPlanned(command) }
      // "Slowly": a plan that takes a while, as the gateway's does, so a test
      // can watch the pill while the command is still working.
      if command.localizedCaseInsensitiveContains("slowly") { try await Task.sleep(for: .seconds(3)) }
      let said = command.replacingOccurrences(of: "slowly ", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
      let lowered = said.lowercased()
      if lowered.hasPrefix("open ") {
        return [.openApp(String(said.dropFirst(5)))]
      }
      if lowered.hasPrefix("type ") {
        return [.type(String(said.dropFirst(5)))]
      }
      if lowered == "mute" {
        return [.media(.mute)]
      }
      throw UITestPlanError.notUnderstood
    }
  }
#endif
