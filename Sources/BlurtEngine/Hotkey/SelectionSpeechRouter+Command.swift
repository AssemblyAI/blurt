import Foundation

#if os(macOS)

  // A command's steps carried out in order, and how a failed job reads on the
  // pill and in the log: the parts of the router's job handling that touch
  // none of its state.
  extension SelectionSpeechRouter {
    /// One command from start to end — the screen read `screen` started, the
    /// plan, each step — as the record the developer-mode log keeps: what the
    /// model saw and answered, how each step ran, and how it ended. Its
    /// outcome is nil only when it ended by being cancelled — a press, or a
    /// newer command — partway: one that failed, or finished, first is logged
    /// as that, however late the cancel came.
    static func execute(
      _ command: String, screen: Task<ScreenContext, Never>?, planner: any VoiceCommandPlanning,
      performer: any VoiceCommandPerforming, session: DictationSession
    ) async -> DictationLog.CommandRecord {
      let began = ContinuousClock.now
      let trace = PlanTrace()
      let ran = StepLog()
      var context = ScreenContext(appName: nil)
      var steps: [VoiceCommandStep] = []
      var failure: (kind: String, text: String)?
      var outcome: OverlayUIState?
      do {
        context = await screen?.value ?? ScreenContext(appName: nil)
        steps = try await planner.plan(command, context: context, trace: trace)
        // The step kinds and counts in public; the command, the app and
        // what each step names (an app, a menu path, a link) private.
        logger.info(
          "command with \(context.elements.count) elements planned \(steps.map(\.action.rawValue).joined(separator: ", "), privacy: .public): \(command, privacy: .private) in \(context.appName ?? "no app", privacy: .private) as \(String(describing: steps), privacy: .private)"
        )
        outcome = try await perform(steps, in: context, performer: performer, session: session, recording: ran)
      } catch  where !(isCancellation(error) && Task.isCancelled) {
        // A cancellation-shaped error on a task nobody cancelled (a request
        // the system dropped) is a failure like any other, and says so.
        // The kind in public, the words private: a command's errors carry
        // what the plan named — a refused link's whole URL, an app, a label.
        logger.error(
          "command failed (\(logName(of: error), privacy: .public)): \(error.localizedDescription, privacy: .private)"
        )
        failure = (logName(of: error), error.localizedDescription)
        outcome = Self.failure(error)
      } catch {
        // A cancelled request answers `URLError.cancelled`, not
        // `CancellationError`: a command a press abandoned, not a failure.
      }
      return DictationLog.CommandRecord(
        command: command, context: context, steps: steps, outcome: outcome,
        failure: failure, duration: ContinuousClock.now - began, ran: ran.records, trace: trace.snapshot)
    }

    /// The steps in order, checking for a press's cancel before each, each
    /// recorded into `ran` as it goes — how it was carried out, how long it
    /// took, the error that stopped it — for the developer-mode log. A typed
    /// step that only reached the clipboard ends the command there, as Copied:
    /// the steps after it assumed the words were in the field.
    static func perform(
      _ steps: [VoiceCommandStep], in context: ScreenContext, performer: any VoiceCommandPerforming,
      session: DictationSession, recording ran: StepLog
    ) async throws -> OverlayUIState {
      for (index, step) in steps.enumerated() {
        try Task.checkCancellation()
        // A beat between steps, so the app has handled one before the next
        // lands — none after the last, which would only hold back "Done".
        if index > 0 { try await Task.sleep(for: performer.settle) }
        let line = step.logLine(in: context)
        let started = ContinuousClock.now
        do {
          guard case .type(let text) = step else {
            ran.add(line, how: try await performer.perform(step), since: started)
            continue
          }
          let pasted = try await session.typeText(text)
          guard case .pasted = pasted else {
            ran.add(line, how: "copied: nothing editable focused", since: started)
            return pasted.overlayState
          }
          ran.add(line, how: "pasted", since: started)
        } catch {
          if !isCancellation(error) { ran.add(line, error: error.localizedDescription, since: started) }
          throw error
        }
      }
      return .done
    }

    /// The steps a command ran, in order, as it runs them.
    @MainActor
    final class StepLog {
      private(set) var records: [StepRecord] = []

      func add(_ step: String, how: String? = nil, error: String? = nil, since started: ContinuousClock.Instant) {
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        records.append(StepRecord(step: step, how: how, milliseconds: milliseconds, error: error))
      }
    }

    /// An error's name for the public log, never its payload: each error type's
    /// own exhaustive name (`VoiceCommandError.unsafeURL`, not the URL it
    /// holds), else just the type.
    nonisolated static func logName(of error: any Error) -> String {
      if let error = error as? VoiceCommandError { return "VoiceCommandError.\(error.logName)" }
      if let error = error as? BlurtError { return "BlurtError.\(error.diagnosticName)" }
      // A network failure's code says which one — a timeout (-1001), no
      // connection (-1009) — and carries nothing of the request.
      if let error = error as? URLError { return "URLError(\(error.code.rawValue))" }
      return String(describing: type(of: error))
    }

    /// Whether `error` is a cancellation: Swift's own, or a request the
    /// cancel reached first, which `URLSession` answers with `URLError.cancelled`.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
      error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// What the pill shows for a failed rewrite or command. A `BlurtError` (a
    /// missing key) reads as a dictation's would; a command's own errors name
    /// the app on the pill where that's the diagnosis; the rest (the rewriter's,
    /// the gateway's) say what went wrong behind the hover.
    static func failure(_ error: any Error) -> OverlayUIState {
      if let error = error as? BlurtError { return PipelinePhase.failed(error).overlayState }
      if let error = error as? VoiceCommandError {
        return .error(message: error.errorDescription ?? "The command failed.", notice: error.pillNotice)
      }
      return .error(message: error.localizedDescription)
    }
  }
#endif
