import Foundation

#if os(macOS)

  /// Sits between the trigger keys and the dictation session. A press of a key
  /// set to read aloud reads the selected text; a press of a key set to ask
  /// records a spoken request about it and reads the answer; a press of a key
  /// set to rewrite records a spoken instruction and pastes the selection,
  /// rewritten that way, over it; a press of a key set to compose records
  /// spoken instructions and pastes what they describe at the cursor; a press
  /// of a key set to command records a
  /// spoken command and carries it out; a dictating key's
  /// commands go straight to `DictationSession.submit` (see `TriggerKeyBindings`
  /// for which key does what).
  ///
  /// The decisions are the engine's `SelectionSpeechRouting`. This class carries
  /// out the actions it returns: the selection read, the hold timer, the speech
  /// task, and the gate resets. Only read, ask and rewrite presses read the selection, so
  /// dictation never waits on an Accessibility round trip.
  ///
  /// Main-actor because its callers are: the key tap's callbacks, the session's
  /// phase observer and Settings all run on the main thread, and isolation lets
  /// the compiler prove single-threaded access to the routing state.
  @MainActor
  public final class SelectionSpeechRouter {
    static let logger = HostIdentity.current.logger("SelectionSpeech")

    private let session: DictationSession
    private let speaker: any ReadAloudSpeaker
    private let rewriter: any SelectionRewriting
    private let composer: any MessageComposing
    private let planner: any VoiceCommandPlanning
    private let performer: any VoiceCommandPerforming
    private let readSelection: @Sendable () async -> String?
    private let defaults: UserDefaults
    /// What the hold timer and the answer's start-cue gap sleep on; a test's
    /// `TestClock` steps them instead of waiting them out.
    private let clock: any Clock<Duration>
    private var routing = SelectionSpeechRouting()
    private var speech: Task<Void, Never>?
    /// The job in flight — a rewrite or a composition until it pastes, a
    /// command until its last step. Cancelled by any press.
    private var job: Task<Void, Never>?
    /// The screen read a command's release started (`.readScreen`), running
    /// while the command transcribes; `.runCommand` plans with its result.
    private var screenRead: Task<ScreenContext, Never>?
    /// The last command logged, for a complaint about it ("that didn't work")
    /// to name (`DictationLog.appendFeedback`).
    private var lastCommand: DictationLog.CommandRecord?
    /// The pending `holdElapsed`, restarted by each press that may ask or rewrite.
    private var holdTimer: Task<Void, Never>?
    /// A voice sample playing from Settings. Apart from `speech`, so it never
    /// touches the routing state a key press owns.
    private var preview: Task<Void, Never>?
    /// The key tap's `syncAfterTerminalPhase`: a dictation ended without a key event.
    public var syncGateAfterSession: () -> Void = {}
    /// The key tap's `resetGate`: a read ended without a key event.
    public var resetGate: () -> Void = {}
    /// A read or answer began (the pill appears, the start cue plays) and ended
    /// (the pill goes, the stop cue plays): once each per read, whether it ran
    /// out, was stopped, or failed.
    public var speechStarted: () -> Void = {}
    public var speechEnded: () -> Void = {}
    /// The loudness of the voice playing, ~20 times a second: the pill's meter.
    public var speechLevel: (Float) -> Void = { _ in }
    /// A read, answer or voice sample failed (it's already logged): the app
    /// beeps, since the pill just goes away.
    public var speechFailed: (any Error) -> Void = { _ in }
    /// What the pill shows for a job: `.rewriting`, `.composing` or `.commanding` as it
    /// starts, then its outcome — Pasted (Done, for a command), Copied, or the
    /// error — or nil when a press abandoned it, and the pill goes back to
    /// what the session is doing.
    public var jobPill: (OverlayUIState?) -> Void = { _ in }
    /// Called after every routing step that leaves the router at rest — a
    /// level, not an edge: every dictation key event and every session phase at
    /// rest calls it too, as does the step that ends an answer or a job. The
    /// music pause resumes here, once the mic has closed.
    public var pressSettled: () -> Void = {}
    /// Counts reads, so a stopped read's late end can't take down a newer read's pill.
    private var speechGeneration = 0
    /// The read the pill is showing, or nil once it ended: a level still on its
    /// way from a read that's over must not land on the pill.
    private var activeGeneration: Int?

    /// `clips`, when given, keeps every read's audio and reports each one —
    /// the host's history of what was read aloud.
    public convenience init(session: DictationSession, clips: ReadClipSink? = nil) {
      self.init(
        session: session, speaker: SelectionSpeaker(clips: clips), readSelection: SelectionSpeaker.focusedSelection)
    }

    /// The seams: what speaks, what rewrites, what composes, what plans and carries out a
    /// command, how the selection is read, where the
    /// settings each press reads come from, and the clock its timers run on.
    /// Public so a host can run the whole read-aloud path offline (Blurt's UI
    /// tests do).
    public init(
      session: DictationSession, speaker: any ReadAloudSpeaker,
      rewriter: any SelectionRewriting = SelectionRewriter(),
      composer: any MessageComposing = MessageComposer(),
      planner: any VoiceCommandPlanning = VoiceCommandPlanner(),
      performer: any VoiceCommandPerforming = SystemVoiceCommandPerformer(),
      readSelection: @escaping @Sendable () async -> String?, defaults: UserDefaults = .standard,
      clock: any Clock<Duration> = ContinuousClock()
    ) {
      self.session = session
      self.speaker = speaker
      self.rewriter = rewriter
      self.composer = composer
      self.planner = planner
      self.performer = performer
      self.readSelection = readSelection
      self.defaults = defaults
      self.clock = clock
    }

    /// A trigger key went down. What it does and whether it can be held are read
    /// per press, so a change in the Keys tab applies to the next one.
    public func press(key: TriggerKey) {
      let bindings = TriggerKeyBindings(defaults: defaults)
      let action = bindings.action(for: key)
      let holds = bindings.activation != .tap
      perform(routing.press(key: key, action: action, holds: holds))
    }

    /// Speaks a short sample in the chosen voice at the chosen speed, as picking
    /// a cue sound plays it. A newer pick cuts off the one still playing.
    public func previewSample() {
      let style = ReadAloudStyleStore(defaults: defaults).style
      let name = ReadAloudVoice.voice(id: style.voiceID)?.name ?? "your voice"
      let sample = style.verbatim
      preview?.cancel()
      preview = Task { [weak self, speaker] in
        do {
          let line = "Hi, I'm \(name). This is how Blurt reads your selection."
          try await speaker.speak(line, style: sample, onLevel: nil)
        } catch is CancellationError {
        } catch {
          Self.logger.error("voice preview failed: \(error.localizedDescription, privacy: .public)")
          self?.speechFailed(error)
        }
      }
    }

    /// The gate's other commands: `.release`, `.cancel`, `.cancelRecording`.
    public func submit(_ command: DictationSession.Command) {
      perform(routing.submit(command))
    }

    /// A bare Escape with something in flight: stop it all (`SelectionSpeechRouting.escape`).
    public func escape() { perform(routing.escape()) }
    /// Whether a dictation, press, request, read, answer or job is under way.
    public var isBusy: Bool { routing.isBusy }

    /// `DictationKeyTap`'s latch: the press was a tap.
    public func keyLatched() {
      perform(routing.keyLatched())
    }

    public func sessionPhaseChanged(_ phase: PipelinePhase) {
      perform(routing.sessionPhaseChanged(phase))
    }

    private func perform(_ actions: [SelectionSpeechRouting.Action]) {
      for action in actions { perform(action) }
      // Every routing step comes through here, so this sees every return to rest.
      if !routing.isHandlingPress { pressSettled() }
    }

    private func perform(_ action: SelectionSpeechRouting.Action) {
      switch action {
      case .forward(let command): session.submit(command)
      case .prepareCommand: Task { [performer] in await performer.commandStarting() }
      case .readScreen:
        screenRead?.cancel()
        screenRead = Task { [performer] in await performer.screenContext() }
      case .readSelection:
        Task { [weak self] in
          let selection = await self?.readSelection()
          guard let self else { return }
          self.perform(self.routing.selectionResolved(selection))
        }
      case .startHoldTimer: startHoldTimer()
      case .syncGateAfterSession: syncGateAfterSession()
      case .resetGate: resetGate()
      case .speak, .answer, .stopSpeech, .rewrite, .compose, .runCommand, .stopJob: performTask(action)
      }
    }

    /// The actions that start or stop a task of this router's own: a read, an
    /// answer, a rewrite, a composition, a command.
    private func performTask(_ action: SelectionSpeechRouting.Action) {
      switch action {
      case .speak(let selection):
        // Read per press, like the switch itself, so a Settings change applies
        // to the next read.
        let style = ReadAloudStyleStore(defaults: defaults).style
        // The selection arrives with its edges for a rewrite; a read wants the words.
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        run { [speaker] onLevel in try await speaker.speak(text, style: style, onLevel: onLevel) }
      case .answer(let request, let selection):
        let style = ReadAloudStyleStore(defaults: defaults).style
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        run(startCueDelay: Self.answerCueGap) { [speaker] onLevel in
          try await speaker.answer(request, about: words, style: style, onLevel: onLevel)
        }
      case .stopSpeech:
        speech?.cancel()
        speech = nil
        // Ended now, not when the cancelled task gets round to it: a
        // dictation the same press starts must not have its pill taken down
        // by this read's late end.
        endSpeech()
      case .rewrite(let request, let selection): rewrite(selection, as: request)
      case .compose(let request): compose(request)
      case .runCommand(let command): run(command)
      case .stopJob:
        // A stopped command's own end never runs, so stop its screen read and
        // undo its preparation here — before it ran, too; for a rewrite or a
        // composition there's neither, and this does nothing.
        screenRead?.cancel()
        screenRead = nil
        Task { [performer] in await performer.commandEnded() }
        guard let task = job else { return }
        task.cancel()
        job = nil
        // Ended now, as a stopped read is, so the press that stopped it
        // shows its own state rather than this job's late end.
        jobPill(nil)
      case .forward, .prepareCommand, .readScreen, .readSelection, .startHoldTimer, .syncGateAfterSession, .resetGate:
        break
      }
    }

    /// One timer at a time: a newer press cancels the older one's, so a timer
    /// left over from a quick tap can't mark the next press as a hold.
    private func startHoldTimer() {
      holdTimer?.cancel()
      holdTimer = Task { [weak self, clock] in
        try? await clock.sleep(for: SelectionSpeechRouting.holdDelay)
        guard !Task.isCancelled, let self else { return }
        self.holdTimer = nil
        self.perform(self.routing.holdElapsed())
      }
    }

    /// Rewrites `selection` as `request` asks and pastes it over the
    /// selection, through the session's injector, reporting the outcome to the
    /// pill as a dictation's paste would be (`PipelinePhase.overlayState`). A
    /// rewrite this router stopped reports nothing more: `.stopJob` already
    /// ended it.
    /// The rewriter sees only the words: the whitespace around them is the
    /// highlight's, and goes back where it was (`SelectionEdges`).
    private func rewrite(_ selection: String, as request: String) {
      let edges = SelectionEdges(selection)
      paste(as: .rewriting, named: "rewrite") { [rewriter] in
        edges.around(try await rewriter.rewrite(String(edges.words), as: request))
      }
    }

    /// Writes what the spoken `instructions` describe and pastes it at the
    /// cursor as a rewrite is pasted (`replaceSelection`: the hand-back
    /// press's target, no separating space). Written for that same target
    /// ("Slack" gets a chat message, "Mail" an email) — the app the press
    /// pinned, not whatever the user switched to while it transcribed.
    private func compose(_ instructions: String) {
      paste(as: .composing, named: "compose") { [composer, session] in
        try await composer.compose(instructions, for: await session.pinnedAppName)
      }
    }

    /// One rewrite or composition as the router's job: `pill` while `write`
    /// runs, then its text pasted through the session's injector and the
    /// outcome on the pill.
    private func paste(
      as pill: OverlayUIState, named name: String, _ write: @escaping @Sendable () async throws -> String
    ) {
      jobPill(pill)
      job = Task { [weak self, session] in
        let outcome: OverlayUIState
        do {
          let text = try await write()
          try Task.checkCancellation()
          outcome = try await session.replaceSelection(with: text).overlayState
        } catch {
          // A cancelled request answers `URLError.cancelled`: abandoned, not failed.
          if Self.isCancellation(error) { return }
          Self.logger.error("\(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
          outcome = Self.failure(error)
        }
        guard !Task.isCancelled, let self else { return }
        self.job = nil
        self.jobPill(outcome)
        self.perform(self.routing.jobFinished())
      }
    }

    /// Carries out a spoken command: the planner's steps in order, each
    /// performed, a `type` pasted through the session's injector, reporting
    /// the outcome to the pill. The first step that fails ends it, and a
    /// command this router stopped reports nothing more, as a rewrite doesn't.
    private func run(_ command: String) {
      // The read `.readScreen` started — at the release, or just now for a
      // command the recording cap handed back — mostly or wholly done.
      let started = screenRead
      screenRead = nil
      // "That didn't work": not a command to plan, but a report about the
      // last one, logged against it for whoever reads the log to act on.
      if CommandFeedback.isComplaint(command) {
        started?.cancel()
        DictationLog.appendFeedback(command, about: lastCommand)
        Task { [performer] in await performer.commandEnded() }
        jobPill(.noted)
        perform(routing.jobFinished())
        return
      }
      jobPill(.commanding)
      job = Task { [weak self, planner, performer, session] in
        let record = await Self.execute(
          command, screen: started, planner: planner, performer: performer, session: session)
        // In full, to the developer-mode log (`DictationLog+Commands`), an
        // abandoned command too.
        DictationLog.appendCommand(record)
        // A command a press abandoned ends through `.stopJob`, never here: a
        // late end from it — a cancelled request can throw a URLError rather
        // than a CancellationError — must not undo a newer command's start.
        guard !Task.isCancelled, let outcome = record.outcome else { return }
        await performer.commandEnded()
        guard !Task.isCancelled, let self else { return }
        self.lastCommand = record
        self.job = nil
        self.jobPill(outcome)
        self.perform(self.routing.jobFinished())
      }
    }

    /// Whether a read, answer, rewrite, composition or command is wearing the pill — what
    /// `PipelinePhase.overlayState(whileSpeaking:)` asks, so a session phase
    /// arriving under any of them can't cover it.
    public var ownsPill: Bool { activeGeneration != nil || job != nil }

    /// What the session's transcription shows as when it's a job's spoken
    /// words — "Rewriting", "Writing", "Working" — or nil for a dictation's "Transcribing":
    /// what `PipelinePhase.overlayState(whileSpeaking:processingAs:)` asks.
    public var processingState: OverlayUIState? { routing.processingState }

    /// Whether the recording under way is a command's.
    public var recordsCommand: Bool { routing.recordsCommand }

    /// Reports the read the pill is showing as over, once: the meter to 0, then
    /// `speechEnded`.
    private func endSpeech() {
      guard activeGeneration != nil else { return }
      activeGeneration = nil
      speechLevel(0)
      speechEnded()
    }

    /// The beat between an ask's end and its answer's start. The spoken
    /// request ends with dictation's stop chime, and the answer would start
    /// with read-aloud's start chime in the same instant — two sounds run
    /// together. Holding the second back this long keeps them apart.
    static let answerCueGap: Duration = .milliseconds(400)

    /// Runs one read or answer as the current speech task, handing it the meter
    /// callback, and reports its start and end. `startCueDelay` holds back the
    /// start (the pill and its chime) — skipped if the speech has already
    /// ended by then.
    private func run(
      startCueDelay: Duration = .zero,
      _ work: @escaping @Sendable (_ onLevel: @escaping @Sendable (Float) -> Void) async throws -> Void
    ) {
      speechGeneration += 1
      let generation = speechGeneration
      activeGeneration = generation
      if startCueDelay == .zero {
        speechStarted()
      } else {
        Task { [weak self, clock] in
          try? await clock.sleep(for: startCueDelay)
          guard let self, self.activeGeneration == generation else { return }
          self.speechStarted()
        }
      }
      let onLevel: @Sendable (Float) -> Void = { [weak self] level in
        Task { @MainActor in
          guard let self, self.activeGeneration == generation else { return }
          self.speechLevel(level)
        }
      }
      speech = Task { [weak self] in
        do {
          try await work(onLevel)
        } catch is CancellationError {
        } catch {
          Self.logger.error("read-aloud failed: \(error.localizedDescription, privacy: .public)")
          self?.speechFailed(error)
        }
        if let self, self.activeGeneration == generation { self.endSpeech() }
        // A read this router stopped was cancelled, and a newer one may already
        // be playing, so only a read that ended on its own reports back.
        guard !Task.isCancelled, let self else { return }
        self.speech = nil
        self.perform(self.routing.speechFinished())
      }
    }
  }
#endif
