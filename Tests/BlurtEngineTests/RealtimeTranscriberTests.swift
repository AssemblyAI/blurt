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

  private func connect() async throws -> Connection {
    let server = try await FakeRealtimeServer.start()
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    return Connection(server: server, transcriber: transcriber, turns: await transcriber.start())
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
    #expect(
      received == [
        RealtimeTurn(order: 0, transcript: "hello", isFinal: false, speaker: "A"),
        RealtimeTurn(order: 0, transcript: "Hello.", isFinal: true, speaker: "A"),
      ])
  }

  @Test("audio sent before the socket opens waits, and is sent once it does")
  func audioBeforeStart() async throws {
    let server = try await FakeRealtimeServer.start()
    defer { server.stop() }
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    await transcriber.send(Data(count: 3_200))  // before start: no socket yet
    let turns = await transcriber.start()
    await transcriber.send(Data(count: 3_200))
    await transcriber.finish()
    for try await _ in turns {
      // Drained for how the stream ends; its elements don't matter.
    }
    // The backlog and the new audio go out together, unsliced.
    #expect(server.chunkSizes == [6_400])
  }

  @Test("a backlog longer than 1000 ms is sliced on finish, not sent whole")
  func backlogIsSlicedOnFinish() async throws {
    let server = try await FakeRealtimeServer.start()
    defer { server.stop() }
    let transcriber = RealtimeTranscriber(apiKey: "key", url: server.url)
    await transcriber.send(Data(count: 40_000))  // before start: no socket yet
    let turns = await transcriber.start()
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
    let turns = await transcriber.start()
    await transcriber.send(Data(count: 3_200))
    for try await _ in turns {
      // Drained for how the stream ends; its elements don't matter.
    }
    await transcriber.finish()
    #expect(server.chunkSizes.isEmpty)
    #expect(!server.terminated)
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
    let turns = await transcriber.start()
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
}
