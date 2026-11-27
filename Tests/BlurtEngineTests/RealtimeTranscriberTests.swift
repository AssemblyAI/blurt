import Foundation
import Network
import Synchronization
import Testing

@testable import AssemblyAI

/// `RealtimeTranscriber` against a real WebSocket on loopback, standing in for
/// the realtime API: the handshake it opens, the audio it sends, the turns it
/// reads back, and the Terminate → Termination close.
@Suite("Realtime transcriber")
struct RealtimeTranscriberTests {
  /// A fake server, a transcriber pointed at it, and the transcriber's turns.
  private struct Connection {
    let server: FakeRealtimeServer
    let transcriber: RealtimeTranscriber
    let turns: AsyncThrowingStream<RealtimeTurn, any Error>
  }

  /// The fake server's scripted reply to any audio: a partial, then its final.
  private static let helloTurns = [
    RealtimeTurn(order: 0, transcript: "hello", isFinal: false, speaker: "A"),
    RealtimeTurn(order: 0, transcript: "Hello.", isFinal: true, speaker: "A"),
  ]

  /// A transcriber pointed at `server` with 100 ms of audio queued before any
  /// socket is open.
  private static func queued(on server: FakeRealtimeServer) async -> RealtimeTranscriber {
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    await transcriber.send(Data(count: 3_200))  // before start: no socket yet
    return transcriber
  }

  private func connect() async throws -> Connection {
    let server = try await FakeRealtimeServer.start()
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    await transcriber.start()
    return Connection(server: server, transcriber: transcriber, turns: transcriber.turns)
  }

  @Test("authenticates, sends 100 ms chunks and a padded tail, and reads turns until Termination")
  func session() async throws {
    let connection = try await connect()
    let (server, transcriber, turns) = (connection.server, connection.transcriber, connection.turns)
    defer { server.stop() }
    // Past the 1000 ms ceiling: one 32,000-byte message, 1,000 bytes left over.
    await transcriber.send(Data(count: 33_000))
    await transcriber.finish()
    var received: [RealtimeTurn] = []
    for try await turn in turns { received.append(turn) }

    #expect(server.authorization == "key")
    let query = Set(
      URLComponents(url: try #require(transcriber.request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    )
    #expect(
      query == [
        URLQueryItem(name: "encoding", value: "pcm_s16le"), URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "speaker_labels", value: "true"),
      ])
    // The 1,000-byte tail is padded up to the documented 50 ms floor.
    #expect(server.chunkSizes == [32_000, RealtimeTranscriber.minimumChunkBytes])
    #expect(server.terminated)
    #expect(received == Self.helloTurns)
  }

  @Test("audio sent before the socket opens waits, and is sent once it does")
  func audioBeforeStart() async throws {
    let server = try await FakeRealtimeServer.start()
    defer { server.stop() }
    let transcriber = await Self.queued(on: server)
    await transcriber.start()
    let turns = transcriber.turns
    await transcriber.send(Data(count: 3_200))
    await transcriber.finish()
    for try await _ in turns {
      // Drained for how the stream ends; its elements don't matter.
    }
    // The backlog and the new audio go out together, unsliced.
    #expect(server.chunkSizes == [6_400])
  }

  @Test("a finish that beats start opens the socket itself: the queued audio goes out and the turns arrive")
  func finishBeforeStart() async throws {
    let server = try await FakeRealtimeServer.start()
    defer { server.stop() }
    let transcriber = await Self.queued(on: server)
    await transcriber.finish()
    await transcriber.start()  // too late: the session is over, and this opens nothing
    var received: [RealtimeTurn] = []
    for try await turn in transcriber.turns { received.append(turn) }
    #expect(server.chunkSizes == [3_200])
    #expect(server.terminated)
    #expect(received == Self.helloTurns)
  }

  @Test("a backlog longer than 1000 ms is sliced on finish, not sent whole")
  func backlogIsSlicedOnFinish() async throws {
    let server = try await FakeRealtimeServer.start()
    defer { server.stop() }
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    await transcriber.send(Data(count: 40_000))  // before start: no socket yet
    await transcriber.start()
    let turns = transcriber.turns
    await transcriber.finish()
    for try await _ in turns {
      // Drained for how the stream ends; its elements don't matter.
    }
    #expect(server.chunkSizes == [32_000, 8_000])
  }

