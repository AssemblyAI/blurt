import AVFoundation
import BlurtEngine
import Foundation
import Synchronization
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

/// Every way the window's microphone can fail, said as the keyboard's reason
/// and the home screen's sentence (`CaptureFailure`), the silence watchdog
/// (`UtteranceFeed`), the session's reason names, and the simulator's faults.
@Suite("Capture failures")
struct CaptureFailureTests {
  /// Every `ListeningSourceFailure`, with its reason.
  private static let failures: [(ListeningSourceFailure, FailureReason)] = [
    (.windowClosed, .sessionOff),
    (.noInputDevice, .micBusy),
    (.interrupted(reason: "audioDeviceInUseByAnotherClient"), .interrupted),
    (.runtimeError(code: -12782), .micBusy),
    (.configureFailed(code: -50), .micBusy),
    (.inputSilent, .micSilent),
    (.couldNotResume, .interrupted),
    (.backgroundStartRefused(code: 0), .needsForeground),
  ]

  private struct Stranger: Error {}

  @Test("every failure has its reason and its own sentence, bare or under the engine's wrapper")
  func reasons() {
    for (failure, reason) in Self.failures {
      #expect(CaptureFailure.reason(for: failure) == reason)
      #expect(CaptureFailure.reason(for: BlurtError.audioCaptureFailed(underlying: failure)) == reason)
      let sentence = CaptureFailure.sentence(for: failure)
      #expect(sentence == failure.errorDescription)
      #expect(sentence.hasSuffix("."))
      #expect(CaptureFailure.sentence(for: BlurtError.audioCaptureFailed(underlying: failure)) == sentence)
    }
    #expect(Set(Self.failures.map { CaptureFailure.sentence(for: $0.0) }).count == Self.failures.count)
    #expect(ListeningSourceFailure.windowClosed.errorDescription == "The session is off.")
    #expect(ListeningSourceFailure.noInputDevice.errorDescription == "No microphone is available.")
    // The coordinator's comparison still works with associated values about.
    let wrapped = BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed)
    if case .audioCaptureFailed(let underlying) = wrapped {
      #expect(underlying as? ListeningSourceFailure == .windowClosed)
      #expect(underlying as? ListeningSourceFailure != .interrupted(reason: "x"))
    } else {
      Issue.record("not the wrapper")
    }
  }

  @Test("an error the source didn't throw is the microphone being busy, in the engine's words")
  func strangers() {
    #expect(CaptureFailure.reason(for: Stranger()) == .micBusy)
    #expect(CaptureFailure.reason(for: BlurtError.audioCaptureFailed(underlying: Stranger())) == .micBusy)
    #expect(CaptureFailure.reason(for: CancellationError()) == .micBusy)
    #expect(CaptureFailure.sentence(for: Stranger()) == Stranger().localizedDescription)
    let wrapped = BlurtError.audioCaptureFailed(underlying: Stranger())
    #expect(CaptureFailure.sentence(for: wrapped) == Stranger().localizedDescription)
    #expect(!CaptureFailure.sentence(for: wrapped).hasPrefix("Audio capture failed"))
  }

  @Test("an event is a reason when it is a failure, and nothing when it is news")
  func events() {
    #expect(CaptureFailure.reason(for: .interrupted(reason: "audioDeviceInUseByAnotherClient")) == .interrupted)
    #expect(CaptureFailure.reason(for: .runtimeError(code: -12782)) == .micBusy)
    #expect(CaptureFailure.reason(for: .silent) == .micSilent)
    #expect(CaptureFailure.reason(for: .interruptionEnded) == nil)
    #expect(CaptureFailure.reason(for: .routeChanged(reason: "newDeviceAvailable", input: "BluetoothHFP")) == nil)
  }

  @Test("the session's reasons are named, and an unknown one keeps its number")
  func reasonNames() {
    let busy = AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient
    #expect(WindowedAudioSource.interruptionName(busy.rawValue) == "audioDeviceInUseByAnotherClient")
    let background = AVCaptureSession.InterruptionReason.videoDeviceNotAvailableInBackground
    #expect(WindowedAudioSource.interruptionName(background.rawValue) == "videoDeviceNotAvailableInBackground")
    #expect(WindowedAudioSource.interruptionName(nil) == "unknown")
    #expect(WindowedAudioSource.interruptionName(999) == "reason 999")
    let newDevice = AVAudioSession.RouteChangeReason.newDeviceAvailable
    #expect(WindowedAudioSource.routeChangeName(newDevice.rawValue) == "newDeviceAvailable")
    #expect(WindowedAudioSource.routeChangeName(AVAudioSession.RouteChangeReason.override.rawValue) == "override")
    #expect(WindowedAudioSource.routeChangeName(nil) == "unknown")
    #expect(WindowedAudioSource.routeChangeName(999) == "reason 999")
  }
}

@Suite("Silence watchdog")
struct SilenceWatchdogTests {
  /// `seconds` of digital silence, as 16 kHz mono 16-bit PCM.
  private static func zeros(seconds: Double) -> Data {
    Data(count: Int(seconds * Double(UtteranceFeed.silenceBytes)))
  }

