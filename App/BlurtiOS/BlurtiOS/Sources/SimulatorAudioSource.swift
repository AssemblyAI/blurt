#if targetEnvironment(simulator)
  import AudioToolbox
  import BlurtEngine
  import Foundation
  import Synchronization

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
    /// The running queue, or nil while closed or parked between utterances.
    private let queue = Mutex<AudioQueueRef?>(nil)
    private let opened = Atomic<Bool>(false)
    private let parking = Atomic<Bool>(false)
    private let failures: AsyncStream<Void>.Continuation
    let failedStarts: AsyncStream<Void>

    var levels: AsyncStream<Float> { feed.levels }
    var isOpen: Bool { opened.load(ordering: .acquiring) }

    #if DEBUG
      /// `BLURT_SIM_AUDIO_FILE`: a 16 kHz mono 16-bit WAV played into every
      /// utterance in place of the Mac's microphone, at the queue's own pace,
      /// so a probe can dictate real speech with nobody speaking; debug builds
      /// only.
      private static let scripted: Data? = ProcessInfo.processInfo.environment["BLURT_SIM_AUDIO_FILE"]
        .flatMap { try? Data(contentsOf: URL(filePath: $0)) }
        .flatMap(pcmBody)
      private let scriptedOffset = Mutex(0)

      /// The samples after a WAV's `data` chunk header.
      private static func pcmBody(_ wav: Data) -> Data? {
        guard let marker = wav.range(of: Data("data".utf8)) else { return nil }
        let start = marker.upperBound + MemoryLayout<UInt32>.size
        return start < wav.count ? wav.subdata(in: start..<wav.count) : nil
      }

      /// The next `count` bytes of the scripted speech, silence once it runs out.
      private func nextScripted(_ count: Int, from speech: Data) -> Data {
        scriptedOffset.withLock { offset in
          let end = min(offset + count, speech.count)
          var chunk = offset < end ? speech.subdata(in: offset..<end) : Data()
          offset = end
          if chunk.count < count { chunk.append(Data(count: count - chunk.count)) }
          return chunk
        }
      }
    #endif

    init() {
      (failedStarts, failures) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit { stopQueue() }

    func open() async throws {
      parking.store(false, ordering: .releasing)
      try startQueue()
      opened.store(true, ordering: .releasing)
    }

    func park() async {
      parking.store(true, ordering: .releasing)
      if !feed.isCapturing { stopQueue() }
    }

    func hold() async throws {
      parking.store(false, ordering: .releasing)
      if isOpen { try startQueue() }
    }

    func close() async {
      opened.store(false, ordering: .releasing)
      parking.store(false, ordering: .releasing)
      stopQueue()
      feed.end()
    }

    private func startQueue() throws {
      try queue.withLock { queue in
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
        else { throw ListeningSourceFailure.noInputDevice }
        for _ in 0..<Self.bufferCount {
          var buffer: AudioQueueBufferRef?
          guard AudioQueueAllocateBuffer(created, Self.bufferBytes, &buffer) == noErr, let buffer else { continue }
          _ = AudioQueueEnqueueBuffer(created, buffer, 0, nil)
        }
        guard AudioQueueStart(created, nil) == noErr else {
          _ = AudioQueueDispose(created, true)
          throw ListeningSourceFailure.noInputDevice
        }
        queue = created
      }
    }

    private func stopQueue() {
      let stopped = queue.withLock { queue in
        defer { queue = nil }
        return queue
      }
      guard let stopped else { return }
      _ = AudioQueueStop(stopped, true)
      _ = AudioQueueDispose(stopped, true)
    }

    // MARK: MicCaptureProtocol

    func start() async throws -> AsyncStream<Data> {
      guard isOpen else {
        throw BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed)
      }
      if parking.load(ordering: .acquiring) {
        do {
          try startQueue()
        } catch {
          guard isOpen, !Task.isCancelled else { throw CancellationError() }
          failures.yield()
          throw BlurtError.audioCaptureFailed(underlying: error)
        }
        // Closed while the queue came up: no window, no microphone.
        guard isOpen else {
          stopQueue()
          throw CancellationError()
        }
      }
      #if DEBUG
        scriptedOffset.withLock { $0 = 0 }
      #endif
      return feed.begin()
    }

    func stop() -> Int {
      let bytes = feed.end()
      releaseWhenIdle()
      return bytes
    }

    func cancelCapture() {
      feed.end()
      releaseWhenIdle()
    }

    private func releaseWhenIdle() {
      if parking.load(ordering: .acquiring) || !isOpen { stopQueue() }
    }

    /// Core Audio's callback: a C function pointer, so it captures nothing and
    /// finds its way back to the source through the user-data pointer.
    private static let deliver: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
      guard let userData else { return }
      let source = Unmanaged<SimulatorAudioSource>.fromOpaque(userData).takeUnretainedValue()
      let count = Int(buffer.pointee.mAudioDataByteSize)
      if count > 0 {
        var chunk = Data(bytes: buffer.pointee.mAudioData, count: count)
        #if DEBUG
          if let speech = SimulatorAudioSource.scripted, source.feed.isCapturing {
            chunk = source.nextScripted(count, from: speech)
          }
        #endif
        source.feed.deliver(chunk)
      }
      _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
  }
#endif