  @Test("a start that loses the race with cancel opens nothing")
  func startAfterCancel() async throws {
    let server = try await FakeRealtimeServer.start()
    defer { server.stop() }
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    await transcriber.cancel()
    await transcriber.start()
    let turns = transcriber.turns
    await transcriber.send(Data(count: 3_200))
    for try await _ in turns {
      // Drained for how the stream ends; its elements don't matter.
    }
    await transcriber.finish()
    #expect(server.chunkSizes.isEmpty)
    #expect(!server.terminated)
  }

  @Test("audio sent after the session closes is dropped, not queued")
  func sendAfterCloseIsDropped() async {
    // No server: a session cancelled before it opened never connects.
    let transcriber = RealtimeTranscriber(apiKey: "key", url: URL(literal: "ws://127.0.0.1:9/v3/ws"))
    await transcriber.cancel()
    await transcriber.send(Data(count: 3_200))
    #expect(await transcriber.pending.isEmpty)
  }

  @Test("an odd-length tail is padded to a whole sample on finish")
  func oddTailIsPaddedToAWholeSample() async throws {
    let server = try await FakeRealtimeServer.start()
    defer { server.stop() }
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    // Over the 50 ms floor, under a 100 ms chunk, and half a sample over.
    await transcriber.send(Data(count: RealtimeTranscriber.minimumChunkBytes + 1))
    await transcriber.start()
    let turns = transcriber.turns
    await transcriber.finish()
    for try await _ in turns {
      // Drained only so the session runs to its end; the turns aren't checked.
    }
    #expect(server.chunkSizes == [RealtimeTranscriber.minimumChunkBytes + 2])
  }

  @Test("a second finish waits for the same Termination instead of stranding the first")
  func concurrentFinish() async throws {
    let connection = try await connect()
    let (server, transcriber, turns) = (connection.server, connection.transcriber, connection.turns)
    defer { server.stop() }
    await transcriber.send(Data(count: 3_200))
    async let first: Void = transcriber.finish()
    async let second: Void = transcriber.finish()
    _ = await (first, second)
    for try await _ in turns {
      // Drained for how the stream ends; its elements don't matter.
    }
    #expect(server.terminated)
  }

  @Test("a connection that fails surfaces as an error on the turns")
  func connectionFailure() async throws {
    // Nothing listens on port 9 of loopback.
    let transcriber = RealtimeTranscriber(apiKey: "key", url: URL(literal: "ws://127.0.0.1:9/v3/ws"))
    await transcriber.start()
    let turns = transcriber.turns
    await #expect(throws: RealtimeError.self) {
      for try await _ in turns {
        // Drained for how the stream ends; its elements don't matter.
      }
    }
  }

  @Test("cancel ends the turns at once, without waiting for Termination")
  func cancel() async throws {
    let connection = try await connect()
    let (server, transcriber, turns) = (connection.server, connection.transcriber, connection.turns)
    defer { server.stop() }
    await transcriber.cancel()
    for try await _ in turns {
      // Drained for how the stream ends; its elements don't matter.
    }
    #expect(!server.terminated)
  }

  @Test("server Error frames surface their message instead of the close placeholder")
  func errorFrameSurfacesServerMessage() async throws {
    let server = try await FakeRealtimeServer.start(
      behavior: .errorFrame(
        message: "User Input Validation Error: bad audio",
        closeReason: "See Error message for details"
      )
    )
    defer { server.stop() }
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    await transcriber.start()
    await transcriber.send(Data(count: 3_200))

    var caught: (any Error)?
    do {
      for try await _ in transcriber.turns {
        // Wait for the server Error frame to end the stream.
      }
    } catch {
      caught = error
    }
    #expect(caught as? RealtimeError == .connection("User Input Validation Error: bad audio"))
    let event = try JSONDecoder().decode(
      RealtimeTranscriber.Event.self,
      from: Data(#"{"type":"Error","error_code":3006,"error":"Too many sessions"}"#.utf8)
    )
    #expect(event.error == "Too many sessions")
    #expect(event.turn == nil)
  }
}
