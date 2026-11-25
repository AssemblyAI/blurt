import BlurtEngine

// Pieces of the ready screen's Library.

/// What a Library entry is, as the window draws it — the one table of each
/// kind's name and glyph, read by the Library's rows and its filter. An answer
/// is its own kind here, though the store files it as a read-aloud with a
/// request.
enum LibraryKind {
  case recording, dictation, file, readAloud, ask

  var name: String {
    switch self {
    case .recording:
      "Recording"

    case .dictation:
      "Dictation"

    case .file:
      "File"

    case .readAloud:
      KeyActionName.readAloud

    case .ask:
      KeyActionName.ask
    }
  }

  var systemImage: String {
    switch self {
    case .recording:
      "mic"

    case .dictation:
      "text.alignleft"

    case .file:
      "doc"

    case .readAloud:
      "speaker.wave.2"

    case .ask:
      "questionmark.bubble"
    }
  }

  init(_ entry: SavedTranscript) {
    switch entry.kind {
    case .recording:
      self = .recording

    case .dictation:
      self = .dictation

    case .file:
      self = .file

    case .readAloud:
      self = entry.request == nil ? .readAloud : .ask
    }
  }
}
