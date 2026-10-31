#if os(macOS)
  import AVFoundation
  import AssemblyAI
  import CoreAudio
  import Foundation

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
  /// cue sounds excluded) joined to the default input device in a private
  /// aggregate device. The **input device is the aggregate's only sub-device
  /// and its clock**, with the tap drift-compensated against it — so a
  /// headset whose mic and speaker are one device isn't added twice, an output
  /// interface's own inputs never reach the mix, and switching the output
  /// mid-recording doesn't pull the clock away. One IOProc delivers both
  /// streams in the same cycle; each is averaged to mono, the two summed and
  /// clamped, then converted to 16 kHz. The first recording asks for the
  /// System Audio Recording permission (`NSAudioCaptureUsageDescription`);
  /// refused, the tap delivers silence and the microphone still records.
  public final class SystemAudioRecorder {
    public enum RecorderError: Error, LocalizedError {
      case coreAudio(String, OSStatus)

      public var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status):
          "Couldn't start recording (\(step), error \(status))."
        }
      }
    }

    /// The rate everything leaves at: the realtime API's, and plenty for speech.
    public static let outputSampleRate = Double(RealtimeTranscriber.sampleRate)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: MixWriter?
    private let queue = DispatchQueue(label: "Blurt.SystemAudioRecorder")
    static let log = HostIdentity.current.logger("Recorder")

    public init() {}

    deinit { teardown() }

    /// Starts recording to `url` (an `.m4a`), handing each slice of the 16 kHz
    /// mix to `onPCM` as S16LE bytes, on the recorder's queue. Throws — with
    /// everything it created torn down, the empty file included — if any Core
    /// Audio step fails.
    public func start(to url: URL, onPCM: @escaping @Sendable (Data) -> Void) throws {
      do {
        try createTap()
        try createAggregate()
        let rate = try nominalSampleRate(of: aggregateID)
        let frames = try bufferFrameSize(of: aggregateID)
        Self.log.notice(
          "recorder starting: aggregate \(self.aggregateID, privacy: .public) at \(rate, privacy: .public) Hz, \(frames, privacy: .public)-frame buffers"
        )
        let writer = try MixWriter(url: url, inputRate: rate, maxFrames: Int(frames), onPCM: onPCM)
        self.writer = writer
        var proc: AudioDeviceIOProcID?
        try check(
          "IOProc",
          AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { _, input, _, _, _ in
            writer.write(input)
          })
        procID = proc
        try check("start", AudioDeviceStart(aggregateID, proc))
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
      guard let procID else { return }
      AudioDeviceStop(aggregateID, procID)
      Self.log.notice("recorder paused")
    }

    /// Resumes capture into the same file after `pause`.
    public func resume() throws {
      guard let procID else { return }
      try check("resume", AudioDeviceStart(aggregateID, procID))
      Self.log.notice("recorder resumed")
    }

    /// Stops recording and closes the file. Safe to call when not recording.
    public func stop() {
      teardown()
    }

    private func teardown() {
      if let writer { Self.log.notice("recorder stopping: \(writer.summary, privacy: .public)") }
      if let procID {
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        self.procID = nil
      }
      // Every callback already queued has run once this returns, so the file
      // closes after its last write.
      queue.sync { writer?.close() }
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
      try check("tap", AudioHardwareCreateProcessTap(description, &tapID))
    }

    private func createAggregate() throws {
      // The same default input the dictation recorder and the Settings picker
      // resolve — one spelling of it (`AudioInputDevices`).
      guard let input = AudioInputDevices.systemDefaultDevice?.uniqueID else {
        throw RecorderError.coreAudio("default input", kAudioHardwareUnspecifiedError)
      }
      let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Blurt Recorder",
        kAudioAggregateDeviceUIDKey: "Blurt.Recorder.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: input,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: input]],
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]
        ],
      ]
      try check("aggregate", AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))
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
      let status = AudioObjectGetPropertyData(
        AudioRoute.systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
      return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func check(_ step: String, _ status: OSStatus) throws {
      guard status == noErr else { throw RecorderError.coreAudio(step, status) }
    }
  }

#endif
