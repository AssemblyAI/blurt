import AssemblyAI
import BlurtEngine
import Foundation

// The Record button's half of `TranscriptsModel`: start, pause, stop, discard,
// and saving what the live transcription heard. Split from TranscriptsModel.swift
// for the file-length budget, which is why the state it drives is internal
// rather than private there.

extension TranscriptsModel {
  /// A recording is running or finishing: the sheet is its, and nothing else
  /// may take it.
  var isRecordingBusy: Bool {
    switch state {
    case .recording, .finishingRecording:
      true

    default:
      false
    }
  }

  /// Starts recording the microphone and system audio together, streaming
  /// both to the realtime API so the transcript appears as it's spoken.
  /// `byUser` is false when a meeting started it (`MeetingAutoRecord`).
  func startRecording(byUser: Bool = true) {
    guard canRecord else {
      return
    }
    guard let apiKey = apiKey(), !apiKey.isEmpty else {
      state = .failed(fileName: "Recording", message: BlurtError.apiKeyMissing.localizedDescription)
      return
    }
    reset()
    let url = recordingsDirectory.appending(path: Self.recordingName(at: .now))
    let realtime = makeLiveSession(apiKey)
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
    state = .recording
    let opened = Task { await realtime.start() }
    recording = Recording(
      url: url,
      realtime: realtime,
      audio: feed,
      pump: pump,
      opened: opened,
      turns: applyTurns(from: realtime, opened: opened),
      quietStop: RecordingQuietStop(now: .now)
    )
    watchForQuiet(url)
    if byUser { noteUserStartedRecording() }
  }

  /// Applies `realtime`'s turns to the live transcript as they arrive. Every
  /// update is checked against the recording it belongs to, as `watchForQuiet`
  /// is: a session that outlives its recording must not write its turns into the
  /// next one's transcript, or end it when it fails.
  private func applyTurns(
    from realtime: any LiveTranscriptionSession,
    opened: Task<AsyncThrowingStream<RealtimeTurn, any Error>, Never>
  ) -> Task<Void, Never> {
    Task { [weak self] in
      let turns = await opened.value
      do {
        for try await turn in turns {
          guard let self, recording?.realtime === realtime else {
            return
          }
          live.apply(turn)
          if turn.transcript.trimmedNonEmpty() != nil { recording?.quietStop.heard(at: .now) }
        }
      } catch {
        guard let self, recording?.realtime === realtime else {
          return
        }
        liveTranscriptionFailed(error)
      }
    }
  }

  /// Ends the recording at `url` once nothing has been said for
  /// `RecordingQuietStop.after` — the conversation is over even if no one
  /// pressed Stop, or the meeting app still holds the mic. Paused time
  /// doesn't count. Stops as the user would: an auto-recorded meeting that's
  /// somehow still on isn't recorded again until it ends. The watch ends by
  /// itself once that recording does, however it ended.
  private func watchForQuiet(_ url: URL) {
    Task { [weak self] in
      while true {
        try? await Task.sleep(for: RecordingQuietStop.checkInterval)
        guard let self, isRecording, let recording, recording.url == url else {
          return
        }
        if !isPaused, recording.quietStop.isOver(now: .now) {
          stopRecording()
          return
        }
      }
    }
  }

