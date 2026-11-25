public import Foundation

/// The main window's "Auto-record meetings" switch: when on, a recording
/// starts as a meeting does and stops after it ends (`MeetingAutoRecord`).
///
/// **Off unless switched on** — it records the user's microphone and Mac audio
/// without a press, so it is never a default. Read-only, like the other
/// switches: the toggle binds `@AppStorage` to `defaultsKey`.
public struct MeetingAutoRecordStore {
  /// UserDefaults key holding the switch, for the toggle's `@AppStorage`.
  public static var defaultsKey: String { DefaultsKey.autoRecordMeetings.key }

  private let defaults: UserDefaults

  /// Whether meetings record themselves.
  public var isEnabled: Bool { defaults.bool(forKey: Self.defaultsKey) }

  /// A store over `defaults`; tests pass an isolated suite.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }
}
