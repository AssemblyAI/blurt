import AVFoundation
import Foundation

/// The audio session as the listening window needs it: up with the options a
/// held microphone wants, down again, the input it prefers, and what the
/// system says about it. A protocol so `ListeningWindowTests` run against a
/// fake in the simulator; `SystemAudioSession` is the phone's.
@MainActor
protocol AudioSessionControlling: AnyObject {
  var events: AsyncStream<AudioSessionEvent> { get }

  /// Category, mode and options set, haptics allowed over the recording, the
  /// session active, the preferred input applied — in that order.
  func activate() throws
  /// `setActive(false)`, other apps told. Throws during a call.
  func deactivate() throws
  /// The input the window prefers: the phone's own microphone unless Settings
  /// says AirPods. Applied after activation and again on every route change.
  func applyPreferredInput()
}
