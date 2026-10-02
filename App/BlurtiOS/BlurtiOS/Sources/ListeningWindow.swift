import AVFoundation
import BlurtiOSCore
import Foundation
import Observation

/// The stretch of time the app keeps the microphone open so the keyboard can
/// start a dictation without bringing the app forward — Wispr calls the same
/// thing a "Flow Session".
///
/// Opening needs the app in front (iOS refuses to start capture from the
/// background), which is why the keyboard's mic key opens `blurt://start` when
/// no window is open. Once open, `UIBackgroundModes: audio` plus the active
/// audio session keep it alive after the user swipes back. Every dictation
/// extends the window; it closes on its own after `SharedStore.windowMinutes`
/// of silence (0 means never), when the user closes it in the app, or when a
/// phone call, Siri or another app takes the microphone: the window is over
/// then, and saying so beats a mic that looks open and hears nothing.
@MainActor
@Observable
final class ListeningWindow {
  #if targetEnvironment(simulator)
    // The simulator's capture session carries no audio; see SimulatorAudioSource.
    let source: any ListeningSource = SimulatorAudioSource()
  #else
    let source: any ListeningSource = WindowedAudioSource()
  #endif
  private(set) var until: Date?
  private(set) var lastError: String?
  @ObservationIgnored private var expiry: Task<Void, Never>?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?
  @ObservationIgnored private var interruptions: Task<Void, Never>?
  /// Run when the window closes on its own — its time ran out, or iOS took
  /// the microphone — and awaited *before* the source closes: a dictation
  /// riding on the feed has to be ended by whoever owns the session while
  /// the feed still holds its audio, not left recording into a closed one.
  @ObservationIgnored var onClosingOnItsOwn: (() async -> Void)?

  var isOpen: Bool { source.isOpen && (until.map { $0 > Date() } ?? false) }

  /// Opens the microphone for `SharedStore.windowMinutes`. Foreground only.
  func open() async {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // `.mixWithOthers` so the window doesn't silence whatever the user is
      // playing for the whole time it is open; `.defaultToSpeaker` so that
      // audio doesn't drop to the earpiece while the microphone is ours; HFP
      // so AirPods can be the input.
      try audioSession.setCategory(
        .playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
      try audioSession.setActive(true)
      try await source.open()
      lastError = nil
      extend()
      startHeartbeat()
      watchInterruptions()
    } catch {
      lastError = error.localizedDescription
      await close()
    }
  }

  /// Pushes the window's end out again — called on open and after every
  /// dictation, so a window only closes on real silence.
  func extend() {
    let minutes = SharedStore.windowMinutes
    let end = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : Date.distantFuture
    until = end
    SharedStore.listeningUntil = end
    expiry?.cancel()
    guard end != .distantFuture else { return }
    expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
      guard !Task.isCancelled else { return }
      await self?.closeOnItsOwn()
    }
  }

  /// Tells the keyboard the app is alive and the microphone really is open —
  /// `SharedStore.isListening` needs both. Stops reporting the moment capture
  /// is interrupted, so the keyboard's next tap reopens the app instead of
  /// sending a press into silence.
  private func startHeartbeat() {
    heartbeat?.cancel()
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        SharedStore.appSeenAt = source.isOpen ? Date() : nil
        try? await Task.sleep(for: .seconds(SharedStore.appHeartbeatInterval))
      }
    }
  }

  /// A phone call, Siri, an alarm: iOS takes the microphone and tells us. The
  /// window closes rather than pretending; the user reopens it in Blurt.
  private func watchInterruptions() {
    interruptions?.cancel()
    interruptions = Task { [weak self] in
      let began = NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification)
        .filter { notification in
          let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
          return raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
        }
      for await _ in began {
        guard !Task.isCancelled else { return }
        await self?.closeOnItsOwn()
        return
      }
    }
  }

  /// The window ending without the user asking: the owner hears first.
  private func closeOnItsOwn() async {
    await onClosingOnItsOwn?()
    await close()
  }

  func close() async {
    expiry?.cancel()
    expiry = nil
    heartbeat?.cancel()
    heartbeat = nil
    interruptions?.cancel()
    interruptions = nil
    await source.close()
    until = nil
    SharedStore.listeningUntil = nil
    SharedStore.appSeenAt = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