  /// Pauses or resumes the recording. Paused, nothing is captured, written
  /// or sent — the live session just waits — and the clock stops. The socket
  /// stays open on purpose: the session has no idle timeout unless one is
  /// asked for (`inactivity_timeout`, which Blurt doesn't send), and reopening
  /// would restart turn numbering mid-transcript.
  func togglePause() {
    guard isRecording else {
      return
    }
    if let pausedAt {
      do {
        try recorder.resume()
        clockStart += Date.now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
        recording?.quietStop.heard(at: .now)
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
  /// `byUser` is false when a meeting's end stopped it (`MeetingAutoRecord`);
  /// a long silence (`watchForQuiet`) stops it as the user would.
  func stopRecording(byUser: Bool = true) {
    guard isRecording, let recording else {
      return
    }
    if byUser { noteUserStoppedRecording() }
    endCapture(recording, dropUnsent: false)
    state = .finishingRecording
    Task { [weak self] in
      await recording.pump.value
      // A Stop that lands before the socket has opened would otherwise find
      // the session idle, close it, and drop the audio queued for it.
      _ = await recording.opened.value
      await recording.realtime.finish()
      await recording.turns.value
      self?.saveRecording(recording.url)
    }
  }

  /// Stops and throws the recording away, file and all.
  func discardRecording() {
    guard isRecording, let recording else {
      return
    }
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
      // The audio may still hold speech: try the async pass on it. Saved
      // first, so no way the pass ends — failed, or abandoned with Back —
      // leaves the file with nothing pointing at it.
      state = .idle
      transcribe(url, kind: .recording, entry: keepUntranscribed(url))
      return
    }
    let entry = SavedTranscript(kind: .recording, date: .now, text: text, fileURL: url, plainText: live.plainText)
    add(entry)
    diarize(entry)
  }

  /// The socket failed mid-recording: stop, and keep what was transcribed.
  /// The error itself needn't reach the user — the audio file is complete up
  /// to here either way, and the async pass `saveRecording` starts
  /// transcribes all of it, replacing the cut-short live text. Only if that
  /// fails too does the entry keep the partial live transcript.
  /// Also the way out when the recorder can't resume, where the socket is
  /// still open: it is closed here, and its turns stop, rather than left
  /// running into the next recording.
  private func liveTranscriptionFailed(_: any Error) {
    guard isRecording, let recording else {
      return
    }
    endCapture(recording, dropUnsent: true)
    recording.turns.cancel()
    Task { await recording.realtime.cancel() }
    saveRecording(recording.url)
  }

  /// Upgrades a recording's live transcript to a diarized one: the saved
  /// audio goes to the async API with speaker labels, which separate voices
  /// far better than the realtime stream does on one mixed-down channel. The
  /// live text stands until it returns; then the entry — and the sheet, if it
  /// has it open — shows the labelled transcript, with Plain text beside it.
  /// Best-effort: on failure the live transcript simply stays.
  func diarize(_ entry: SavedTranscript) {
    guard let url = entry.fileURL else {
      return
    }
    Task { [weak self, transcriber] in
      guard let result = try? await transcriber.transcribe(fileAt: url), let self,
        result.text.trimmedNonEmpty() != nil,
        let index = history.firstIndex(where: { $0.id == entry.id })
      else {
        return
      }
      history[index].replaceTranscript(result.text, plain: result.plainText)
      save()
      if openEntry?.id == entry.id { showTranscript(of: history[index]) }
    }
  }

  /// Transcribes again a recording kept without a transcript — Try Again on
  /// the failure page, or opening it from the Library.
  func retranscribe(_ entry: SavedTranscript) {
    guard history.contains(where: { $0.id == entry.id }), let url = entry.fileURL else {
      return
    }
    transcribe(url, kind: entry.kind, entry: entry)
  }

  /// Saves the recording at `url` with no transcript yet
  /// (`needsTranscription`), so it is in the Library — playable, in Finder,
  /// and transcribed when opened — however its transcription ends.
  func keepUntranscribed(_ url: URL) -> SavedTranscript {
    let entry = SavedTranscript(kind: .recording, date: .now, text: "", fileURL: url)
    history.insert(entry, at: 0)
    save()
    return entry
  }

  /// Gives a recording kept without a transcript the one just made, and
  /// opens it; false if it was deleted meanwhile.
  func fillIn(_ entry: SavedTranscript, with result: FileTranscription) -> Bool {
    guard let index = history.firstIndex(where: { $0.id == entry.id }) else {
      return false
    }
    history[index].replaceTranscript(result.text, plain: result.plainText)
    save()
    let transcribed = history[index]
    open(transcribed)
    Task { [weak self] in await self?.applyTitle(to: transcribed) }
    return true
  }

  /// The app is quitting (`applicationWillTerminate`, a Sparkle relaunch
  /// included): no `deinit` runs and no task resumes after this, so whatever
  /// is in flight is finished here, synchronously. A recording's file is
  /// closed — left open, the `.m4a` never gets its index and won't play — and
  /// what the live transcription heard is saved with it; then the history is
  /// written. The diarized pass a normal stop starts can't run now; the entry
  /// keeps the live transcript and the audio. A recording that heard nothing
  /// live is still kept, untranscribed (`needsTranscription`), as a failed
  /// pass's is: the Library offers it again rather than leaving the file with
  /// nothing pointing at it.
  func prepareForExit() {
    recorder.stop()
    if let recording {
      self.recording = nil
      let text = live.text
      let heard = text.trimmedNonEmpty() != nil
      history.insert(
        SavedTranscript(
          kind: .recording,
          date: .now,
          text: heard ? text : "",
          fileURL: recording.url,
          plainText: heard ? live.plainText : nil
        ),
        at: 0
      )
    }
    flushHistory()
  }

  /// Writes the history now, in place of the pending debounced save, queued
  /// behind any write already under way so this one lands last. If the saved
  /// file hasn't been read in yet, it is read and merged first rather than
  /// overwritten with only this session's entries.
  private func flushHistory() {
    pendingSave?.cancel()
    writer.saveNow(history, mergingSaved: !isLoaded)
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
