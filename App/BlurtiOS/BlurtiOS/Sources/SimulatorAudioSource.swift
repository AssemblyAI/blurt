#if targetEnvironment(simulator)
  import AudioToolbox
  import BlurtEngine
  import Foundation

  /// The simulator's microphone. `AVCaptureSession` carries no audio there
  /// (FigCaptureSessionSimulator fails with -12782 the moment it starts), so
  /// this feeds the same stream from an Audio Queue that asks for the dictation
  /// format outright — 16 kHz mono 16-bit — and lets Core Audio convert from
  /// the Mac's microphone. Never built for a phone; `WindowedAudioSource` is
  /// the real thing and this only has to be good enough to exercise the loop.
  nonisolated final class SimulatorAudioSource: ListeningSource, @unchecked Sendable {
    /// 100 ms per buffer, three in flight.
    private static let bufferBytes: UInt32 = 3200
    private static let bufferCount = 3

    private let feed = UtteranceFeed()
    private nonisolated(unsafe) var queue: AudioQueueRef?
    private(set) nonisolated(unsafe) var isOpen = false

    var levels: AsyncStream<Float> { feed.levels }

    deinit { close() }

    func open() throws {
      guard queue == nil else { return }
      var format = AudioStreamBasicDescription(
        mSampleRate: Double(SyncSTTLimits.sampleRate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
        mReserved: 0)
      var created: AudioQueueRef?
      let unmanagedSelf = Unmanaged.passUnretained(self).toOpaque()
      guard AudioQueueNewInput(&format, Self.deliver, unmanagedSelf, nil, nil, 0, &created) == noErr,
        let created
      else { throw WindowedAudioSource.Failure.noInputDevice }
      for _ in 0..<Self.bufferCount {
        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBuffer(created, Self.bufferBytes, &buffer) == noErr, let buffer else { continue }
        _ = AudioQueueEnqueueBuffer(created, buffer, 0, nil)
      }
      guard AudioQueueStart(created, nil) == noErr else {
        _ = AudioQueueDispose(created, true)
        throw WindowedAudioSource.Failure.noInputDevice
      }
      queue = created
      isOpen = true
    }

    func close() {
      if let queue {
        _ = AudioQueueStop(queue, true)
        _ = AudioQueueDispose(queue, true)
      }
      queue = nil
      isOpen = false
      feed.end()
    }

    // MARK: MicCaptureProtocol

    func start() throws -> AsyncStream<Data> {
      guard isOpen else {
        throw BlurtError.audioCaptureFailed(underlying: WindowedAudioSource.Failure.windowClosed)
      }
      return feed.begin()
    }

    func stop() -> Int { feed.end() }

    func cancelCapture() { feed.end() }

    /// Core Audio's callback: a C function pointer, so it captures nothing and
    /// finds its way back to the source through the user-data pointer.
    private static let deliver: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
      guard let userData else { return }
      let source = Unmanaged<SimulatorAudioSource>.fromOpaque(userData).takeUnretainedValue()
      let count = Int(buffer.pointee.mAudioDataByteSize)
      if count > 0 {
        source.feed.deliver(Data(bytes: buffer.pointee.mAudioData, count: count))
      }
      _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
  }
#endif
