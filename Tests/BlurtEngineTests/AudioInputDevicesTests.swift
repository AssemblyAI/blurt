@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import BlurtEngine

/// Live-hardware checks for the microphone-selection plumbing: the device
/// enumeration the Settings picker lists, the UID lookups the capture path
/// resolves a pin with, and the session recorder itself.
///
/// Gated on BLURT_LIVE_AUDIO_TESTS=1 like the other capture suites — every test
/// here talks to real devices (and two of them open one), which a headless CI
/// runner cannot answer for. Documents and locks the behavior for a human
/// running it on a Mac with a microphone; `AudioInputDevices.swift` and
/// `CaptureSessionRecorder.swift` are excluded from the coverage gate for the
/// same reason `MicCapture.swift` is.
@Suite(
  "AudioInputDevices & capture session (live)",
  ConditionTrait.requiresLiveAudio,
  .tags(.liveAudio),
  // Serialized: three of these open the default input, and the engagement test
  // reads whether *anyone* has it open. Run in parallel they'd flag each other.
  .serialized,
  .timeLimit(.minutes(1)))
struct AudioInputDevicesTests {
  @Test("enumeration lists named, uniquely-identified input devices")
  func enumerationListsInputDevices() throws {
    let devices = AudioInputDevices.all()
    try #require(!devices.isEmpty, "a machine running this suite needs at least one input device")

    // Every entry must be renderable in the picker and pinnable by the store.
    // Closures rather than key paths inside the macros — the rethrows + key-path
    // combination is the documented `#expect` trap (see AGENTS.md's testing notes).
    #expect(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
    let uids = devices.map { $0.uid }
    #expect(Set(uids).count == uids.count, "device UIDs must be unique")

    // The default input has a name for the "Same as system (…)" label.
    #expect(AudioInputDevices.systemDefaultInputName() != nil)
  }

  @Test("a listed UID classifies; a bogus one reads as absent")
  func uidLookupsAgreeWithTheEnumeration() throws {
    let first = try #require(AudioInputDevices.all().first)

    // One read answers both questions `MicCapture.resolveInput` asks of a pin —
    // is the device there, and what transport is it on. That it holds for every
    // enumerated device is the load-bearing part: the picker must not offer a
    // device the capture path would then treat as missing (or fail to classify,
    // which silently loses the Bluetooth caps).
    #expect(AudioInputDevices.transportType(forUID: first.uid) != nil)

    // The missing-device signal `MicDeviceSelection.effective` falls back on.
    #expect(AudioInputDevices.transportType(forUID: "blurt-test-no-such-device") == nil)
  }

  @Test("building a recorder — and warming up — leaves the microphone closed")
  func buildingASessionDoesNotEngageTheDevice() async throws {
    await LiveAudioDevice.acquire()
    defer { LiveAudioDevice.release() }

    // The measurement the warm-up design rests on, as a regression test: a built
    // but unstarted session must not open the device, or `warmUp()` at launch
    // would light the input indicator and pin AirPods into their mic-capable
    // profile (where *output* audio is degraded) for as long as the app runs.
    let device = try #require(AVCaptureDevice.default(for: .audio))
    // Wait for the device to be free rather than demanding it already is: this
    // suite is `.serialized`, but the other live suites are separate suites and
    // run in parallel with it, and two of them open this same device. Polling
    // makes the precondition deterministic instead of dependent on which suite
    // got there first; a device that never frees up is a real failure with a
    // message that says so.
    try #require(
      await Self.poll(upTo: .seconds(3)) { Self.isRunningSomewhere(uid: device.uniqueID) == false },
      "the default input stayed busy — another app (or suite) is capturing from it")

    let recorder = try await CaptureSessionRecorder.make(pinnedUID: device.uniqueID)
    #expect(Self.isRunningSomewhere(uid: device.uniqueID) == false, "building must not open the device")

    await MicCapture(deviceSelection: { .systemDefault }).warmUp()
    #expect(Self.isRunningSomewhere(uid: device.uniqueID) == false, "warm-up must not open the device")

