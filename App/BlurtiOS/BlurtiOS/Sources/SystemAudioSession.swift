import AVFoundation
import BlurtEngine
import BlurtiOSCore
import Foundation

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
  /// Where "Use AirPods mic" is read from, each time the session is set up.
  private let store: SharedStore
  let events: AsyncStream<AudioSessionEvent>
  /// Registered once in `init`, removed in `deinit`, which is nonisolated:
  /// the same arrangement `WindowedAudioSource` keeps for its observers.
  nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

  init(store: SharedStore) {
    self.store = store
    let (stream, sink) = AsyncStream<AudioSessionEvent>.makeStream()
    self.events = stream
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
        guard let event = Self.interruption(note.userInfo ?? [:]) else {
          return
        }
        sink.yield(event)
      },
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { _ in
        sink.yield(.mediaReset)
      },
    ]
  }

  /// The notification's type and option, as an event; nil for a type this build doesn't know.
  nonisolated private static func interruption(_ userInfo: [AnyHashable: Any]) -> AudioSessionEvent? {
    let raw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt
    switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
    case .began:
      return .interruptionBegan

    case .ended:
      let options = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt).map(
        AVAudioSession.InterruptionOptions.init(rawValue:)
      )
      return .interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false)

    case nil:
      return nil

    @unknown default:
      return nil
    }
  }

  func activate() throws {
    var options = Self.baseOptions
    if store.airPodsMic { options.insert(.allowBluetoothHFP) }
    try session.setCategory(.playAndRecord, mode: .default, options: options)
    // Before activation, or the key clicks and the recording's own haptic
    // fall silent for the whole window.
    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    try session.setActive(true)
    applyPreferredInput()
    Self.log.notice("audio session active; airPodsMic=\(store.airPodsMic)")
  }

  func deactivate() throws {
    try session.setActive(false, options: .notifyOthersOnDeactivation)
    Self.log.notice("audio session inactive")
  }

  func applyPreferredInput() {
    // With the opt-in, the system's own choice (AirPods when they are the
    // route) stands; without it, the phone's microphone whatever is connected.
    let preferred = store.airPodsMic ? nil : session.availableInputs?.first { $0.portType == .builtInMic }
    guard store.airPodsMic || preferred != nil else {
      return
    }
    do {
      try session.setPreferredInput(preferred)
    } catch {
      Self.log.error("preferred input refused: \(error.localizedDescription, privacy: .public)")
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
}
