import Foundation

#if os(macOS)

  /// Sits between the trigger keys and the dictation session. A press of a key
  /// set to read aloud reads the selected text; a press of a key set to ask
  /// records a spoken request about it and reads the answer; a dictating key's
  /// commands go straight to `DictationSession.submit` (see `TriggerKeyBindings`
  /// for which key does what).
  ///
  /// The decisions are the engine's `SelectionSpeechRouting`. This class carries
  /// out the actions it returns: the selection read, the hold timer, the speech
  /// task, and the gate resets. Only read and ask presses read the selection, so
  /// dictation never waits on an Accessibility round trip.
  ///
  /// Main-actor because its callers are: the key tap's callbacks, the session's
  /// phase observer and Settings all run on the main thread, and isolation lets
  /// the compiler prove single-threaded access to the routing state.
  @MainActor
  public final class SelectionSpeechRouter {
    private static let logger = HostIdentity.current.logger("SelectionSpeech")

    private let session: DictationSession
    private let speaker: any ReadAloudSpeaker
    private let readSelection: @Sendable () async -> String?
    private let defaults: UserDefaults
    private var routing = SelectionSpeechRouting()
    private var speech: Task<Void, Never>?
    /// The pending `holdElapsed`, restarted by each press that may ask.
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

    /// The seams: what speaks, how the selection is read, and where the
    /// settings each press reads come from. Public so a host can run the whole
    /// read-aloud path offline (Blurt's UI tests do).
    public init(
      session: DictationSession, speaker: any ReadAloudSpeaker,
      readSelection: @escaping @Sendable () async -> String?, defaults: UserDefaults = .standard
    ) {
      self.session = session
      self.speaker = speaker
      self.readSelection = readSelection
      self.defaults = defaults
    }

    /// A trigger key went down. What it does and whether it can be held are read
    /// per press, so a change in the Keys tab applies to the next one.
    public func press(key: TriggerKey) {
      let bindings = TriggerKeyBindings(defaults: defaults)
      let action = bindings.action(for: key)
      let holds = bindings.activation(for: key) != .tap
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

    /// `DictationKeyTap`'s latch: the press was a tap.
    public func keyLatched() {
      perform(routing.keyLatched())
    }

    public func sessionPhaseChanged(_ phase: PipelinePhase) {
      perform(routing.sessionPhaseChanged(phase))
    }

    private func perform(_ actions: [SelectionSpeechRouting.Action]) {
      for action in actions {
        switch action {
        case .forward(let command): session.submit(command)
        case .readSelection:
          Task { [weak self] in
            let selection = await self?.readSelection()
            guard let self else { return }
            self.perform(self.routing.selectionResolved(selection))
          }
        case .startHoldTimer: startHoldTimer()
        case .speak(let text):
          // Read per press, like the switch itself, so a Settings change applies
          // to the next read.
          let style = ReadAloudStyleStore(defaults: defaults).style
          run { [speaker] onLevel in try await speaker.speak(text, style: style, onLevel: onLevel) }
        case .answer(let request, let selection):
          let style = ReadAloudStyleStore(defaults: defaults).style
          run(startCueDelay: Self.answerCueGap) { [speaker] onLevel in
            try await speaker.answer(request, about: selection, style: style, onLevel: onLevel)
          }
        case .stopSpeech:
          speech?.cancel()
          speech = nil
          // Ended now, not when the cancelled task gets round to it: a
          // dictation the same press starts must not have its pill taken down
          // by this read's late end.
          endSpeech()
        case .syncGateAfterSession: syncGateAfterSession()
        case .resetGate: resetGate()
        }
      }
    }

    /// One timer at a time: a newer press cancels the older one's, so a timer
    /// left over from a quick tap can't mark the next press as a hold.
    private func startHoldTimer() {
      holdTimer?.cancel()
      holdTimer = Task { [weak self] in
        try? await Task.sleep(for: SelectionSpeechRouting.holdDelay)
        guard !Task.isCancelled, let self else { return }
        self.holdTimer = nil
        self.perform(self.routing.holdElapsed())
      }
    }

    /// Whether a read or answer is playing, wearing the pill — what
    /// `PipelinePhase.overlayState(whileSpeaking:)` asks.
    public var isSpeaking: Bool { activeGeneration != nil }

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
        Task { [weak self] in
          try? await Task.sleep(for: startCueDelay)
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
