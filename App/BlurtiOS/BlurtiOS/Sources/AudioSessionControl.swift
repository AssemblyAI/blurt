import AVFoundation
import BlurtEngine
import BlurtiOSCore
import Foundation

/// What the system says about the audio session while a window is open, in
/// the order it happened. One reader: the window, which turns each into the
/// machine's event.
enum AudioSessionEvent: Sendable, Equatable {
  /// A call, Siri, an alarm: the session is taken.
  case interruptionBegan
  /// Given back; `shouldResume` is the system's own advice.
  case interruptionEnded(shouldResume: Bool)
  /// Media services were reset under the session: everything audio is gone.
  case mediaReset
}

/// The audio session as the listening window needs it: up with the options a
/// held microphone wants, down again, the input it prefers, and what the
/// system says about it. A protocol so `ListeningWindowTests` run against a
/// fake in the simulator; `SystemAudioSession` is the phone's.
@MainActor
protocol AudioSessionControlling: AnyObject {
  /// Category, mode and options set, haptics allowed over the recording, the
  /// session active, the preferred input applied — in that order.
  func activate() throws
  /// `setActive(false)`, other apps told. Throws during a call.
  func deactivate() throws
  /// The input the window prefers: the phone's own microphone unless Settings
  /// says AirPods. Applied after activation and again on every route change.
  func applyPreferredInput()
  var events: AsyncStream<AudioSessionEvent> { get }
}

/// `AVAudioSession` as the window runs it — the way Typeless does, read off a
/// phone log (DESIGN.md): play and record, the speaker, A2DP so music on
/// AirPods stays stereo, HFP only with the "Use AirPods mic" opt-in. Never
/// `.mixWithOthers`, and never a sound of its own to stay alive.
@MainActor
final class SystemAudioSession: AudioSessionControlling {
  private static let log = HostIdentity.current.logger("Capture")
  /// The options every session gets; `.allowBluetoothHFP` joins them with the opt-in.
  static let baseOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]

  private let session = AVAudioSession.sharedInstance()
  let events: AsyncStream<AudioSessionEvent>
  /// Registered once in `init`, removed in `deinit`, which is nonisolated:
  /// the same arrangement `WindowedAudioSource` keeps for its observers.
  nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

  init() {
    let (events, sink) = AsyncStream<AudioSessionEvent>.makeStream()
    self.events = events
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
        guard let event = Self.interruption(note.userInfo ?? [:]) else { return }
        sink.yield(event)
      },
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { _ in
        sink.yield(.mediaReset)
      },
    ]
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// The notification's type and option, as an event; nil for a type this build doesn't know.
  private nonisolated static func interruption(_ userInfo: [AnyHashable: Any]) -> AudioSessionEvent? {
    let raw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt
    switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
    case .began:
      return .interruptionBegan
    case .ended:
      let options = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt).map(
        AVAudioSession.InterruptionOptions.init(rawValue:))
      return .interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false)
    case nil:
      return nil
    @unknown default:
      return nil
    }
  }

  func activate() throws {
    var options = Self.baseOptions
    if SharedStore.airPodsMic { options.insert(.allowBluetoothHFP) }
    try session.setCategory(.playAndRecord, mode: .default, options: options)
    // Before activation, or the key clicks and the recording's own haptic
    // fall silent for the whole window.
    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    try session.setActive(true)
    applyPreferredInput()
    Self.log.notice("audio session active; airPodsMic=\(SharedStore.airPodsMic)")
  }

  func deactivate() throws {
    try session.setActive(false, options: .notifyOthersOnDeactivation)
    Self.log.notice("audio session inactive")
  }

  func applyPreferredInput() {
    // With the opt-in, the system's own choice (AirPods when they are the
    // route) stands; without it, the phone's microphone whatever is connected.
    let preferred = SharedStore.airPodsMic ? nil : session.availableInputs?.first { $0.portType == .builtInMic }
    guard SharedStore.airPodsMic || preferred != nil else { return }
    do {
      try session.setPreferredInput(preferred)
    } catch {
      Self.log.error("preferred input refused: \(error.localizedDescription, privacy: .public)")
    }
  }
}
