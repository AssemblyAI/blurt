import Foundation

/// The main window's "Auto-record meetings" switch: when on, a recording
/// starts as a meeting does and stops after it ends (`MeetingAutoRecord`).
///
/// **Off unless switched on** — it records the user's microphone and Mac audio
/// without a press, so it is never a default. Read-only, like the other
/// switches: the toggle binds `@AppStorage` to `defaultsKey`.
public struct MeetingAutoRecordStore {
  public static var defaultsKey: String { DefaultsKey.autoRecordMeetings.key }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var isEnabled: Bool { defaults.bool(forKey: Self.defaultsKey) }
}
