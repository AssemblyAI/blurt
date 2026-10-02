/// Whether the app opens on its first-run setup screen or on its tabs, as in
/// the blurt-ios prototype: setup first, then the app, with the steps moving
/// into Settings once they are done.
package nonisolated enum SetupProgress {
  /// Set when the user leaves the setup screen with a key in place, so the
  /// steps they skipped (the microphone, the keyboard) don't hold the app back.
  package static let finishedKey = "SetupFinished"

  /// The setup screen shows without a key, which nothing works without, and
  /// until the user has either finished every step or chosen to start anyway.
  package static func needsSetup(hasKey: Bool, isSetUp: Bool, finished: Bool) -> Bool {
    !hasKey || (!finished && !isSetUp)
  }
}
