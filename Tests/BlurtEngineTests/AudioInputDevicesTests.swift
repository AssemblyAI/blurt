import Foundation
import Testing

@testable import BlurtEngine

/// Live-hardware checks for the microphone-selection plumbing: the device
/// enumeration the Settings picker lists, the UID→snapshot translation the
/// capture path pins with, and the pinned AudioQueue recorder itself.
///
/// Gated on BLURT_LIVE_AUDIO_TESTS=1 like the other capture suites — every test
/// here talks to the real CoreAudio HAL (and the recorder test opens a real
/// input device), which a headless CI runner cannot answer for. Documents and
/// locks the behavior for a human running it on a Mac with a microphone;
/// `AudioInputDevices.swift` and `PinnedAudioQueueRecorder.swift` are excluded
/// from the coverage gate for the same reason `MicCapture.swift` is.
@Suite(
  "AudioInputDevices & pinned recorder (live)",
  .enabled(
    if: ProcessInfo.processInfo.environment["BLURT_LIVE_AUDIO_TESTS"] == "1",
    "set BLURT_LIVE_AUDIO_TESTS=1 to run (needs a real microphone)"),
  .tags(.liveAudio),
  .timeLimit(.minutes(1)))
struct AudioInputDevicesTests {
  @Test("enumeration lists named, uniquely-identified input devices")
  func enumerationListsInputDevices() throws {
    let devices = AudioInputDevices.all()
    try #require(!devices.isEmpty, "a machine running this suite needs at least one input device")

    // Every entry must be renderable in the picker and pinnable by the store.
    #expect(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
    #expect(Set(devices.map(\.uid)).count == devices.count, "device UIDs must be unique")

    // The default input has a name for the "Same as system (…)" label.
    #expect(AudioInputDevices.systemDefaultInputName() != nil)
  }

  @Test("a listed UID translates back to a live input snapshot; a bogus one doesn't")
  func uidTranslationRoundTrips() throws {
    let devices = AudioInputDevices.all()
    let first = try #require(devices.first)

    let snapshot = try #require(AudioInputDevices.input(forUID: first.uid))
    #expect(snapshot.deviceID != 0)

    // The missing-device signal `MicDeviceSelection.effective` falls back on.
    #expect(AudioInputDevices.input(forUID: "blurt-test-no-such-device") == nil)
  }

  @Test("the pinned recorder captures S16LE audio from the device it was built for")
  func pinnedRecorderCapturesAudio() async throws {
    // Pin to the current default input's UID — the one device a machine running
    // this suite is known to have working.
    let defaultInput = try #require(AudioRoute.currentInput())
    let device = try #require(
      AudioInputDevices.all().first {
        AudioInputDevices.input(forUID: $0.uid)?.deviceID == defaultInput.deviceID
      }, "the default input should be among the enumerated devices")

    let recorder = try PinnedAudioQueueRecorder(deviceUID: device.uid)
    try #require(recorder.record(), "the pinned recorder should start on a live device")

    // Give the queue a moment to clock and deliver, as the liveness gate would.
    try await Task.sleep(for: .milliseconds(500))
    #expect(recorder.currentTime > 0, "the queue's clock should advance while recording")

    let pcm = recorder.stopAndReadPCM()
    #expect(!pcm.isEmpty, "half a second of capture should deliver samples")
    #expect(pcm.count % SyncSTTLimits.bytesPerSample == 0, "the blob must be whole S16LE samples")
  }
}
