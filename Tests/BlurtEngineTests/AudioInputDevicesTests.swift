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
  .enabled(
    if: ProcessInfo.processInfo.environment["BLURT_LIVE_AUDIO_TESTS"] == "1",
    "set BLURT_LIVE_AUDIO_TESTS=1 to run (needs a real microphone)"),
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

  @Test("a listed UID reads as connected and classifiable; a bogus one doesn't")
  func uidLookupsAgreeWithTheEnumeration() throws {
    let first = try #require(AudioInputDevices.all().first)

    // The two questions `MicCapture.resolveInput` asks of a pin. That the first
    // holds for every enumerated device is the load-bearing part: the picker
    // must not offer a device the capture path would then treat as missing.
    #expect(AudioInputDevices.isConnected(uid: first.uid))
    #expect(
      AudioInputDevices.transportType(forUID: first.uid) != nil,
      "a connected device must classify, or it silently loses the Bluetooth caps")

    // The missing-device signal `MicDeviceSelection.effective` falls back on.
    #expect(AudioInputDevices.isConnected(uid: "blurt-test-no-such-device") == false)
    #expect(AudioInputDevices.transportType(forUID: "blurt-test-no-such-device") == nil)
  }

  @Test("building a recorder — and warming up — leaves the microphone closed")
  func buildingASessionDoesNotEngageTheDevice() async throws {
    // The measurement the warm-up design rests on, as a regression test: a built
    // but unstarted session must not open the device, or `warmUp()` at launch
    // would light the input indicator and pin AirPods into their mic-capable
    // profile (where *output* audio is degraded) for as long as the app runs.
    let device = try #require(AVCaptureDevice.default(for: .audio))
    try #require(
      Self.isRunningSomewhere(uid: device.uniqueID) == false,
      "another app is capturing from the default input — can't tell who opened it")

    let recorder = try CaptureSessionRecorder(pinnedUID: device.uniqueID)
    #expect(Self.isRunningSomewhere(uid: device.uniqueID) == false, "building must not open the device")

    await MicCapture(deviceSelection: { .systemDefault }).warmUp()
    #expect(Self.isRunningSomewhere(uid: device.uniqueID) == false, "warm-up must not open the device")

    // And the same recorder still opens it on demand, so "closed" isn't just a
    // recorder that was never usable.
    try #require(recorder.record())
    #expect(Self.isRunningSomewhere(uid: device.uniqueID), "record() is what opens the device")
    recorder.stopAndDiscard()
  }

  @Test("the session recorder captures S16LE audio from the device it was pinned to")
  func pinnedRecorderCapturesAudio() async throws {
    // Pin to the current default input — the one device a machine running this
    // suite is known to have working — by the same UID the picker would store.
    let uid = try #require(AVCaptureDevice.default(for: .audio)?.uniqueID)
    #expect(AudioInputDevices.all().contains { $0.uid == uid }, "the default input should be listed")

    let recorder = try CaptureSessionRecorder(pinnedUID: uid)
    try #require(recorder.record(), "the session recorder should start on a live device")

    // Give the session a moment to deliver, as the liveness gate would.
    try await Task.sleep(for: .milliseconds(500))
    #expect(recorder.deliveredFrames > 0, "buffers should be arriving")
    // The meter must read as a live analog input, not digital silence — this is
    // the reading `MicLiveness.silenceFloorDB` gates on, and the assertion that
    // proves the session meter's floor semantics on real hardware.
    #expect(
      recorder.meteredPowerDB() > MicLiveness.silenceFloorDB,
      "a live mic must out-read the silence floor")

    let pcm = recorder.stopAndReadPCM()
    #expect(!pcm.isEmpty, "half a second of capture should deliver samples")
    #expect(pcm.count % SyncSTTLimits.bytesPerSample == 0, "the blob must be whole S16LE samples")
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
