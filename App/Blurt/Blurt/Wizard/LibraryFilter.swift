import BlurtEngine

/// The Library's filter: everything, or one family of entry.
enum LibraryFilter: CaseIterable {
  case all, recordings, dictations, files, spoken

  var title: String {
    switch self {
    case .all:
      "All"

    case .recordings:
      "Recordings"

    case .dictations:
      "Dictations"

    case .files:
      "Files"

    case .spoken:
      "Spoken"
    }
  }

  var systemImage: String {
    switch self {
    case .all:
      "tray"

    case .recordings:
      LibraryKind.recording.systemImage

    case .dictations:
      LibraryKind.dictation.systemImage

    case .files:
      LibraryKind.file.systemImage

    case .spoken:
      LibraryKind.readAloud.systemImage
    }
  }

  var emptyTitle: String {
    switch self {
    case .all:
      "Nothing yet"

    case .recordings:
      "No recordings yet"

    case .dictations:
      "No dictations yet"

    case .files:
      "No files yet"

    case .spoken:
      "Nothing spoken yet"
    }
  }

  var emptyHint: String {
    switch self {
    case .all:
      ""

    case .recordings:
      "Press Record to capture a meeting or a voice memo."

    case .dictations:
      "Click a text field and press your dictation key."

    case .files:
      "Drop an audio or video file on this window."

    case .spoken:
      "Select text and press your read-aloud or ask key."
    }
  }

  func includes(_ entry: SavedTranscript) -> Bool {
    switch self {
    case .all:
      true

    case .recordings:
      entry.kind == .recording

    case .dictations:
      entry.kind == .dictation

    case .files:
      entry.kind == .file

    case .spoken:
      entry.kind == .readAloud
    }
  }
}
