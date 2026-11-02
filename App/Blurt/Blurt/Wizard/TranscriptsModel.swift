import AssemblyAI
import BlurtEngine
import Foundation
import Observation

/// The main window's transcriptions: files dropped or browsed for, recordings
/// made with Record, the saved history of all of them, and the stock
/// transforms of whichever one the sheet has open.
///
/// A recording is transcribed by the async API (`FileTranscriber`), so it can
/// be any length; a transform runs over the stored transcript on the LLM
/// Gateway (`TranscriptLLM`). Every transcript, and every transform fetched for
/// it, is saved (`TranscriptStore`) — so reopening one, or going back to
/// **Full**, the transcript itself, costs nothing.
@Observable
final class TranscriptsModel {
  enum State: Equatable {
    case idle
    case transcribing(fileName: String, phase: AsyncTranscriptionClient.Phase)
    /// Recording, with the live transcript streaming into `live`.
    case recording
    /// Stopped; the last audio and the last turn's final are on their way.
    case finishingRecording
    /// A saved entry is open (`openEntry`).
    case finished
    case failed(fileName: String, message: String)
  }

  /// What one facet's text area shows.
  enum Content: Equatable {
    case loading
    case ready(String)
    case failed(String)
  }

  /// Set here and by the recording extension (`TranscriptsModel+Recording.swift`).
  var state = State.idle
  /// The facet on show. Always `.full` when a transcript opens.
  private(set) var selection = TranscriptFacet.full
  /// Every facet in hand for the open transcript; `.full` is the transcript.
  var contents: [TranscriptFacet: Content] = [:]
  /// The open transcript's speaker turns, parsed once (`showTranscript`);
  /// empty for anything without speakers told apart.
  private(set) var fullTurns: [SpeakerTurn] = []
  /// The last custom request applied, for the Custom popover to start from.
  private(set) var customRequest = ""
  /// Every saved transcript, newest first.
  var history: [SavedTranscript] {
    didSet { refreshOpenEntry() }
  }
  /// The recording's transcript as it streams in — settled turns and the
  /// partial being spoken.
  var live = LiveTranscript()

  @ObservationIgnored let transcriber: FileTranscriber
  @ObservationIgnored private let llm: TranscriptLLM
  @ObservationIgnored private let store: TranscriptStore
  /// The key the model's own checks read — the same one the transcriber and
  /// the LLM are given, so a test's in-memory key is the only one consulted.
  @ObservationIgnored let apiKey: @Sendable () -> String?
  @ObservationIgnored let recorder = SystemAudioRecorder()
  /// Plays saved audio from the Recent list and the sheet.
  let player = ClipPlayer()
  /// Reads a task result aloud (`TranscriptsModel+Playback.swift`).
  @ObservationIgnored let reader = TextReader()
  /// The task result being read aloud now, if any.
  var readingFacet: TranscriptFacet?
  @ObservationIgnored var readingTask: Task<Void, Never>?
  /// Auto-record meetings (`TranscriptsModel+Meetings.swift`): the policy,
  /// the probe loop while the switch is on, and the last probe's answer.
  @ObservationIgnored var meetingPolicy = MeetingAutoRecord()
  @ObservationIgnored var meetingProbe: Task<Void, Never>?
  @ObservationIgnored var lastMeetingActive = false
  @ObservationIgnored var recording: Recording?
  /// When the recording was paused, while it is; nil while it records.
  var pausedAt: Date?
  /// When the recording clock reads zero: the start, moved later by every
  /// pause, so the clock counts capturing time only (`Text(timerInterval:)`).
  var clockStart = Date.now
  /// The ring entries already saved, so a re-pushed ring adds only what's new.
  @ObservationIgnored private var savedDictationIDs: Set<UUID> = []
  /// Which `transcribe` run is current, so a late phase update from an
  /// abandoned one can't land on its successor (both may be "Recording …").
  @ObservationIgnored private var currentRun = UUID()
  @ObservationIgnored private var tasks: [TranscriptFacet: Task<Void, Never>] = [:]
  @ObservationIgnored private var pendingSave: Task<Void, Never>?
  /// Whether the saved history has been read in. Until it has, nothing is
  /// written: a save then would replace the file with only this session's
  /// entries. The load's merge saves whatever arrived before it.
  @ObservationIgnored private var isLoaded = false

  init(
    apiKey: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transcriber: FileTranscriber? = nil, llm: TranscriptLLM? = nil,
    store: TranscriptStore = TranscriptStore()
  ) {
    self.apiKey = apiKey
    self.transcriber = transcriber ?? FileTranscriber(apiKeyProvider: apiKey)
    self.llm = llm ?? TranscriptLLM(apiKeyProvider: apiKey)
    self.store = store
    self.history = []
    // Read off the main actor: the history only grows, and launch shouldn't
    // wait on decoding it. Anything saved meanwhile stays on top.
    Task { [weak self, store] in
      let loaded = await Task.detached(priority: .userInitiated) { store.load() }.value
      guard let self else { return }
      let added = Set(history.map(\.id))
      history += loaded.filter { !added.contains($0.id) }
      isLoaded = true
      if !added.isEmpty { save() }
      await titleUntitled()
    }
  }

