import Foundation
import Synchronization
import Testing

extension Tag {
  /// Marks tests that drive a real `AVCaptureSession` and the system mic. They
  /// only run when BLURT_LIVE_AUDIO_TESTS=1; the tag lets a run include/exclude
  /// them as a group (e.g. `--filter-tag liveAudio`).
  @Tag static var liveAudio: Self
}

extension ConditionTrait {
  /// The BLURT_LIVE_AUDIO_TESTS gate, in one place. Three suites need it, and it
  /// was three copies of the same condition *and* the same skip message — a
  /// rename of the variable was a three-file edit with nothing to catch a miss.
  ///
  /// `.enabled(if:)` rather than an in-body `guard … else { return }` so a normal
  /// run reports these as *skipped* instead of a silent pass: the skip is
  /// visible, and no one mistakes "didn't run" for "passed".
  static var requiresLiveAudio: Self {
    .enabled(
      if: ProcessInfo.processInfo.environment["BLURT_LIVE_AUDIO_TESTS"] == "1",
      "set BLURT_LIVE_AUDIO_TESTS=1 to run (needs a real microphone)")
  }
}

/// Exclusive use of the system microphone, across suites.
///
/// `.serialized` orders tests *within* a suite, and the live suites are separate
/// suites — so they run concurrently, and three of them open the input device.
/// Mostly that is harmless (CoreAudio allows several clients on one input), but
/// `AudioInputDevicesTests` asserts on `kAudioDevicePropertyDeviceIsRunningSomewhere`,
/// which answers for the *device* rather than for our client: another suite's
/// capture reads exactly like a failure of "building must not open the device".
/// It failed that way on two runs out of two before this existed.
///
/// Not an `actor`: the bodies these tests want to protect capture non-`Sendable`
/// AVFoundation objects, so a `withLock`-style async closure would fight strict
/// concurrency for no benefit. Acquire/release around the hardware section
/// instead — the callers are a handful of tests, and `defer` keeps it honest.
enum LiveAudioDevice {
  private static let held = Mutex(false)

  /// Waits until no other live test holds the microphone, then claims it.
  static func acquire() async {
    while !held.withLock({ claimed -> Bool in
      guard !claimed else { return false }
      claimed = true
      return true
    }) {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  static func release() {
    held.withLock { $0 = false }
  }
}
