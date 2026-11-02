#if os(macOS)
  import Foundation

  /// What reads text aloud for `SelectionSpeechRouter`: `SelectionSpeaker` in
  /// production, a stand-in under UI testing (no network, no audio). Both calls
  /// run until the speech has played; cancelling the task stops it.
  public protocol ReadAloudSpeaker: Sendable {
    func speak(_ text: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?) async throws
    func answer(
      _ request: String, about selection: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?
    ) async throws
  }

  /// Reads text aloud with AssemblyAI's streaming TTS. This is the engine half of
  /// the read-aloud and ask keys (`SelectionSpeechRouting`); the app decides when
  /// to call it.
  ///
  /// `speak` runs until the last sample has played. To stop early, cancel the task
  /// that is awaiting it: cancellation silences playback at once and cancels the
  /// request in flight.
  struct SelectionSpeaker: ReadAloudSpeaker {
    /// The most text one press will read: a long article (about 15,000 words).
    /// Reading is paced by listening (`bufferTarget`), so a long selection costs
    /// only as much TTS as is heard before it's stopped.
    static let maxCharacters = 100_000

    /// How far ahead of the listener the reading runs, in seconds: the next
    /// piece is asked for once less than this is queued. Comfortably longer
    /// than a piece's rewrite and first audio, so pieces join without a gap.
    static let bufferTarget: Double = 30

    private static let logger = HostIdentity.current.logger("SelectionSpeech")

    private let synthesizer: AssemblyAISpeechSynthesizer
    private let llm: ReadAloudLLM
    private let makeSink: @Sendable (_ rate: Double) -> any PCMSink
    /// Where each read's audio is kept and who hears about it; nil keeps none.
    private let clips: ReadClipSink?

    init(clips: ReadClipSink? = nil) {
      self.init(synthesizer: AssemblyAISpeechSynthesizer(), llm: ReadAloudLLM(), clips: clips) { rate in
        StreamingPCMPlayer(sampleRate: AssemblyAISpeechSynthesizer.sampleRate, rate: rate)
      }
    }

    /// `makeSink` is the playback seam, handed the style's rate. There is one
    /// sink per `speak`, so a cancelled read can't bleed into the next one.
    init(
      synthesizer: AssemblyAISpeechSynthesizer, llm: ReadAloudLLM, clips: ReadClipSink? = nil,
      makeSink: @escaping @Sendable (_ rate: Double) -> any PCMSink
    ) {
      self.synthesizer = synthesizer
      self.llm = llm
      self.clips = clips
      self.makeSink = makeSink
    }

    /// The selected text in the frontmost app, or nil when there is none, when
    /// the field is secure, or when it can't be read.
    ///
    /// Accessibility first. The read is synchronous cross-process IPC that can
    /// block a thread for the AX timeout against a hung app, so it runs off the
    /// cooperative pool (`BlockingIPC.run`). When AX can't reach a
    /// focused element at all, it falls back to copying the selection
    /// (`SelectionCopy`).
    static func focusedSelection() async -> String? {
      let read = await BlockingIPC.run { FocusCapture.captureSelectedText(maxChars: maxCharacters) }
      return await resolve(read, copy: SelectionCopy())
    }

    /// Split from `focusedSelection` so the fallback rule is testable without AX.
    static func resolve(_ read: FocusCapture.SelectionRead, copy: SelectionCopy) async -> String? {
      switch read {
      case .text(let text): text
      case .none: nil
      case .unreadable: await copy.copySelection(maxCharacters: maxCharacters)
      }
    }

    /// Reads `text` in `style`, a piece at a time (`ListeningChunks`): each
    /// rewritten for listening first when it skips jargon, then spoken in its
    /// voice and played at its rate, the next asked for only as the listening
    /// catches up (`bufferTarget`). `onLevel`, when
    /// given, hears the loudness of what's playing about 20 times a second
    /// while it plays, then a final 0 — the pill's meter.
    func speak(
      _ text: String, style: ReadAloudStyle = .standard, onLevel: (@Sendable (Float) -> Void)? = nil
    ) async throws {
      try await speak(text, style: style, onLevel: onLevel, request: nil)
    }

    /// `speak`, kept as a clip (`clips`) when there is somewhere to keep it:
    /// the audio is copied as it plays, and the clip is reported however the
    /// read ends — finished, stopped or failed part-way — as long as some of it
    /// was heard. `request` is the question an answer replied to.
    private func speak(
      _ text: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?, request: String?
    ) async throws {
      let pieces = ListeningChunks.chunks(of: text)
      guard !pieces.isEmpty else { return }
      let writer = makeClipWriter()
      let base = makeSink(style.rate)
      let player: any PCMSink = writer.map { ClipRecordingSink(base: base, writer: $0) } ?? base
      defer { finishClip(writer, text: text, request: request) }
      // At the mic meter's rate, and only on a change: the silence before the
      // first audio and between words is a run of zeros the pill needn't hear.
      let meter = onLevel.map { onLevel in
        Task {
          var last: Float?
          while !Task.isCancelled {
            let level = player.currentLevel
            if level != last { onLevel(level) }
            last = level
            try? await Task.sleep(for: .seconds(MicCapture.meterIntervalSeconds))
          }
        }
      }
      defer {
        meter?.cancel()
        onLevel?(0)
      }
      try await withTaskCancellationHandler {
        do {
          for piece in pieces {
            try await waitForRoom(in: player)
            let spoken = style.skipsJargon ? try await forListening(piece) : piece
            // A stop that landed while the rewrite's answer was already on its
            // way back: nothing more should play, and no request should go out.
            try Task.checkCancellation()
            for try await chunk in synthesizer.speech(for: spoken, voiceID: style.voiceID) {
              player.enqueue(chunk)
            }
            // A stopped read's stream just ends — iteration doesn't throw on
            // cancellation — so say it was stopped rather than drain as if done.
            try Task.checkCancellation()
          }
        } catch {
          player.stop()
          throw error
        }
        await player.drain()
      } onCancel: {
        player.stop()
      }
    }

    /// Answers a spoken `request` about `selection` and reads the answer aloud in
    /// `style`'s voice and rate. The answer is already written to be heard, so it skips the
    /// listening rewrite. No fallback: when the answer fails, there is nothing
    /// else to read.
    func answer(
      _ request: String, about selection: String, style: ReadAloudStyle,
      onLevel: (@Sendable (Float) -> Void)? = nil
    ) async throws {
      let reply = try await llm.answer(request, about: selection)
      try Task.checkCancellation()
      try await speak(reply, style: style.verbatim, onLevel: onLevel, request: request)
    }

    /// A writer for this read's clip, when clips are kept and the file opens.
    private func makeClipWriter() -> WAVWriter? {
      clips.flatMap { clips in
        try? WAVWriter(
          url: clips.directory.appending(path: "Read \(TranscriptStore.fileStamp(.now)).wav"),
          sampleRate: AssemblyAISpeechSynthesizer.sampleRate)
      }
    }

    /// Closes the clip and reports it, or drops the file if nothing was heard.
    private func finishClip(_ writer: WAVWriter?, text: String, request: String?) {
      guard let writer, let clips else { return }
      if writer.finish() > 0 {
        clips.onClip(ReadClip(text: text, audioURL: writer.url, request: request))
      } else {
        try? FileManager.default.removeItem(at: writer.url)
      }
    }

    /// Returns once less than `bufferTarget` seconds of audio are queued, so the
    /// next piece is synthesized only as the listening reaches it.
    private func waitForRoom(in player: any PCMSink) async throws {
      // Sleep out the excess — it drains at listening speed — then look again:
      // between a quarter second (should the clock stall) and a second, so a
      // wait of minutes is a wake a second rather than four.
      while player.bufferedSeconds > Self.bufferTarget {
        try await Task.sleep(for: .seconds(min(1, max(0.25, player.bufferedSeconds - Self.bufferTarget))))
      }
    }

    /// `text` rewritten by `ReadAloudLLM`, or `text` itself when the rewrite
    /// fails: hearing the jargon beats hearing nothing. A stop during the rewrite
    /// is the one failure that doesn't fall back, since nothing should play.
    private func forListening(_ text: String) async throws -> String {
      do {
        return try await llm.rewriteForListening(text)
      } catch {
        try Task.checkCancellation()
        Self.logger.error(
          "read-aloud rewrite failed, reading verbatim: \(error.localizedDescription, privacy: .public)")
        return text
      }
    }
  }
#endif