  /// Files and recordings saved before they had titles, or whose title
  /// request failed: asked for once more, one at a time, and only with a key
  /// — never a burst of requests that can't succeed.
  private func titleUntitled() async {
    guard apiKey()?.isEmpty == false else { return }
    for entry in history where entry.generatedTitle == nil && entry.isTranscript {
      await applyTitle(to: entry)
    }
  }

  /// Asks the LLM for `entry`'s title and saves it on the entry. Best-effort:
  /// until it comes — or if it fails — the entry keeps its file name.
  private func applyTitle(to entry: SavedTranscript) async {
    guard let title = try? await llm.title(for: entry.text),
      let index = history.firstIndex(where: { $0.id == entry.id })
    else { return }
    history[index].generatedTitle = title
    save()
  }

  /// The chips the open entry offers: Plain text only where it differs from
  /// the labelled transcript — a file or recording with several speakers.
  var availableFacets: [TranscriptFacet] {
    TranscriptFacet.allCases.filter { $0 != .plain || openEntry?.plainText != nil }
  }

  /// What the selected facet shows, when it has text — what Copy copies.
  var selectedText: String? {
    guard case .ready(let text) = contents[selection] else { return nil }
    return text
  }

  var isPaused: Bool { pausedAt != nil }

  var isRecording: Bool {
    if case .recording = state { true } else { false }
  }

  /// Whether Record can start: not while anything else has the sheet.
  var canRecord: Bool { state == .idle }

  /// One recording in flight: where it's written, the live session, the
  /// audio feed into it, and the two tasks that pump audio out and turns in.
  struct Recording {
    let url: URL
    let realtime: RealtimeTranscriber
    let audio: AsyncStream<Data>.Continuation
    let pump: Task<Void, Never>
    let turns: Task<Void, Never>
  }

  /// Opens a saved transcript in the sheet, with every transform already
  /// fetched for it.
  func open(_ entry: SavedTranscript) {
    reset()
    openEntry = entry
    customRequest = entry.customRequest ?? ""
    showTranscript(of: entry)
    for facet in TranscriptFacet.allCases where facet != .full && facet != .plain {
      if let text = entry.results[facet.rawValue] { contents[facet] = .ready(text) }
    }
    state = .finished
  }

  /// Puts an entry's transcript in the sheet: Full, Plain text where it
  /// differs, and — for a transcript with speakers told apart — its turns,
  /// parsed once here rather than on every render.
  func showTranscript(of entry: SavedTranscript) {
    contents[.full] = .ready(entry.text)
    contents[.plain] = entry.plainText.map(Content.ready)
    fullTurns = entry.isTranscript ? SpeakerTurn.parse(entry.text) : []
  }

  /// Saves a new transcript at the top of the history, opens it, and asks for
  /// its title.
  func add(_ entry: SavedTranscript) {
    history.insert(entry, at: 0)
    save()
    open(entry)
    Task { [weak self] in await self?.applyTitle(to: entry) }
  }

  /// Saves a read-aloud clip as it lands.
  func saveReadClip(_ clip: ReadClip) {
    history.insert(
      SavedTranscript(kind: .readAloud, date: .now, text: clip.text, fileURL: clip.audioURL, request: clip.request),
      at: 0)
    save()
  }

  /// The entry the sheet has open, if it's a saved one. Stored, and kept
  /// current by `history`'s `didSet`, so the sheet reads it without scanning
  /// the history — and doesn't redraw when some other entry changes.
  private(set) var openEntry: SavedTranscript?

  /// Re-reads the open entry after the history changed, assigning only when
  /// it did change so observers of `openEntry` aren't woken for nothing.
  private func refreshOpenEntry() {
    guard let id = openEntry?.id else { return }
    let current = history.first { $0.id == id }
    if current != openEntry { openEntry = current }
  }

  /// Saves every dictation in `ring` not saved yet. The ring is the session's
  /// whole history pushed after each dictation, so its entries' ids say which
  /// are new; a dictation into a secure field never reaches it.
  func saveDictations(from ring: RecentDictations) {
    let new = ring.entries.filter { savedDictationIDs.insert($0.id).inserted }
    guard !new.isEmpty else { return }
    let entries = new.map {
      SavedTranscript(id: $0.id, kind: .dictation, date: $0.timestamp, text: $0.text, style: $0.style)
    }
    history.insert(contentsOf: entries, at: 0)
    save()
  }

  /// Removes a saved transcript. Audio Blurt made — a recording, a read-aloud
  /// clip — is deleted with it; a file the user brought is theirs and stays.
  func delete(_ entry: SavedTranscript) {
    let wasOpen = openEntry?.id == entry.id
    history.removeAll { $0.id == entry.id }
    save()
    if let url = entry.fileURL, entry.ownsAudio {
      if player.playingID == entry.id { player.stop() }
      try? FileManager.default.removeItem(at: url)
    }
    if wasOpen { dismiss() }
  }

  // MARK: - Facets