    // And the same recorder still opens it on demand, so "closed" isn't just a
    // recorder that was never usable.
    //
    // Polled rather than asserted outright, because when the open *completes*
    // is transport-dependent — the measurement that shaped the liveness gate.
    // On a USB interface `startRunning()` blocks until the device is running, so
    // this holds the instant `record()` returns; on AirPods it returns in ~80 ms
    // and the device comes up ~400 ms later. Asserting immediately passes on
    // wired hardware and fails on the transport the gate exists for.
    try #require(await recorder.record())
    #expect(
      await Self.waitForRunning(uid: device.uniqueID),
      "record() is what opens the device, even if the link finishes opening it later")
    recorder.stopAndDiscard()
  }

  @Test("the session recorder captures S16LE audio from the device it was pinned to")
  func pinnedRecorderCapturesAudio() async throws {
    await LiveAudioDevice.acquire()
    defer { LiveAudioDevice.release() }

    // Pin to the current default input — the one device a machine running this
    // suite is known to have working — by the same UID the picker would store.
    let uid = try #require(AVCaptureDevice.default(for: .audio)?.uniqueID)
    #expect(AudioInputDevices.all().contains { $0.uid == uid }, "the default input should be listed")

    let recorder = try await CaptureSessionRecorder.make(pinnedUID: uid)
    try #require(await recorder.record(), "the session recorder should start on a live device")

    // Wait for frames the way the liveness gate does, rather than sleeping a
    // fixed 500 ms: on AirPods the first buffer lands ~490 ms after
    // `startRunning()` returns, so a fixed sleep sits right on the edge and this
    // suite would flake on a cold link.
    try #require(
      await Self.poll(upTo: MicLiveness.bluetoothTimeout) { recorder.deliveredFrames > 0 },
      "buffers should be arriving")
    // The meter must read as a live analog input, not digital silence — this is
    // the reading `MicLiveness.silenceFloorDB` gates on, and the assertion that
    // proves the session meter's floor semantics on real hardware.
    //
    // Polled for the same reason the frame wait is, and this is the sharper
    // case: the channel's power lags the first frames, reporting
    // `-Float.greatestFiniteMagnitude` until its first update (measured on
    // AirPods). That is exactly why the gate polls *both* terms instead of
    // metering once frames appear.
    #expect(
      await Self.poll(upTo: MicLiveness.bluetoothTimeout) {
        recorder.meteredPowerDB() > MicLiveness.silenceFloorDB
      }, "a live mic must out-read the silence floor")

    let pcm = recorder.stopAndReadPCM()
    #expect(!pcm.isEmpty, "half a second of capture should deliver samples")
    #expect(pcm.count % SyncSTTLimits.bytesPerSample == 0, "the blob must be whole S16LE samples")
  }

  /// Polls `condition` on a short tick until it holds or `timeout` elapses,
  /// answering whether it ever held. The suite's own miniature of
  /// `MicLiveness.waitUntilLive`, for the same reason that exists: nothing about
  /// a capture device is synchronous just because the call that started it
  /// returned.
  private static func poll(
    upTo timeout: Duration, _ condition: @Sendable () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while ContinuousClock().now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  /// Whether the device carrying `uid` comes up as capturing within the
  /// Bluetooth cap — the widest the product itself ever waits.
  private static func waitForRunning(uid: String) async -> Bool {
    await poll(upTo: MicLiveness.bluetoothTimeout) { isRunningSomewhere(uid: uid) }
  }

  /// CoreAudio's own answer to "is this device capturing right now" — the bit
  /// behind the system input indicator. Test-local rather than a production
  /// helper: nothing in the app needs to ask, and the point of the assertions
  /// above is to check the *device*, not our bookkeeping about it.
  private static func isRunningSomewhere(uid: String) -> Bool {
    var translate = AudioRoute.globalAddress(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var deviceID = AudioDeviceID(0)
    var idSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let translated = withUnsafeMutablePointer(to: &cfUID) { qualifier in
      AudioObjectGetPropertyData(
        AudioRoute.systemObject, &translate, UInt32(MemoryLayout<CFString>.size), qualifier,
        &idSize, &deviceID)
    }
    guard translated == noErr, deviceID != 0 else { return false }

    var address = AudioRoute.globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var running = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else {
      return false
    }
    return running != 0
  }
}
