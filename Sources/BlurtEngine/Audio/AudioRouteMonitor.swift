import CoreAudio
import Foundation
import os

/// Ticks whenever the system's audio **output** route changes in a way that
/// invalidates an already-pre-rolled `AVAudioPlayer`.
///
/// This exists for the record cue chimes. `CueSoundPlayer` decodes and
/// `prepareToPlay()`s them once at launch so the first chime never stalls the
/// pill — but that pre-roll is bound to the output route it was made against,
/// and Blurt's own capture is what invalidates it: opening the mic flips AirPods
/// out of their output-only profile into the bidirectional one, which drops the
/// output format underneath the primed players. The first chime after such a
/// flip is exactly the one that stalls, which is the chime at the start of a
/// dictation.
///
/// Two properties are watched, because "the route changed" has two shapes:
///
/// - `kAudioHardwarePropertyDefaultOutputDevice` on the system object — the user
///   switched output devices (built-in speakers → AirPods).
/// - `kAudioDevicePropertyNominalSampleRate` on whichever device is *currently*
///   default — the same device renegotiated its format, which is what the
///   profile flip looks like from CoreAudio. That listener is re-targeted
///   whenever the first one fires, so it always tracks the live device.
///
/// Public because the app owns the cue players; the engine's own use of
/// CoreAudio routing (`AudioRoute`) stays internal.
///
/// `@unchecked Sendable` because the listener registrations below are confined
/// to `queue` rather than protected by a lock — see their declarations.
public final class AudioRouteMonitor: @unchecked Sendable {
  private static let logger = Logger(subsystem: BlurtIdentity.subsystem, category: "AudioRoute")

  /// Fires once per observed route change. `.bufferingNewest(1)` because this is
  /// an invalidation signal, not a log: a consumer that was busy through three
  /// changes needs to re-prime once, not three times.
  public let outputRouteChanges: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  /// The queue CoreAudio delivers every listener callback on, and the one place
  /// the registrations below are touched. Serial, so a re-target triggered by a
  /// default-device change can't interleave with itself.
  private let queue: DispatchQueue

  /// The registered listener blocks, kept so they can be handed back to
  /// CoreAudio — removal matches on block identity, so a re-created block would
  /// deregister nothing.
  ///
  /// `nonisolated(unsafe)` rather than lock-guarded: every read and write happens
  /// inside a `queue` block, including the initial registration (`init` wraps it
  /// in `queue.sync` precisely so a listener can't fire before the property
  /// recording it has been written). Dispatch's serial ordering supplies both the
  /// exclusion and the memory barriers a lock would.
  private nonisolated(unsafe) var systemListener: AudioObjectPropertyListenerBlock?
  private nonisolated(unsafe) var deviceListener:
    (id: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

  public init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.outputRouteChanges = stream
    self.continuation = continuation
    self.queue = DispatchQueue(label: "\(BlurtIdentity.subsystem).AudioRoute")
    queue.sync {
      installDefaultDeviceListener()
      retargetFormatListener()
    }
  }

  /// The monitor is owned for the app's lifetime, so this never runs in
  /// practice — but deregistering mirrors the `[weak self]` care below and
  /// documents that the CoreAudio registrations are owned rather than leaked: a
  /// listener left behind outlives the monitor, since CoreAudio retains the block
  /// and nothing else would ever hand it back.
  ///
  /// The `queue.sync` cannot deadlock: the listener blocks hold `self` weakly, so
  /// `queue` never owns the last reference and this deinit never runs on it.
  deinit {
    continuation.finish()
    queue.sync {
      if let systemListener {
        var address = Self.defaultOutputDeviceAddress
        _ = AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &address, queue, systemListener)
      }
      if let deviceListener {
        var address = Self.sampleRateAddress
        _ = AudioObjectRemovePropertyListenerBlock(
          deviceListener.id, &address, queue, deviceListener.block)
      }
      systemListener = nil
      deviceListener = nil
    }
  }

  // MARK: - Registration (queue-confined)

  /// Watches for the default output device itself changing. Registered once and
  /// never re-targeted — the system object is always there.
  private func installDefaultDeviceListener() {
    var address = Self.defaultOutputDeviceAddress
    // `[weak self]`, so CoreAudio's strong hold on the block doesn't keep the
    // monitor alive forever — and so a callback landing during teardown finds
    // nil rather than a half-destroyed object.
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      // Re-target first, then publish: a consumer that re-primes on this tick
      // should already be behind a listener pointed at the new device.
      self.retargetFormatListener()
      self.continuation.yield()
    }
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    guard status == noErr else {
      Self.logger.error("default-output listener failed: \(status)")
      return
    }
    systemListener = block
  }

  /// Points the format listener at the current default output device, removing
  /// the one on the previous device. A no-op when the device hasn't actually
  /// changed, so a notification that resolves to the same device doesn't churn
  /// the registration.
  private func retargetFormatListener() {
    let device = AudioRoute.defaultOutputDeviceID()
    if let existing = deviceListener {
      guard existing.id != device else { return }
      var address = Self.sampleRateAddress
      _ = AudioObjectRemovePropertyListenerBlock(existing.id, &address, queue, existing.block)
      deviceListener = nil
    }
    guard let device else { return }
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.continuation.yield()
    }
    var address = Self.sampleRateAddress
    let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
    guard status == noErr else {
      Self.logger.error("output-format listener failed: \(status)")
      return
    }
    deviceListener = (id: device, block: block)
  }

  // MARK: - Property addresses

  // Computed, not stored: each caller needs its own mutable copy to pass `inout`
  // to CoreAudio anyway, so a shared constant would only add a global whose
  // `Sendable`-ness depends on how the C struct imports.

  private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private static var sampleRateAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
}
