#if targetEnvironment(simulator)
  import BlurtEngine
  import Foundation
  import Testing

  @testable import BlurtiOS
  @testable import BlurtiOSCore

  @Suite("Simulator faults")
  struct SimulatorFaultTests {
    private typealias Fault = SimulatorAudioSource.Fault

    /// A 100 ms chunk with sound in it.
    private static let live = [Int16](repeating: 1_000, count: 1_600).withUnsafeBufferPointer { Data(buffer: $0) }

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
        let first = await group.next().flatMap(\.self)
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

    @Test("refuseBackgroundStart: the window opens and holds; a parked press is refused, typed")
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
      try await source.hold()
      _ = try await source.start()
      _ = source.stop()
      await source.close()
    }

    @Test("silentFrames: an utterance of zeros trips the watchdog after the start's grace, and the zeros still flow")
    func silentFrames() async throws {
      let source = SimulatorAudioSource(fault: .silentFrames, usesMicrophone: false)
      try await source.open()
      let stream = try await source.start()
      let chunks = UtteranceFeed.startGraceBytes / Self.live.count
      for _ in 0..<chunks { source.deliverForTesting(Self.live) }
      #expect(await Self.next(source.events) == .silent)
      #expect(source.stop() == chunks * Self.live.count)
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
      source.deliverForTesting(Self.live)
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