  /// Shows `facet`, fetching it if it hasn't been (or failed last time).
  /// Custom with no request yet only selects; the popover asks for one.
  func select(_ facet: TranscriptFacet) {
    if facet != selection { stopReading() }
    selection = facet
    switch contents[facet] {
    case .loading, .ready: return
    case .failed, nil: fetch(facet)
    }
  }

  /// Applies a new custom request, replacing the previous custom result.
  func applyCustom(_ request: String) {
    guard let request = request.trimmedNonEmpty() else { return }
    customRequest = request
    tasks[.custom]?.cancel()
    contents[.custom] = nil
    select(.custom)
  }

  /// Fetches the selected facet again after a failure.
  func retry() { fetch(selection) }

  private func fetch(_ facet: TranscriptFacet) {
    guard let transform = facet.transform(custom: customRequest),
      case .ready(let transcript) = contents[.full]
    else { return }
    contents[facet] = .loading
    let request = customRequest
    tasks[facet]?.cancel()
    tasks[facet] = Task { [weak self, llm] in
      let content: Content
      do {
        content = .ready(try await llm.apply(transform, to: transcript))
      } catch {
        content = .failed(error.localizedDescription)
      }
      guard !Task.isCancelled, let self else { return }
      contents[facet] = content
      if case .ready(let text) = content { remember(text, for: facet, request: request) }
    }
  }

  /// Saves a fetched transform onto the open transcript's history entry.
  private func remember(_ text: String, for facet: TranscriptFacet, request: String) {
    guard let index = history.firstIndex(where: { $0.id == openEntry?.id }) else { return }
    history[index].results[facet.rawValue] = text
    if facet == .custom { history[index].customRequest = request }
    save()
  }

  // MARK: - Sheet lifecycle

  /// Shows why a drop that held no audio or video file wasn't transcribed.
  func refuse(_ url: URL?) {
    guard !isRecordingBusy else { return }
    reset()
    state = .failed(
      fileName: url?.lastPathComponent ?? "Dropped item",
      message: "Blurt can only transcribe audio and video files.")
  }

  /// Closes the sheet. A transcription still uploading or running is
  /// abandoned; transforms already fetched are saved.
  ///
  /// Never while recording or finishing one: a stray Esc must not cost a
  /// meeting. Stop or Discard are the only ways out of a recording.
  func dismiss() {
    guard !isRecordingBusy else { return }
    reset()
    state = .idle
  }

  func reset() {
    stopReading()
    fullTurns = []
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
    contents = [:]
    selection = .full
    customRequest = ""
    openEntry = nil
  }

  /// Saves the history — coalesced, and written off the main actor: a burst
  /// of changes (a dictation, its title, a transform) costs one write, and the
  /// write never holds up the UI. The last change within the delay wins.
  func save() {
    pendingSave?.cancel()
    guard isLoaded else { return }
    let snapshot = history
    pendingSave = Task { [store] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      await Task.detached(priority: .utility) { try? store.save(snapshot) }.value
    }
  }
}

// MARK: - Transcribing

extension TranscriptsModel {
  /// Uploads and transcribes `url`, saving the result and opening it.
  ///
  /// `kind` is `.recording` for a recording whose live transcript came back
  /// empty: its audio is still worth the async pass, and if that finds nothing
  /// either the file is deleted rather than left with no entry pointing at it.
  /// If the pass fails, the file is kept: the audio may hold the whole meeting.
  ///
  /// Never over a recording: a file dropped while one runs is refused, or the
  /// recording would be left capturing with no sheet to stop it.
  func transcribe(_ url: URL, kind: SavedTranscript.Kind = .file) {
    guard !isRecordingBusy else { return }
    reset()
    let fileName = url.lastPathComponent
    let run = UUID()
    currentRun = run
    state = .transcribing(fileName: fileName, phase: .uploading)
    tasks[.full] = Task { [weak self, transcriber] in
      let outcome: Result<FileTranscription, any Error>
      do {
        outcome = .success(
          try await transcriber.transcribe(fileAt: url) { phase in
            Task { @MainActor in
              guard let self, self.currentRun == run, case .transcribing = self.state else { return }
              self.state = .transcribing(fileName: fileName, phase: phase)
            }
          })
      } catch {
        outcome = .failure(error)
      }
      guard !Task.isCancelled, let self else { return }
      switch outcome {
      case .success(let result) where result.text.trimmedNonEmpty() == nil:
        if kind == .recording { try? FileManager.default.removeItem(at: url) }
        state = .failed(fileName: fileName, message: "No speech was found in that file.")
      case .success(let result):
        add(SavedTranscript(kind: kind, date: .now, text: result.text, fileURL: url, plainText: result.plainText))
      case .failure(let error):
        // A failure isn't "no speech": the recording stays in its folder
        // rather than costing the user the audio over a network blip.
        state = .failed(fileName: fileName, message: error.localizedDescription)
      }
    }
  }

  /// A recording is running or finishing: the sheet is its, and nothing else
  /// may take it.
  var isRecordingBusy: Bool {
    switch state {
    case .recording, .finishingRecording: true
    default: false
    }
  }
}
