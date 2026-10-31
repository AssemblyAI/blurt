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
    await transcriber.send(Data(count: 7_000))  // two 3,200-byte chunks, 600 left over
    await transcriber.finish()
    var received: [RealtimeTurn] = []
    for try await turn in turns { received.append(turn) }

    #expect(server.authorization == "key")
    let query = Set(
      URLComponents(url: try #require(transcriber.request.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
    #expect(
      query == [
        URLQueryItem(name: "encoding", value: "pcm_s16le"), URLQueryItem(name: "sample_rate", value: "16000"),
        URLQueryItem(name: "speaker_labels", value: "true"),
      ])
    // The 600-byte tail is padded up to the documented 50 ms floor.
    #expect(server.chunkSizes == [3_200, 3_200, RealtimeTranscriber.minimumChunkBytes])
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
    for try await _ in turns {}
    #expect(server.chunkSizes == [3_200, 3_200])
  }

  @Test("a connection that fails surfaces as an error on the turns")
  func connectionFailure() async throws {
    // Nothing listens on port 9 of loopback.
    let transcriber = RealtimeTranscriber(apiKey: "key", url: URL(literal: "ws://127.0.0.1:9/v3/ws"))
    let turns = await transcriber.start()
    await #expect(throws: RealtimeError.self) {
      for try await _ in turns {}
    }
  }

  @Test("cancel ends the turns at once, without waiting for Termination")
  func cancel() async throws {
    let connection = try await connect()
    let (server, transcriber, turns) = (connection.server, connection.transcriber, connection.turns)
    defer { server.stop() }
    await transcriber.cancel()
    for try await _ in turns {}
    #expect(!server.terminated)
  }
}

/// A one-connection WebSocket server playing the realtime API's part: it
/// records the handshake and every binary message, answers the first audio
/// with a partial and a final turn, and answers Terminate with Termination.
private final class FakeRealtimeServer: Sendable {
  private struct Log {
    var authorization: String?
    var chunkSizes: [Int] = []
    var terminated = false
  }

  /// The handshake's headers land here before the server object exists:
  /// the handler has to be on the options before they go into the parameters.
  private final class Recorder: Sendable {
    let log = Mutex(Log())
  }

  private let listener: NWListener
  private let recorder: Recorder
  private let queue = DispatchQueue(label: "FakeRealtimeServer")

  var url: URL { URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/v3/ws") ?? URL(filePath: "/") }
  var authorization: String? { recorder.log.withLock { $0.authorization } }
  var chunkSizes: [Int] { recorder.log.withLock { $0.chunkSizes } }
  var terminated: Bool { recorder.log.withLock { $0.terminated } }

  private init(listener: NWListener, recorder: Recorder) {
    self.listener = listener
    self.recorder = recorder
  }

  static func start() async throws -> FakeRealtimeServer {
    let recorder = Recorder()
    let queue = DispatchQueue(label: "FakeRealtimeServer.handshake")
    let websocket = NWProtocolWebSocket.Options()
    websocket.setClientRequestHandler(queue) { subprotocols, headers in
      recorder.log.withLock { entry in
        entry.authorization = headers.first { $0.name.lowercased() == "authorization" }?.value
      }
      return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
    }
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let server = FakeRealtimeServer(listener: try NWListener(using: parameters), recorder: recorder)
    server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
    await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
      let resumed = Mutex(false)
      server.listener.stateUpdateHandler = { state in
        guard case .ready = state,
          !resumed.withLock({
            let was = $0
            $0 = true
            return was
          })
        else { return }
        ready.resume()
      }
      server.listener.start(queue: server.queue)
    }
    return server
  }

  func stop() { listener.cancel() }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection)
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self, error == nil, let data else { return }
      let metadata =
        context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
      switch metadata?.opcode {
      case .binary:
        let first = recorder.log.withLock { entry in
          entry.chunkSizes.append(data.count)
          return entry.chunkSizes.count == 1
        }
        if first {
          send(
            #"{"type":"Turn","turn_order":0,"transcript":"hello","end_of_turn":false,"speaker_label":"A"}"#,
            on: connection)
          send(
            #"{"type":"Turn","turn_order":0,"transcript":"Hello.","end_of_turn":true,"speaker_label":"A"}"#,
            on: connection)
        }
      case .text where String(data: data, encoding: .utf8)?.contains("Terminate") == true:
        recorder.log.withLock { $0.terminated = true }
        send(#"{"type":"Termination","audio_duration_seconds":0.3,"session_duration_seconds":1}"#, on: connection)
      default:
        break
      }
      receive(on: connection)
    }
  }

  private func send(_ text: String, on connection: NWConnection) {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
    connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
  }
}
