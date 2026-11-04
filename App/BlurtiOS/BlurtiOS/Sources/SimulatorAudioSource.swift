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
  ///
  /// Debug builds also fail on request (`BLURT_SIM_FAULT`, `Fault`,
  /// `SimulatorAudioSource+Fault.swift`): the failures and events a phone's
  /// microphone produces, so the app's and the keyboard's answers to each can
  /// be seen without a phone call.
  nonisolated final class SimulatorAudioSource: ListeningSource, @unchecked Sendable {
    /// 100 ms per buffer, three in flight.
    private static let bufferBytes: UInt32 = 3200
    private static let bufferCount = 3
    private static let log = HostIdentity.current.logger("Capture")

    private let feed: UtteranceFeed
    /// The running queue, or nil while closed or parked between utterances.
    private let queue = Mutex<AudioQueueRef?>(nil)
    private let opened = Atomic<Bool>(false)
    private let parking = Atomic<Bool>(false)
    private let failures: AsyncStream<Void>.Continuation
    let failedStarts: AsyncStream<Void>
    private let eventSink: AsyncStream<SourceEvent>.Continuation
    let events: AsyncStream<SourceEvent>

    var levels: AsyncStream<Float> { feed.levels }

    var isOpen: Bool {
      #if DEBUG
        guard !interrupted.load(ordering: .acquiring), !dead.load(ordering: .acquiring) else { return false }
      #endif
      return opened.load(ordering: .acquiring)
    }

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

      private let fault: Fault?
      /// The timed fault, counting from `open` to `close`.
      private let faultTimer = Mutex<Task<Void, Never>?>(nil)
      /// Taken away (`interruptAfter`): no frames, no starts, not open.
      private let interrupted = Atomic<Bool>(false)
      /// Dead (`runtimeErrorAfter`): the queue is gone until the window closes.
      private let dead = Atomic<Bool>(false)
      /// Whether an Audio Queue runs on the Mac's microphone. Tests say no:
      /// a runner has no microphone to assume, and feed `deliverForTesting`.
      private let usesMicrophone: Bool

      init(fault: Fault? = Fault.fromEnvironment, usesMicrophone: Bool = true) {
        self.fault = fault
        self.usesMicrophone = usesMicrophone
        (failedStarts, failures) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (events, sink) = AsyncStream<SourceEvent>.makeStream()
        self.events = events
        eventSink = sink
        feed = UtteranceFeed(onSilence: { sink.yield(.silent) })
      }
    #else
      init() {
        (failedStarts, failures) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (events, sink) = AsyncStream<SourceEvent>.makeStream()
        self.events = events
        eventSink = sink
        feed = UtteranceFeed(onSilence: { sink.yield(.silent) })
      }
    #endif

    deinit {
      stopQueue()
      #if DEBUG
        faultTimer.withLock { $0?.cancel() }
      #endif
    }

    func open() async throws {
      parking.store(false, ordering: .releasing)
      try startQueue(parked: false)
      opened.store(true, ordering: .releasing)
      #if DEBUG
        scheduleFault()
      #endif
    }

    func park() async {
      parking.store(true, ordering: .releasing)
      if !feed.isCapturing { stopQueue() }
    }

    func hold() async throws {
      parking.store(false, ordering: .releasing)
      if isOpen { try startQueue(parked: false) }
    }

    func close() async {
      opened.store(false, ordering: .releasing)
      parking.store(false, ordering: .releasing)
      #if DEBUG
        faultTimer.withLock { $0?.cancel() }
        interrupted.store(false, ordering: .releasing)
        dead.store(false, ordering: .releasing)
      #endif
      stopQueue()
      feed.end()
    }

    private func startQueue(parked: Bool) throws {
      #if DEBUG
        try refuse(parked: parked)
        guard usesMicrophone else { return }
      #endif
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
        throw BlurtError.audioCaptureFailed(underlying: closedFailure())
      }
      if parking.load(ordering: .acquiring) {
        do {
          try startQueue(parked: true)
        } catch {
          guard isOpen, !Task.isCancelled else { throw CancellationError() }
          Self.log.error("capture parked start failed: \(error.localizedDescription, privacy: .public)")
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

    /// Why a press found no microphone: the window is closed — or, under a
    /// fault, the microphone is taken or dead.
    private func closedFailure() -> ListeningSourceFailure {
      #if DEBUG
        if interrupted.load(ordering: .acquiring) { return .interrupted(reason: Fault.interruptionReason) }
        if dead.load(ordering: .acquiring) { return .runtimeError(code: Fault.errorCode) }
      #endif
      return .windowClosed
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

    /// A chunk from the Mac's microphone — or a test's — on its way to the
    /// feed: the scripted speech or the fault's zeros in its place, nothing
    /// while the microphone is taken or dead.
    private func ingest(_ chunk: Data) {
      var chunk = chunk
      #if DEBUG
        guard !interrupted.load(ordering: .acquiring), !dead.load(ordering: .acquiring) else { return }
        if let speech = Self.scripted, feed.isCapturing { chunk = nextScripted(chunk.count, from: speech) }
        if fault == .silentFrames { chunk = Data(count: chunk.count) }
      #endif
      feed.deliver(chunk)
    }

    /// Core Audio's callback: a C function pointer, so it captures nothing and
    /// finds its way back to the source through the user-data pointer.
    private static let deliver: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
      guard let userData else { return }
      let source = Unmanaged<SimulatorAudioSource>.fromOpaque(userData).takeUnretainedValue()
      let count = Int(buffer.pointee.mAudioDataByteSize)
      if count > 0 { source.ingest(Data(bytes: buffer.pointee.mAudioData, count: count)) }
      _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    #if DEBUG
      /// A test's chunk, taken the way the Audio Queue's are.
      func deliverForTesting(_ chunk: Data) { ingest(chunk) }

      /// The fault's refusal, for a start: every start, or a parked one.
      private func refuse(parked: Bool) throws {
        switch fault {
        case .refuseStart:
          throw ListeningSourceFailure.configureFailed(code: Fault.errorCode)
        case .refuseBackgroundStart where parked:
          throw ListeningSourceFailure.backgroundStartRefused(code: Fault.backgroundRefusalCode)
        default:
          return
        }
      }

      /// Starts the timed fault's clock, from the window opening.
      private func scheduleFault() {
        guard let fault, let delay = fault.delay else { return }
        let task = Task { [weak self] in
          guard (try? await Task.sleep(for: .seconds(delay))) != nil, let self else { return }
          self.fire(fault)
          guard case .interruptAfter = fault, (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
          self.interrupted.store(false, ordering: .releasing)
          Self.log.notice("capture interruptionEnded (simulated)")
          self.eventSink.yield(.interruptionEnded)
        }
        faultTimer.withLock {
          $0?.cancel()
          $0 = task
        }
      }

      private func fire(_ fault: Fault) {
        switch fault {
        case .interruptAfter:
          interrupted.store(true, ordering: .releasing)
          Self.log.notice("capture interrupted reason=\(Fault.interruptionReason, privacy: .public) (simulated)")
          eventSink.yield(.interrupted(reason: Fault.interruptionReason))
        case .runtimeErrorAfter:
          dead.store(true, ordering: .releasing)
          stopQueue()
          Self.log.error("capture runtimeError code=\(Fault.errorCode) (simulated)")
          eventSink.yield(.runtimeError(code: Fault.errorCode))
        case .routeChangeAfter:
          let route = "reason=\(Fault.routeChangeReason) input=\(Fault.routeInput)"
          Self.log.notice("capture route \(route, privacy: .public) (simulated)")
          eventSink.yield(.routeChanged(reason: Fault.routeChangeReason, input: Fault.routeInput))
        case .refuseStart, .silentFrames, .refuseBackgroundStart:
          break
        }
      }
    #endif
  }
#endif
