import BlurtEngine

// The transcript sheet's Play: what it plays is whatever is showing. On Full,
// the entry's own audio — the read-aloud clip, the recording, the file. Any
// other tab (meeting notes, a summary…), and Full for a dictation, which keeps
// no audio, is read aloud in the user's read-aloud voice. Split from TranscriptsModel.swift for the file-length budget.
extension TranscriptsModel {
  /// Whether the showing content has something to play: Full needs audio; a
  /// task result needs its text in hand.
  var canPlayShown: Bool {
    showsOriginalAudio || selectedText != nil
  }

  /// Full, on an entry that has audio of its own: Play plays that, not a reading.
  private var showsOriginalAudio: Bool {
    selection == .full && openEntry?.hasAudio == true
  }

  /// Whether the showing content is the thing playing now.
  var isPlayingShown: Bool {
    if showsOriginalAudio {
      guard let url = openEntry?.audioURL else { return false }
      return player.playingURL == url
    }
    return readingFacet == selection
  }

  /// Plays (or stops) what's showing.
  func togglePlayShown() {
    if showsOriginalAudio {
      stopReading()
      if let entry = openEntry { togglePlayback(entry) }
      return
    }
    if readingFacet == selection {
      stopReading()
      return
    }
    guard let text = selectedText else { return }
    stopReading()
    player.stop()
    let facet = selection
    readingFacet = facet
    readingTask = Task { [weak self, reader] in
      try? await reader.read(text)
      guard !Task.isCancelled, let self, readingFacet == facet else { return }
      readingFacet = nil
    }
  }

  /// Stops a task result being read aloud. Switching chips or closing the
  /// sheet calls it, so a reading never outlives what it was reading.
  func stopReading() {
    readingTask?.cancel()
    readingTask = nil
    readingFacet = nil
  }
}
