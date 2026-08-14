import Foundation

// The input-diagnostics half of the developer-mode log: while the Custom
// trigger capture sheet is open, every event its recorder sees — accepted or
// refused — is appended to a sibling `capture-events.jsonl`. Split from
// `DictationLog.swift` (same enum, so it shares the serial queue, the encoder,
// the developer-mode gate, and `appendLine`) because it answers a different
// question again: not "what did users say" or "what broke", but "what did that
// mouse actually send" — the diagnosis for a multi-button mouse whose extra
// buttons arrive as something unexpected (or never arrive at all), which is
// invisible from the sheet's refusal text alone.
//
// A separate file for the reason `errors.jsonl` is: the other two logs' lines
// each carry their own expected shape, and interleaving input rows would break
// anything decoding them.
extension DictationLog {
  struct CaptureEventEntry: Encodable {
    let ts: String
    /// Which monitor delivered the event: `keyDown` or `otherMouseDown`.
    let kind: String
    /// What the recorder did with it — a stable token to aggregate on:
    /// `captured`, `refused-button`, `refused-keyboard-key`, or `cancelled`.
    let outcome: String
    /// `CGEvent`/`NSEvent` button number, for mouse events (0 = left).
    let button: Int?
    /// macOS virtual keycode, for keyboard events.
    let keyCode: Int?
    /// The event's raw modifier flags. Recorded even when no decision reads
    /// them: a mouse driver that ships clicks with phantom flags is exactly the
    /// kind of misbehavior this log exists to catch.
    let flags: UInt64
    /// Whether a keyboard event was an autorepeat delivery.
    let isRepeat: Bool
    /// The bound trigger's label ("Mouse 4") when `outcome` is `captured`.
    let binding: String?

    /// Spelled out for the reason `Entry.CodingKeys` is: a hand-written
    /// `encode(to:)` means the key names are the on-disk contract, so they're
    /// stated rather than left to a synthesis that no longer happens.
    enum CodingKeys: String, CodingKey {
      case ts, kind, outcome, button, keyCode, flags, binding
      case isRepeat = "repeat"
    }

    /// Hand-written so absent facts are omitted rather than written as `null`
    /// (matching the other two logs), and so the two always-meaningless-when-
    /// default fields (`flags` 0, `repeat` false) don't pad every line of a log
    /// meant to be eyeballed.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(ts, forKey: .ts)
      try container.encode(kind, forKey: .kind)
      try container.encode(outcome, forKey: .outcome)
      try container.encodeIfPresent(button, forKey: .button)
      try container.encodeIfPresent(keyCode, forKey: .keyCode)
      if flags != 0 {
        try container.encode(flags, forKey: .flags)
      }
      if isRepeat {
        try container.encode(true, forKey: .isRepeat)
      }
      try container.encodeIfPresent(binding, forKey: .binding)
    }
  }

  /// Where capture-sheet input events land. Sibling of `defaultURL` in the same
  /// directory, so the one "delete my logs" gesture covers all three files.
  static let defaultCaptureURL = URL.libraryDirectory.appending(
    path: "Logs/Blurt/capture-events.jsonl")

  /// `defaultCaptureURL` as a home-abbreviated path, for the Developer section's
  /// footer — derived here next to the URL the writer uses, for the same reason
  /// as `defaultDisplayPath`: the displayed path can't drift from the write
  /// target.
  public static var defaultCaptureDisplayPath: String {
    (defaultCaptureURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  /// Append one capture-sheet input event. **Gated on developer mode**, so with
  /// the switch off (the default) this returns without touching the disk and the
  /// capture sheet can invoke it unconditionally for every event it sees. The
  /// file I/O is dispatched onto `queue`, off the event-monitor callback.
  ///
  /// Public because the caller is the app's capture sheet — unlike the other two
  /// logs, whose writers live inside the engine. The real store and destination
  /// are supplied in the body rather than as defaulted parameters: a public
  /// function's default arguments may only reference public declarations, and
  /// neither `DeveloperModeStore.init` nor `defaultCaptureURL` has a reason to
  /// be public. Tests inject both through the internal overload below.
  public static func appendCaptureEvent(
    kind: String, outcome: String,
    button: Int? = nil, keyCode: Int? = nil,
    flags: UInt64 = 0, isRepeat: Bool = false, binding: String? = nil
  ) {
    appendCaptureEvent(
      kind: kind, outcome: outcome, button: button, keyCode: keyCode,
      flags: flags, isRepeat: isRepeat, binding: binding,
      store: DeveloperModeStore(), to: defaultCaptureURL)
  }

  /// The injectable overload behind the public entry point: `store` and `url`
  /// exist to be overridden by tests, exactly as on `append`/`appendError` —
  /// with both hard-coded, the gate could only be exercised by writing to the
  /// real `~/Library/Logs`.
  static func appendCaptureEvent(
    kind: String, outcome: String,
    button: Int? = nil, keyCode: Int? = nil,
    flags: UInt64 = 0, isRepeat: Bool = false, binding: String? = nil,
    store: DeveloperModeStore, to url: URL
  ) {
    gated(store: store) { now in
      writeCaptureEvent(
        kind: kind, outcome: outcome, button: button, keyCode: keyCode,
        flags: flags, isRepeat: isRepeat, binding: binding, to: url, now: now)
    }
  }

  /// One capture entry as a value, split from `writeCaptureEvent` for the same
  /// reason as `makeEntry`/`makeErrorEntry`: what a row carries is assertable
  /// directly rather than through a temp file and a substring search.
  static func makeCaptureEntry(
    kind: String, outcome: String, button: Int?, keyCode: Int?,
    flags: UInt64, isRepeat: Bool, binding: String?, now: Date
  ) -> CaptureEventEntry {
    CaptureEventEntry(
      ts: now.formatted(timestampFormat), kind: kind, outcome: outcome,
      button: button, keyCode: keyCode, flags: flags, isRepeat: isRepeat, binding: binding)
  }

  /// The unconditional writer, named distinctly from `appendCaptureEvent` for
  /// the reason `write`/`writeError` are: the gated entry point above must not
  /// be bypassable by accidentally satisfying a different signature.
  static func writeCaptureEvent(
    kind: String, outcome: String, button: Int? = nil, keyCode: Int? = nil,
    flags: UInt64 = 0, isRepeat: Bool = false, binding: String? = nil,
    to url: URL, now: Date
  ) {
    appendLine(
      makeCaptureEntry(
        kind: kind, outcome: outcome, button: button, keyCode: keyCode,
        flags: flags, isRepeat: isRepeat, binding: binding, now: now),
      to: url)
  }
}
