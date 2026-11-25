/// The media keys a command can press: what the keyboard's top row does.
public enum MediaKey: String, CaseIterable, Sendable {
  case volumeUp = "volume_up"
  case volumeDown = "volume_down"
  case mute
  case playPause = "play_pause"
  case nextTrack = "next_track"
  case previousTrack = "previous_track"
  case brightnessUp = "brightness_up"
  case brightnessDown = "brightness_down"

  /// The `NX_KEYTYPE_*` code the system-defined event carries.
  var systemKeyType: Int {
    switch self {
    case .volumeUp:
      0

    case .volumeDown:
      1

    case .mute:
      7

    case .playPause:
      16

    case .nextTrack:
      17

    case .previousTrack:
      18

    case .brightnessUp:
      2

    case .brightnessDown:
      3
    }
  }
}
