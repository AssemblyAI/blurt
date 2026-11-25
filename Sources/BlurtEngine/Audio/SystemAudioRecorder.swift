#if os(macOS)
  public import AVFoundation
  import CoreAudio
  public import Foundation
  import os

  /// Records the microphone **and** the Mac's system audio together, mixed to
  /// mono at 16 kHz — the main window's Record button. Always both: a call
  /// recorded from the mic alone loses the other side, and from system audio
  /// alone loses the user. The mix goes two ways at once: to an AAC file, the
  /// recording kept with its transcript, and to `onPCM` as 16-bit PCM, which
  /// the live transcription streams.
  ///
  /// **Not the dictation capture path.** Dictation records through `MicCapture`'s
  /// fresh-per-press `AVCaptureSession`; this is a separate recorder with
  /// nothing in common with it — no `AVAudioEngine`, nothing kept warm, and a
  /// fresh tap and aggregate device per recording.
  ///
  /// How: a Core Audio process tap on everything the system plays (Blurt's own
  /// cue sounds excluded) joined to the input device — the microphone pinned
  /// in Settings, else the default input, as dictation resolves it — in a
  /// private aggregate device. The **input device is the aggregate's only
  /// sub-device and its clock**, with the tap drift-compensated against it — so a
  /// headset whose mic and speaker are one device isn't added twice, an output
  /// interface's own inputs never reach the mix, and switching the output
  /// mid-recording doesn't pull the clock away. One IOProc delivers both
  /// streams in the same cycle; each is averaged to mono, the two summed and
  /// clamped, then converted to 16 kHz. The first recording asks for the
  /// System Audio Recording permission (`NSAudioCaptureUsageDescription`);
  /// refused, the tap delivers silence and the microphone still records.
  ///
  /// `@safe`: the IOProc ID it stores is a raw Core Audio handle, but it is
  /// created, run and destroyed entirely inside this class, never handed out.
  @safe
  public final class SystemAudioRecorder: RecordingCapture {
    public enum RecorderError: Error, LocalizedError {
      case coreAudio(String, OSStatus)

      public var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status):
          "Couldn't start recording (\(step), error \(status))."
        }
      }
    }

    /// The rate everything leaves at: dictation's 16 kHz, which is what a live
    /// session takes too (AssemblyAI's realtime API), and plenty for speech.
    public static let outputSampleRate = Double(RecordingLimits.sampleRate)
    static let log = HostIdentity.current.logger("Recorder")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: MixWriter?
    private let queue = DispatchQueue(label: "Blurt.SystemAudioRecorder")

    /// An idle recorder: nothing is created until `start`.
    public init() {
      // Nothing to set up: the tap and aggregate device are built by `start`.
    }

    /// Starts recording to `url` (an `.m4a`), handing each slice of the 16 kHz
    /// mix to `onPCM` as S16LE bytes, on the recorder's queue. Throws — with
    /// everything it created torn down, the empty file included — if any Core
    /// Audio step fails.
    @preconcurrency
    public func start(to url: URL, onPCM: @escaping @Sendable (Data) -> Void) throws {
      do {
        try createTap()
        try createAggregate()
        let rate = try nominalSampleRate(of: aggregateID)
        let frames = try bufferFrameSize(of: aggregateID)
        Self.log.notice(
          "recorder starting: aggregate \(self.aggregateID, privacy: .public) at \(rate, privacy: .public) Hz, \(frames, privacy: .public)-frame buffers"
        )
        let mixWriter = try MixWriter(url: url, inputRate: rate, maxFrames: Int(frames), onPCM: onPCM)
        self.writer = mixWriter
        var proc: AudioDeviceIOProcID?
        try unsafe check(
          "IOProc",
          AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, _, _ in
            unsafe mixWriter.write(input)
          }
        )
        unsafe procID = unsafe proc
        unsafe try check("start", AudioDeviceStart(aggregateID, proc))
        Self.log.notice("recorder started")
      } catch {
        Self.log.error("recorder failed to start: \(error.localizedDescription, privacy: .public)")
        teardown()
        try? FileManager.default.removeItem(at: url)
        throw error
      }
    }

    /// Pauses capture: the device's IO stops — so the microphone is released
    /// and its indicator goes out — while the tap, the aggregate and the file
    /// stay, for `resume` to carry on into.
    public func pause() {
      guard let runningID = unsafe procID else {
        return
      }
      unsafe AudioDeviceStop(aggregateID, runningID)
      Self.log.notice("recorder paused")
    }

    /// Resumes capture into the same file after `pause`.
    public func resume() throws {
      guard let runningID = unsafe procID else {
        return
      }
      unsafe try check("resume", AudioDeviceStart(aggregateID, runningID))
      Self.log.notice("recorder resumed")
    }

    /// Stops recording and closes the file. Safe to call when not recording.
    public func stop() {
      teardown()
    }

    private func teardown() {
      if let runningID = unsafe procID {
        unsafe AudioDeviceStop(aggregateID, runningID)
        unsafe AudioDeviceDestroyIOProcID(aggregateID, runningID)
        unsafe self.procID = nil
      }
      // Every callback already queued has run once this returns, so the file
      // closes after its last write. The summary is read here too, not before
      // the IOProc stops: `MixWriter` is confined to `queue`, and its counters
      // are written by every callback.
      queue.sync {
        guard let writer else {
          return
        }
        Self.log.notice("recorder stopping: \(writer.summary, privacy: .public)")
        writer.close()
      }
      writer = nil
      if aggregateID != kAudioObjectUnknown {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
      }
      if tapID != kAudioObjectUnknown {
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
      }
    }

    // MARK: - Core Audio setup

    private func createTap() throws {
      let excluded = ownProcessObject().map { [$0] } ?? []
      let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
      tapUUID = UUID()
      description.uuid = tapUUID
      description.isPrivate = true
      description.muteBehavior = .unmuted
      try unsafe check("tap", AudioHardwareCreateProcessTap(description, &tapID))
    }

    private func createAggregate() throws {
      // The microphone Settings picked, the same pin dictation records from,
      // and — when none is pinned or the pinned one isn't connected — the
      // system default input, the same fallback dictation takes. One spelling
      // of each (`MicDeviceStore`, `AudioInputDevices`).
      let pinned = MicDeviceStore().selection.pinnedUID.flatMap(AudioInputDevices.device(forUID:))
      guard let input = (pinned ?? AudioInputDevices.systemDefaultDevice)?.uniqueID else {
        throw RecorderError.coreAudio("input device", kAudioHardwareUnspecifiedError)
      }
      let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Blurt Recorder",
        kAudioAggregateDeviceUIDKey: "Blurt.Recorder.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: input,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        // Off, so the input device's clock alone drives the IO cycle. On, the
        // aggregate's IO waits on the tap, and a tap only produces while the
        // output device is running: with nothing playing, the IOProc was never
        // called at all — no system audio *and* no microphone — until something
        // made a sound or the output device changed. Measured 2026-11-02 with a
        // standalone copy of this setup: auto-start on, 0 callbacks in silence
        // (140 while audio played); off, 141 either way, and the tap still
        // carries system audio, including audio that starts mid-recording.
        kAudioAggregateDeviceTapAutoStartKey: false,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: input]],
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]
        ],
      ]
      try unsafe check("aggregate", AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))
    }

    private func nominalSampleRate(of device: AudioObjectID) throws -> Double {
      var rate = Float64(0)
      try read(kAudioDevicePropertyNominalSampleRate, of: device, into: &rate)
      return rate
    }

    /// The most frames one IO cycle delivers — what the mix buffers are sized to.
    private func bufferFrameSize(of device: AudioObjectID) throws -> UInt32 {
      var frames = UInt32(0)
      try read(kAudioDevicePropertyBufferFrameSize, of: device, into: &frames)
      return frames
    }

    private func read<Value>(
      _ selector: AudioObjectPropertySelector, of object: AudioObjectID, into value: inout Value
    ) throws {
      try check("property \(selector)", AudioRoute.read(selector, of: object, into: &value))
    }

    /// Blurt's own process object, so its cue sounds stay out of the tap.
    private func ownProcessObject() -> AudioObjectID? {
      var address = AudioRoute.globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
      var pid = ProcessInfo.processInfo.processIdentifier
      var object = AudioObjectID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      let status = unsafe AudioObjectGetPropertyData(
        AudioRoute.systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
      )
      return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func check(_ step: String, _ status: OSStatus) throws {
      guard status == noErr else { throw RecorderError.coreAudio(step, status) }
    }

    deinit { teardown() }
  }

#endif