  /// A chunk with sound in it.
  private static let live = [Int16](repeating: 1000, count: 1600).withUnsafeBufferPointer { Data(buffer: $0) }

  /// How many times the feed said silent.
  nonisolated private final class Silences: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func bump() { count.withLock { $0 += 1 } }
  }

  private static func feed() -> (UtteranceFeed, Silences) {
    let silences = Silences()
    return (UtteranceFeed(onSilence: { silences.bump() }), silences)
  }

  @Test("the second is a second of 16 kHz mono 16-bit")
  func constant() {
    #expect(UtteranceFeed.silenceSeconds == 1)
    #expect(UtteranceFeed.silenceBytes == 32_000)
  }

  @Test("a second of zeros in an open utterance says silent, once per run; a live chunk starts the count over")
  func silent() {
    let (feed, count) = Self.feed()
    feed.deliver(Self.zeros(seconds: 2))
    #expect(count.value == 0, "nothing between utterances")
    _ = feed.begin()
    for _ in 0..<9 { feed.deliver(Self.zeros(seconds: 0.1)) }
    #expect(count.value == 0, "0.9 s is not a second")
    feed.deliver(Self.zeros(seconds: 0.1))
    #expect(count.value == 1)
    feed.deliver(Self.zeros(seconds: 3))
    #expect(count.value == 1, "said once per run")
    feed.deliver(Self.live)
    feed.deliver(Self.zeros(seconds: 0.5))
    #expect(count.value == 1, "the live chunk started the count over")
    feed.deliver(Self.zeros(seconds: 0.5))
    #expect(count.value == 2)
    feed.end()
    feed.deliver(Self.zeros(seconds: 2))
    #expect(count.value == 2, "nothing after the utterance")
    _ = feed.begin()
    feed.deliver(Self.zeros(seconds: 1))
    #expect(count.value == 3, "the next utterance counts afresh")
    feed.end()
  }

  @Test("the zeros still reach the utterance and its tally")
  func delivered() async {
    let (feed, _) = Self.feed()
    let stream = feed.begin()
    feed.deliver(Self.zeros(seconds: 1))
    #expect(feed.bytesSoFar == UtteranceFeed.silenceBytes)
    #expect(feed.end() == UtteranceFeed.silenceBytes)
    var received = 0
    for await chunk in stream { received += chunk.count }
    #expect(received == UtteranceFeed.silenceBytes)
  }

  @Test("a parked start holds the watchdog until the first live frame")
  func parked() {
    let (feed, count) = Self.feed()
    _ = feed.begin(watchingSilence: false)
    feed.deliver(Self.zeros(seconds: 2.5))
    #expect(count.value == 0, "a route coming up delivers zeros")
    feed.watchSilence()
    feed.deliver(Self.zeros(seconds: 1))
    #expect(count.value == 1)
    feed.end()
    // `begin` without the flag watches from the first chunk again.
    _ = feed.begin()
    feed.deliver(Self.zeros(seconds: 1))
    #expect(count.value == 2)
    feed.end()
  }
}

