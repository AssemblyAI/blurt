#if UITEST_HOOKS
  import BlurtEngine
  import Foundation

  // The rewrite and command keys' stand-ins under UI testing, beside the
  // pipeline doubles in UITestSupport.swift: no gateway, nothing acted on.

  /// Stub rewriter: the rewrite a spoken instruction asks for, as a marked
  /// echo, so a test sees the instruction reach it and the result pasted.
  nonisolated struct UITestRewriter: SelectionRewriting {
    func rewrite(_ selection: String, as request: String) async throws -> String {
      "Rewritten (\(request)): \(selection)"
    }
  }

  /// Stub planner: a few canned commands, each a fixed plan, so the router's
  /// whole command path runs with no gateway. "Open X" opens X; "type X"
  /// types it; "mute" mutes; anything else is a command Blurt can't do.
  nonisolated struct UITestPlanner: VoiceCommandPlanning {
    func plan(_ command: String, context: ScreenContext, trace: PlanTrace) async throws -> [VoiceCommandStep] {
      await MainActor.run { UITestState.shared.recordPlanned(command) }
      // "Slowly": a plan that takes a while, as the gateway's does, so a test
      // can watch the pill while the command is still working.
      if command.localizedCaseInsensitiveContains("slowly") { try await Task.sleep(for: .seconds(3)) }
      let said = command.replacingOccurrences(of: "slowly ", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
      let lowered = said.lowercased()
      if lowered.hasPrefix("open ") { return [.openApp(String(said.dropFirst(5)))] }
      if lowered.hasPrefix("type ") { return [.type(String(said.dropFirst(5)))] }
      if lowered == "mute" { return [.media(.mute)] }
      throw UITestPlanError.notUnderstood
    }
  }

  /// What the stub planner throws for a command it has no plan for.
  nonisolated enum UITestPlanError: Error, LocalizedError {
    case notUnderstood
    var errorDescription: String? { "Blurt can’t do that command." }
  }

  /// Stub performer: records each step it's handed instead of carrying it out
  /// (no Accessibility, no app opened), over a fixed small screen.
  nonisolated struct UITestPerformer: VoiceCommandPerforming {
    func screenContext() async -> ScreenContext {
      ScreenContext(
        appName: "Notes", windowTitle: "Shopping", elements: [.init(id: 1, kind: "button", label: "New Note")])
    }

    func perform(_ step: VoiceCommandStep) async throws -> String? {
      await MainActor.run { UITestState.shared.recordPerformed(String(describing: step)) }
      return "stubbed"
    }
  }
#endif
