import CoreFoundation

/// The decisions behind acting on an element — when a press falls back to a
/// click, when a focused field's contents are selected, which menu item a
/// path names, putting the pointer back — apart from the Accessibility calls
/// that carry them out, which the shell (`SystemVoiceCommandPerformer+Screen`,
/// `+Accessibility`) passes in. Each answers the note the command log keeps
/// for the step (`StepRecord.how`).
enum ElementActions {
  /// An Accessibility action — `AXPress`, or setting `AXSelected` — then a
  /// click when the element refuses it, or, given a `fingerprint` to check
  /// by, takes it and nothing a working action would change did
  /// (`PressFingerprint`). With no fingerprint a success is the whole step:
  /// the check exists for Chromium and Electron, whose web content answers
  /// success for a press it ignored, and in a native app it double-pressed
  /// every control that changes nothing it reads — Calculator's keys went in
  /// twice (2026-11-04). The destructive guard is the caller's, first.
  static func press(
    _ action: String = "AXPress", fingerprint: (() -> PressFingerprint)?, press: () -> Bool,
    settle: () async throws -> Void, click: () async throws -> Void
  ) async throws -> String {
    let before = fingerprint?()
    guard press() else {
      try await click()
      return "click: \(action) refused"
    }
    guard let before, let fingerprint else { return action }
    try await settle()
    guard !fingerprint().changed(since: before) else { return action }
    try await click()
    return "\(action), then click: nothing visibly changed"
  }

  /// Focus, checked: a click when the field didn't take it; then a single-line
  /// field's contents selected, only once it's confirmed focused — a selection
  /// lands wherever the cursor is. `setFocus` sets the attribute and gives the
  /// app its beat to move the cursor.
  static func focus(
    singleLine: Bool, setFocus: () async throws -> Void, isFocused: () -> Bool,
    click: () async throws -> Void, selectAll: () -> String
  ) async throws -> String {
    try await setFocus()
    var how = "AX focus"
    if !isFocused() {
      try await click()
      how = "click: AX focus not taken"
    }
    guard singleLine else { return how + "; a text area keeps its cursor" }
    guard isFocused() else { return how + "; still not focused, nothing selected" }
    return how + "; " + selectAll()
  }

  /// The menu item at `path`, from the menu bar down: each title matched
  /// loosely (`NameMatch`) among the entries of the item before — a bar
  /// item's or submenu's entries sit inside its one menu child, which
  /// `entries` unwraps. Refused at the first title that marks it as destructive.
  static func menuItem<Node>(
    _ path: [String], from bar: Node, entries: (Node) -> [Node], title: (Node) -> String?
  ) throws -> Node {
    var item = bar
    for name in path {
      let titled = entries(item).compactMap { entry in title(entry).map { (title: $0, entry: entry) } }
      guard let match = NameMatch.best(for: name, among: titled.map(\.title)),
        let next = titled.first(where: { $0.title == match })?.entry
      else { throw VoiceCommandError.menuItemNotFound(path) }
      guard !DestructiveGuard.isDestructive(label: match) else {
        throw VoiceCommandError.refused("choose \(path.joined(separator: " › "))")
      }
      item = next
    }
    return item
  }

  /// Runs `body` with the pointer at `point`, a beat for the app to take the
  /// event, then the pointer back `home` — however it ends: a click that
  /// throws, or a command cancelled during the beat, leaves it where it was.
  static func withPointer(
    at point: CGPoint, home: CGPoint?, warp: (CGPoint) -> Void, beat: () async throws -> Void,
    _ body: () throws -> Void
  ) async throws {
    warp(point)
    defer { if let home { warp(home) } }
    try body()
    try await beat()
  }
}
