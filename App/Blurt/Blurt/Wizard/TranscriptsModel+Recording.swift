import AssemblyAI
import BlurtEngine
import Foundation

// The Record button's half of `TranscriptsModel`: start, pause, stop, discard,
// and saving what the live transcription heard. Split from TranscriptsModel.swift
// for the file-length budget, which is why the state it drives is internal
// rather than private there.

extension TranscriptsModel {
  /// Starts recording the microphone and system audio together, streaming
  /// both to the realtime API so the transcript appears as it's spoken.
  func startRecording() {
    guard canRecord else { return }
    guard let apiKey = APIKeyStore.current, !apiKey.isEmpty else {
      state = .failed(fileName: "Recording", message: BlurtError.apiKeyMissing.localizedDescription)
      return
    }
    reset()
    let url = TranscriptStore.recordingsDirectory.appending(path: Self.recordingName(at: .now))
    let realtime = RealtimeTranscriber.blurt(apiKey: apiKey)
    // One ordered feed from the recorder's queue to the socket: the recorder
    // yields each slice as it is mixed, and a single task sends them in turn.
    let (audio, feed) = AsyncStream.makeStream(of: Data.self)
    let pump = Task {
      for await slice in audio { await realtime.send(slice) }
    }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try recorder.start(to: url) { feed.yield($0) }
    } catch {
      feed.finish()
      pump.cancel()
      state = .failed(fileName: "Recording", message: error.localizedDescription)
      return
    }
    live = LiveTranscript()
    pausedAt = nil
    clockStart = .now
    state = .recording(startedAt: .now)
    recording = Recording(url: url, realtime: realtime, audio: feed, pump: pump)
    recording?.turns = Task { [weak self] in
      let turns = await realtime.start()
      do {
        for try await turn in turns { self?.live.apply(turn) }
      } catch {
        self?.liveTranscriptionFailed(error)
      }
    }
  }

  /// Pauses or resumes the recording. Paused, nothing is captured, written
  /// or sent — the live session just waits — and the clock stops.
  func togglePause() {
    guard isRecording else { return }
    if let pausedAt {
      do {
        try recorder.resume()
        clockStart += Date.now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
      } catch {
        liveTranscriptionFailed(error)
      }
    } else {
      recorder.pause()
      pausedAt = .now
    }
  }

  /// Stops recording, lets the last audio and the last turn's final arrive,
  /// then saves the live transcript and opens it.
  /// `byUser` is false when a meeting's end stopped it (`MeetingAutoRecord`).
  func stopRecording(byUser: Bool = true) {
    guard isRecording, let recording else { return }
    if byUser { noteUserStoppedRecording() }
    endCapture(recording, dropUnsent: false)
    state = .finishingRecording
    Task { [weak self] in
      await recording.pump.value
      await recording.realtime.finish()
      await recording.turns?.value
      self?.saveRecording(recording.url)
    }
  }

  /// Stops and throws the recording away, file and all.
  func discardRecording() {
    guard isRecording, let recording else { return }
    noteUserStoppedRecording()
    endCapture(recording, dropUnsent: true)
    Task { await recording.realtime.cancel() }
    try? FileManager.default.removeItem(at: recording.url)
    self.recording = nil
    reset()
    state = .idle
  }

  private func saveRecording(_ url: URL) {
    recording = nil
    let text = live.text
    guard text.trimmedNonEmpty() != nil else {
      // Nothing heard live — silence, or a live session that never got going.
      // The audio may still hold speech: try the async pass on it, which
      // saves it or, finding nothing, deletes the file.
      state = .idle
      transcribe(url, kind: .recording)
      return
    }
    let entry = SavedTranscript(kind: .recording, date: .now, text: text, fileURL: url, plainText: live.plainText)
    add(entry)
    diarize(entry)
  }

  /// The socket failed mid-recording: stop, and keep what was transcribed —
  /// the audio file is complete up to here either way.
  private func liveTranscriptionFailed(_ error: any Error) {
    guard isRecording, let recording else { return }
    endCapture(recording, dropUnsent: true)
    let message = error.localizedDescription
    saveRecording(recording.url)
    if case .failed = state { state = .failed(fileName: recording.url.lastPathComponent, message: message) }
  }

  /// Upgrades a recording's live transcript to a diarized one: the saved
  /// audio goes to the async API with speaker labels, which separate voices
  /// far better than the realtime stream does on one mixed-down channel. The
  /// live text stands until it returns; then the entry — and the sheet, if it
  /// has it open — shows the labelled transcript, with Plain text beside it.
  /// Best-effort: on failure the live transcript simply stays.
  func diarize(_ entry: SavedTranscript) {
    guard let url = entry.fileURL else { return }
    Task { [weak self, transcriber] in
      guard let result = try? await transcriber.transcribe(fileAt: url), let self,
        result.text.trimmedNonEmpty() != nil,
        let index = history.firstIndex(where: { $0.id == entry.id })
      else { return }
      history[index].replaceTranscript(result.text, plain: result.plainText)
      save()
      if openEntry?.id == entry.id { showTranscript(of: history[index]) }
    }
  }

  /// Stops capturing and ends the audio feed — every way a recording ends.
  /// `dropUnsent` also abandons audio not yet sent, for an ending that won't
  /// wait for the live transcript to finish.
  private func endCapture(_ recording: Recording, dropUnsent: Bool) {
    recorder.stop()
    recording.audio.finish()
    if dropUnsent { recording.pump.cancel() }
  }
}
