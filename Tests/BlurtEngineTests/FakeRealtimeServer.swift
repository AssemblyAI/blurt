import Foundation
import Network
import Synchronization
import Testing

@testable import AssemblyAI

/// A one-connection WebSocket server playing the realtime API's part: it
/// records the handshake and every binary message, answers the first audio
/// with a partial and a final turn, and answers Terminate with Termination.
final class FakeRealtimeServer: Sendable {
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
    let handshakeRecorder = Recorder()
    let handshakeQueue = DispatchQueue(label: "FakeRealtimeServer.handshake")
    let websocket = NWProtocolWebSocket.Options()
    websocket.setClientRequestHandler(handshakeQueue) { subprotocols, headers in
      handshakeRecorder.log.withLock { entry in
        entry.authorization = headers.first { $0.name.lowercased() == "authorization" }?.value
      }
      return NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
    }
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let server = FakeRealtimeServer(listener: try NWListener(using: parameters), recorder: handshakeRecorder)
    server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
    await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
      let resumed = Mutex(false)
      server.listener.stateUpdateHandler = { state in
        guard case .ready = state,
          !resumed.withLock({ flag in
            let was = flag
            flag = true
            return was
          })
        else {
          return
        }
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
      guard let self, error == nil, let data else {
        return
      }
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
            on: connection
          )
          send(
            #"{"type":"Turn","turn_order":0,"transcript":"Hello.","end_of_turn":true,"speaker_label":"A"}"#,
            on: connection
          )
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
