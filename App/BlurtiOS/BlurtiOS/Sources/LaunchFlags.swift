import BlurtEngine
import Foundation

/// The debug launch arguments that outlive the process they were given to.
///
/// `-BlurtDeveloperMode YES` and `-BlurtDeviceTrace YES` reach only the process
/// `scripts/ios-device.sh launch` starts. The keyboard's hop (`blurt://`)
/// relaunches Blurt through SpringBoard with no arguments, so the engine's
/// dictation log and the gate's trace ended at the first hop (2026-11-05: 13
/// trace lines, then a second pid writing none). Each flag's value is written
/// to standard defaults, where `DeveloperModeStore` and `DeviceTrace` already
/// read it, and holds until a launch says `NO`. Debug builds only — the
/// release build never sees the arguments or this call.
enum LaunchFlags {
  static let persisted = [DeveloperModeStore.defaultsKey, DeviceTrace.launchArgument]

  /// Writes the value of every flag the arguments carry (`-Flag YES|NO`).
  static func persist(
    _ keys: [String] = persisted, arguments: [String] = CommandLine.arguments, into defaults: UserDefaults = .standard
  ) {
    for key in keys {
      guard let value = value(of: key, in: arguments) else { continue }
      defaults.set(value, forKey: key)
    }
  }

  /// `-<key> <value>` as `UserDefaults` reads it: `YES`, `true` and `1` are on.
  static func value(of key: String, in arguments: [String]) -> Bool? {
    guard let index = arguments.firstIndex(of: "-" + key), arguments.indices.contains(index + 1) else { return nil }
    return (arguments[index + 1] as NSString).boolValue
  }
}
