import AVFoundation
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
/// of silence (0 means never), or when the user closes it in the app.
@MainActor
@Observable
final class ListeningWindow {
  let source = WindowedAudioSource()
  private(set) var until: Date?
  private(set) var lastError: String?
  @ObservationIgnored private var expiry: Task<Void, Never>?

  var isOpen: Bool { source.isOpen && (until.map { $0 > Date() } ?? false) }

  /// Opens the microphone for `SharedStore.windowMinutes`. Foreground only.
  func open() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // `.mixWithOthers` so the window doesn't silence whatever the user is
      // playing for the whole time it is open; `.defaultToSpeaker` so that
      // audio doesn't drop to the earpiece while the microphone is ours; HFP
      // so AirPods can be the input.
      try audioSession.setCategory(
        .playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
      try audioSession.setActive(true)
      try source.open()
      lastError = nil
      extend()
    } catch {
      lastError = error.localizedDescription
      close()
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
      self?.close()
    }
  }

  func close() {
    expiry?.cancel()
    expiry = nil
    source.close()
    until = nil
    SharedStore.listeningUntil = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
