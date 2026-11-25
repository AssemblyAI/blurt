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
    /// `retry`: a recording kept untranscribed, for Try Again.
    case failed(fileName: String, message: String, retry: SavedTranscript? = nil)
  }

  /// What one facet's text area shows.
  enum Content: Equatable {
    case loading
    case ready(String)
    case failed(String)
  }

  /// One recording in flight, and when it last heard a word (`+Recording.swift`).
  struct Recording {
    let url: URL
    let realtime: any LiveTranscriptionSession
    let audio: AsyncStream<Data>.Continuation
    let pump: Task<Void, Never>
    /// The socket being opened. Stopping waits for it before `finish`, which
    /// on a session not yet open would close it and drop the queued audio.
    let opened: Task<AsyncThrowingStream<RealtimeTurn, any Error>, Never>
    let turns: Task<Void, Never>
    var quietStop: RecordingQuietStop
  }

  /// Set here and by the recording extension (`TranscriptsModel+Recording.swift`).
  var state = State.idle
  /// The facet on show. Always `.full` when a transcript opens.
  private(set) var selection = TranscriptFacet.full
  /// Every facet in hand for the open transcript; `.full` is the transcript.
  private(set) var contents: [TranscriptFacet: Content] = [:]
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

  let transcriber: FileTranscriber
  private let llm: TranscriptLLM
  /// The key the model's own checks read — the same one the transcriber and
  /// the LLM are given, so a test's in-memory key is the only one consulted.
  let apiKey: @Sendable () -> String?
  /// What Record captures from (`SystemAudioRecorder`, the microphone and
  /// system audio), the live transcription it streams to (the realtime API, given
  /// the key) and where its files go. Seams for the UI tests'
  /// offline doubles (`TranscriptsModel.uiTest(store:)`), as the transcriber is.
  let recorder: any RecordingCapture
  let makeLiveSession: @Sendable (String) -> any LiveTranscriptionSession
  let recordingsDirectory: URL
  /// Plays saved audio from the Recent list and the sheet.
  let player = ClipPlayer()
  /// Reads a task result aloud (`TranscriptsModel+Playback.swift`).
  let reader = TextReader()
  /// The task result being read aloud now, if any.
  var readingFacet: TranscriptFacet?
  /// Whether that reading's first word has played; before, it's preparing.
  var readingStarted = false
  @ObservationIgnored var readingTask: Task<Void, Never>?
  /// Meetings' switch, policy, probe loop and last answer (`+Meetings.swift`).
  @ObservationIgnored var autoRecordMeetings = false
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
  /// Internal, not private, as `tasks` is: `TranscriptsModel+Transcribing.swift`
  /// starts the runs and their tasks.
  @ObservationIgnored var currentRun = UUID()
  @ObservationIgnored var tasks: [TranscriptFacet: Task<Void, Never>] = [:]
  @ObservationIgnored private(set) var pendingSave: Task<Void, Never>?
  /// History writes, one at a time and in order, so an older list never lands last.
  /// Internal, like `pendingSave` and `isLoaded`: `prepareForExit` reads them.
  let writer: TranscriptWriter
  /// Whether the saved history has been read in. Until it has, nothing is written: a save
  /// then would replace the file with this session's entries. The load's merge saves them.
  @ObservationIgnored private(set) var isLoaded = false

  /// The entry the sheet has open, if it's a saved one. Stored, and kept
  /// current by `history`'s `didSet`, so the sheet reads it without scanning
  /// the history — and doesn't redraw when some other entry changes.
  private(set) var openEntry: SavedTranscript?

  init(
    apiKey: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transcriber: FileTranscriber? = nil,
    llm: TranscriptLLM? = nil,
    store: TranscriptStore = TranscriptStore(),
    recorder: (any RecordingCapture)? = nil,
    liveSession: @escaping @Sendable (String) -> any LiveTranscriptionSession = { key in
      RealtimeTranscriber.blurt(apiKey: key)
    },
    recordingsDirectory: URL = TranscriptStore.recordingsDirectory
  ) {
    self.apiKey = apiKey
    self.transcriber = transcriber ?? FileTranscriber(apiKeyProvider: apiKey)
    self.llm = llm ?? TranscriptLLM(apiKeyProvider: apiKey)
    self.recorder = recorder ?? SystemAudioRecorder()
    self.makeLiveSession = liveSession
    self.recordingsDirectory = recordingsDirectory
    // The store is read once, below, and written only through `writer`.
    self.writer = TranscriptWriter(store: store)
    self.history = []
    // Read off the main actor: the history only grows, and launch shouldn't
    // wait on decoding it. Anything saved meanwhile stays on top.
    Task { [weak self, store] in
      let loaded = await Task.detached(priority: .userInitiated) { store.load() }.value
      guard let self else {
        return
      }
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
    guard apiKey()?.isEmpty == false else {
      return
    }
    for entry in history where entry.generatedTitle == nil && entry.isTranscript && !entry.needsTranscription {
      await applyTitle(to: entry)
    }
  }

  /// Asks the LLM for `entry`'s title and saves it on the entry. Best-effort:
  /// until it comes — or if it fails — the entry keeps its file name.
  func applyTitle(to entry: SavedTranscript) async {
    guard let title = try? await llm.title(for: entry.text),
      let index = history.firstIndex(where: { $0.id == entry.id })
    else {
      return
    }
    history[index].generatedTitle = title
    save()
  }

  /// Opens a saved transcript in the sheet, with every transform already
  /// fetched for it — or transcribes one kept without a transcript.
  func open(_ entry: SavedTranscript) {
    if entry.needsTranscription {
      retranscribe(entry)
      return
    }
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
      at: 0
    )
    save()
  }

  /// Re-reads the open entry after the history changed, assigning only when
  /// it did change so observers of `openEntry` aren't woken for nothing. A
  /// deleted entry keeps its last copy, for the sheet to close over (`dismiss()`).
  private func refreshOpenEntry() {
    guard let id = openEntry?.id, let current = history.first(where: { $0.id == id }) else {
      return
    }
    if current != openEntry { openEntry = current }
  }

  /// Saves every dictation in `ring` not saved yet. The ring is the session's
  /// whole history pushed after each dictation, so its entries' ids say which
  /// are new; a dictation into a secure field never reaches it.
  func saveDictations(from ring: RecentDictations) {
    let new = ring.entries.filter { savedDictationIDs.insert($0.id).inserted }
    guard !new.isEmpty else {
      return
    }
    let entries = new.map { dictation in
      SavedTranscript(
        kind: .dictation, date: dictation.timestamp, text: dictation.text, id: dictation.id, style: dictation.style
      )
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
    case .loading, .ready:
      return

    case .failed, nil:
      fetch(facet)
    }
  }

  /// Applies a new custom request, replacing the previous custom result.
  func applyCustom(_ request: String) {
    guard let trimmed = request.trimmedNonEmpty() else {
      return
    }
    customRequest = trimmed
    tasks[.custom]?.cancel()
    contents[.custom] = nil
    select(.custom)
  }

  /// Fetches the selected facet again after a failure.
  func retry() { fetch(selection) }

  private func fetch(_ facet: TranscriptFacet) {
    guard let transform = facet.transform(custom: customRequest),
      case .ready(let transcript) = contents[.full]
    else {
      return
    }
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
      guard !Task.isCancelled, let self else {
        return
      }
      contents[facet] = content
      if case .ready(let text) = content { remember(text, for: facet, request: request) }
    }
  }

  /// Saves a fetched transform onto the open transcript's history entry.
  private func remember(_ text: String, for facet: TranscriptFacet, request: String) {
    guard let index = history.firstIndex(where: { $0.id == openEntry?.id }) else {
      return
    }
    history[index].results[facet.rawValue] = text
    if facet == .custom { history[index].customRequest = request }
    save()
  }

  // MARK: - Sheet lifecycle

  func reset(keepingTranscript: Bool = false) {
    stopReading()
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
    guard !keepingTranscript else {
      return
    }
    fullTurns = []
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
    guard isLoaded else {
      return
    }
    let snapshot = history
    pendingSave = Task { [writer] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else {
        return
      }
      writer.save(snapshot)
    }
  }
}