#if targetEnvironment(simulator)
  @Suite("Simulator faults")
  struct SimulatorFaultTests {
    private typealias Fault = SimulatorAudioSource.Fault

    /// A 100 ms chunk with sound in it.
    private static let live = [Int16](repeating: 1000, count: 1600).withUnsafeBufferPointer { Data(buffer: $0) }

    /// The next event, or nil if none arrives in time — a failed test, not a hung one.
    private static func next(_ events: AsyncStream<SourceEvent>, within: Duration = .seconds(3)) async -> SourceEvent? {
      await withTaskGroup(of: SourceEvent?.self) { group in
        group.addTask {
          var iterator = events.makeAsyncIterator()
          return await iterator.next()
        }
        group.addTask {
          try? await Task.sleep(for: within)
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }

    /// What `start()` throws, or nil when it doesn't.
    private static func startFailure(_ source: SimulatorAudioSource) async -> (any Error)? {
      do {
        _ = try await source.start()
        return nil
      } catch {
        return error
      }
    }

    @Test("every BLURT_SIM_FAULT value parses, and nothing else does")
    func parse() {
      #expect(Fault.parse("refuseStart") == .refuseStart)
      #expect(Fault.parse("silentFrames") == .silentFrames)
      #expect(Fault.parse("refuseBackgroundStart") == .refuseBackgroundStart)
      #expect(Fault.parse("interruptAfter:2") == .interruptAfter(seconds: 2))
      #expect(Fault.parse("runtimeErrorAfter:0.5") == .runtimeErrorAfter(seconds: 0.5))
      #expect(Fault.parse("routeChangeAfter:0") == .routeChangeAfter(seconds: 0))
      #expect(Fault.parse("") == nil)
      #expect(Fault.parse("refuseStart:2") == nil)
      #expect(Fault.parse("interruptAfter") == nil)
      #expect(Fault.parse("interruptAfter:") == nil)
      #expect(Fault.parse("interruptAfter:-1") == nil)
      #expect(Fault.parse("interruptAfter:soon") == nil)
      #expect(Fault.parse("explode") == nil)
      #expect(Fault.environmentKey == "BLURT_SIM_FAULT")
      #expect(Fault.interruptAfter(seconds: 2).delay == 2)
      #expect(Fault.silentFrames.delay == nil)
    }

    @Test("refuseStart: every start throws the simulator's configure failure")
    func refuseStart() async throws {
      let source = SimulatorAudioSource(fault: .refuseStart, usesMicrophone: false)
      await #expect(throws: ListeningSourceFailure.configureFailed(code: Fault.errorCode)) { try await source.open() }
      #expect(!source.isOpen)
      // A hold on a window that never opened is nothing, by design; a press finds no window.
      try await source.hold()
      let failure = await Self.startFailure(source)
      #expect(CaptureFailure.reason(for: try #require(failure)) == .sessionOff, "no window: never opened")
    }

    @Test("refuseBackgroundStart: the window opens and holds; a parked press is refused, typed, and reported")
    func refuseBackgroundStart() async throws {
      let source = SimulatorAudioSource(fault: .refuseBackgroundStart, usesMicrophone: false)
      try await source.open()
      #expect(source.isOpen)
      _ = try await source.start()
      #expect(source.stop() == 0)
      await source.park()
      #expect(source.isOpen)
      let failure = try #require(await Self.startFailure(source))
      #expect(CaptureFailure.reason(for: failure) == .needsForeground)
      #expect(CaptureFailure.sentence(for: failure) == "Open Blurt to start the microphone.")
      if case BlurtError.audioCaptureFailed(let underlying) = failure {
        #expect(underlying as? ListeningSourceFailure == .backgroundStartRefused(code: Fault.backgroundRefusalCode))
      } else {
        Issue.record("not the engine's wrapper: \(failure)")
      }
      var failed = source.failedStarts.makeAsyncIterator()
      #expect(await failed.next() != nil, "reported on failedStarts")
      try await source.hold()
      _ = try await source.start()
      _ = source.stop()
      await source.close()
    }

    @Test("silentFrames: an utterance of zeros trips the watchdog, and the zeros still flow")
    func silentFrames() async throws {
      let source = SimulatorAudioSource(fault: .silentFrames, usesMicrophone: false)
      try await source.open()
      let stream = try await source.start()
      for _ in 0..<10 { source.deliverForTesting(Self.live) }
      #expect(await Self.next(source.events) == .silent)
      #expect(source.stop() == 10 * Self.live.count)
      var zeros = true
      for await chunk in stream { zeros = zeros && UtteranceFeed.isDigitalSilence(chunk) }
      #expect(zeros)
      await source.close()
    }

    @Test("interruptAfter: taken, refused, given back — in that order")
    func interruptAfter() async throws {
      let source = SimulatorAudioSource(fault: .interruptAfter(seconds: 0.05), usesMicrophone: false)
      try await source.open()
      #expect(await Self.next(source.events) == .interrupted(reason: Fault.interruptionReason))
      #expect(!source.isOpen)
      let failure = try #require(await Self.startFailure(source))
      #expect(CaptureFailure.reason(for: failure) == .interrupted)
      #expect(await Self.next(source.events) == .interruptionEnded)
      #expect(source.isOpen)
      _ = try await source.start()
      source.deliverForTesting(Self.live)
      #expect(source.stop() == Self.live.count)
      await source.close()
    }

    @Test("runtimeErrorAfter: the session dies with its code and stays dead")
    func runtimeErrorAfter() async throws {
      let source = SimulatorAudioSource(fault: .runtimeErrorAfter(seconds: 0.05), usesMicrophone: false)
      try await source.open()
      #expect(await Self.next(source.events) == .runtimeError(code: Fault.errorCode))
      #expect(!source.isOpen)
      let failure = try #require(await Self.startFailure(source))
      #expect(CaptureFailure.reason(for: failure) == .micBusy)
      #expect(CaptureFailure.sentence(for: failure) == "The microphone stopped unexpectedly.")
      try await source.hold()
      #expect(!source.isOpen, "dead until the window closes")
      await source.close()
      #expect(!source.isOpen)
    }

    @Test("routeChangeAfter: the route changes and nothing else does; events keep their order")
    func routeChangeAfter() async throws {
      let source = SimulatorAudioSource(fault: .routeChangeAfter(seconds: 0.05), usesMicrophone: false)
      try await source.open()
      // Delivered before the route timer fires: the watchdog's event lands first.
      _ = try await source.start()
      source.deliverForTesting(Data(count: UtteranceFeed.silenceBytes))
      #expect(await Self.next(source.events) == .silent)
      #expect(await Self.next(source.events) == .routeChanged(reason: Fault.routeChangeReason, input: Fault.routeInput))
      #expect(source.isOpen)
      _ = source.stop()
      _ = try await source.start()
      await source.close()
    }
  }
#endif
