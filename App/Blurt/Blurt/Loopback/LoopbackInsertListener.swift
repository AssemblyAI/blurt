import BlurtEngine
import Foundation
import Network
import OSLog

/// What one handed-over line did, as the single word the client reads back.
///
/// `copied` is not a failure: `KeyInjector` leaves the text on the clipboard
/// whenever it can't paste it (nothing editable focused, the target app gone),
/// so the words survive and the sender can say so instead of retrying.
enum LoopbackInsertOutcome: String {
  case inserted = "OK"
  case copied = "COPIED"
  case failed = "ERR insert-failed"
}

/// Accepts finished text from another process on this Mac and inserts it the
/// way a dictation is inserted.
///
/// The point is that Blurt stops being re-implemented: a companion that already
/// has a transcript — a pocket recorder relaying over USB, a script, a shortcut
/// — hands the string over instead of driving the clipboard and ⌘V itself, and
/// inherits the injector's focus pinning, its pasteboard save/restore, its
/// editable-target check, its `InsertionSeparator` spacing and its paste chain,
/// which serializes against a dictation landing at the same moment.
///
/// ## Wire format
///
/// A `SOCK_STREAM` Unix domain socket at `LoopbackInsertStore.socketURL`.
/// Newline-delimited UTF-8, one message per `\n`-terminated line:
///
/// ```text
/// <token>\n     the first line of every connection: the Settings token, alone
/// <text>\n      one transcript per line, as many as you like
/// ```
///
/// Inside a transcript line, `\n` means a newline and `\\` means a backslash —
/// a transcript is often several lines, and a bare newline is the frame. Any
/// other backslash pair is passed through untouched, both characters.
///
/// Blurt answers one line per line received: `OK` (authenticated, or pasted),
/// `COPIED` (on the clipboard, nothing editable was focused), or `ERR <reason>`
/// — `unauthorized`, `not-utf8`, `line-too-long`, `empty`, `insert-failed`.
/// Every `ERR` but `empty` and `insert-failed` also closes the connection.
///
/// ## Security posture
///
/// Off by default, behind the Advanced pane's switch, and authenticated. The
/// three layers, weakest claim last:
///
/// 1. **A Unix socket, not a TCP port.** Nothing is bound on `127.0.0.1`, so
///    there is no port for a browser page or another machine to reach — the
///    socket is a file, and the kernel gates it on the filesystem. It sits
///    under `~/Library` (mode 0700 on macOS) and the node is chmodded 0600 the
///    moment it is ready, so no other user on this Mac can open it.
/// 2. **Off unless switched on.** A fresh install binds nothing.
/// 3. **A shared token**, minted on first enable and sent as the first line.
///    This is defence in depth and should not be read as more: a process
///    running as this user can read the token out of `UserDefaults` as easily
///    as Blurt can. What it does buy is that a client has to be *configured* on
///    purpose, so nothing reaches the injector by stumbling onto a socket, and
///    revoking access is a button rather than a reinstall.
///
/// What none of that defends against is code already running as this user that
/// wants in — on a Mac that is a wide door regardless (the same process could
/// ask for Accessibility itself). The switch is what keeps the door shut for
/// everyone who has no use for it.
final class LoopbackInsertListener {
  /// Most clients open one connection and keep it; the cap is there so a
  /// misbehaving one can't accumulate them.
  static let maxConnections = 4
  /// A single line may not exceed this before its newline arrives, so a client
  /// that never sends one can't make Blurt buffer without bound. Generous
  /// against the longest thing anyone dictates.
  static let maxLineBytes = 64 * 1024
  /// How much one `receive` may hand back. Lines are short; this only bounds
  /// the chunk, never the message.
  static let readChunkBytes = 16 * 1024

  /// Delivers one transcript and reports what became of it. Supplied by
  /// `AppCoordinator`, which owns the injector the dictation pipeline pastes
  /// through — the same instance, deliberately, since the spacing memory and
  /// the paste chain are its per-instance state.
  private let insert: (String) async -> LoopbackInsertOutcome
  private let store: LoopbackInsertStore
  private let log = HostIdentity.current.logger("loopback")

  private var listener: NWListener?
  /// The token the running listener was started with, so `sync()` can tell a
  /// regenerate apart from a no-op.
  private var activeToken: String?
  private var connections: [ObjectIdentifier: LoopbackInsertConnection] = [:]

  init(store: LoopbackInsertStore = LoopbackInsertStore(), insert: @escaping (String) async -> LoopbackInsertOutcome) {
    self.store = store
    self.insert = insert
  }

  /// Brings the listener into line with the switch and the token — called at
  /// launch and whenever the Advanced pane changes either, so neither needs a
  /// relaunch. A regenerated token restarts the listener; an unchanged one is a
  /// no-op.
  func sync() {
    let token = store.token
    guard store.isEnabled, !token.isEmpty else {
      stop()
      return
    }
    guard activeToken != token else { return }
    stop()
    start(token: token)
  }

  /// Closes every connection and unbinds, leaving no socket file behind for the
  /// next run to trip over.
  func stop() {
    // Snapshot first: closing a connection calls back into `connections`.
    let open = connections
    connections.removeAll()
    for connection in open.values { connection.close() }
    listener?.cancel()
    listener = nil
    activeToken = nil
    try? FileManager.default.removeItem(at: LoopbackInsertStore.socketURL)
  }

  private func start(token: String) {
    let url = LoopbackInsertStore.socketURL
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      log.error("loopback socket directory unavailable: \(error.localizedDescription, privacy: .public)")
      return
    }
    // A node left behind by a process that died without unbinding would fail
    // the bind below with EADDRINUSE, and the feature would stay dead until
    // someone deleted a file they have no reason to know about.
    try? FileManager.default.removeItem(at: url)

    // The protocol stack is ignored for a `unix` endpoint — what makes this a
    // Unix domain socket is `requiredLocalEndpoint`, which `NWListener` binds
    // instead of allocating a port.
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .unix(path: url.path(percentEncoded: false))
    do {
      let listener = try NWListener(using: parameters)
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in self?.listenerStateChanged(state) }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in self?.accept(connection, token: token) }
      }
      listener.start(queue: .main)
      self.listener = listener
      activeToken = token
    } catch {
      log.error("loopback listener failed to start: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func listenerStateChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      // Narrow the node to this user before anything can connect. `~/Library`
      // is already 0700, so this is the second lock rather than the first —
      // which is what makes the brief window between bind and here harmless.
      let path = LoopbackInsertStore.socketURL.path(percentEncoded: false)
      if chmod(path, 0o600) != 0 {
        log.error("loopback socket could not be narrowed to this user; refusing to listen")
        stop()
        return
      }
      log.info("loopback insertion listening on \(path, privacy: .public)")
    case .failed(let error):
      log.error("loopback listener failed: \(error.localizedDescription, privacy: .public)")
      stop()
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection, token: String) {
    guard listener != nil, connections.count < Self.maxConnections else {
      connection.cancel()
      return
    }
    let handler = LoopbackInsertConnection(
      connection: connection, token: token, insert: insert,
      onClose: { [weak self] handler in self?.connections[ObjectIdentifier(handler)] = nil })
    connections[ObjectIdentifier(handler)] = handler
    handler.start()
  }
}

/// One client connection: reads `\n`-framed lines, checks the first against the
/// token, and hands every later one to the insert closure — one at a time, in
/// the order they arrived.
///
/// The next `receive` is armed only once the current chunk's lines have all
/// been inserted, which is both the ordering guarantee and the backpressure: a
/// client that floods the socket waits on the paste rather than queueing
/// transcripts that would land out of order.
private final class LoopbackInsertConnection {
  private let connection: NWConnection
  private let token: String
  private let insert: (String) async -> LoopbackInsertOutcome
  private let onClose: (LoopbackInsertConnection) -> Void

  private var buffer = Data()
  private var isAuthenticated = false
  private var isClosed = false

  init(
    connection: NWConnection, token: String, insert: @escaping (String) async -> LoopbackInsertOutcome,
    onClose: @escaping (LoopbackInsertConnection) -> Void
  ) {
    self.connection = connection
    self.token = token
    self.insert = insert
    self.onClose = onClose
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        Task { @MainActor in self?.close() }
      default:
        break
      }
    }
    connection.start(queue: .main)
    receiveNext()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    connection.cancel()
    onClose(self)
  }

  private func receiveNext() {
    guard !isClosed else { return }
    connection.receive(
      minimumIncompleteLength: 1, maximumLength: LoopbackInsertListener.readChunkBytes
    ) { [weak self] data, _, isComplete, error in
      Task { @MainActor in
        await self?.received(data, isComplete: isComplete, failed: error != nil)
      }
    }
  }

  private func received(_ data: Data?, isComplete: Bool, failed: Bool) async {
    guard !isClosed else { return }
    if let data { buffer.append(data) }
    guard buffer.count <= LoopbackInsertListener.maxLineBytes else {
      closeAfterReplying("ERR line-too-long")
      return
    }
    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
      let line = Data(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
      // `false` means this connection is finished and `handle` has already
      // arranged the hang-up (`closeAfterReplying`), so stop reading and let
      // the refusal flush rather than cancelling out from under it.
      guard await handle(line: line), !isClosed else { return }
    }
    if isComplete || failed {
      close()
    } else {
      receiveNext()
    }
  }

  /// Handles one framed line. `false` means the connection is finished and the
  /// hang-up is already on its way out behind the reply.
  private func handle(line: Data) async -> Bool {
    guard let raw = String(data: line, encoding: .utf8) else {
      closeAfterReplying("ERR not-utf8")
      return false
    }
    // Accept CRLF framing too, so a client written against a line-oriented
    // socket library doesn't fail its token check over an invisible byte.
    let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
    guard isAuthenticated else {
      guard LoopbackInsertWire.matches(token: token, presented: text) else {
        closeAfterReplying("ERR unauthorized")
        return false
      }
      isAuthenticated = true
      reply("OK")
      return true
    }
    let transcript = LoopbackInsertWire.unescape(text)
    guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // Nothing to paste, but nothing wrong with the client either: a blank
      // line keeps the connection.
      reply("ERR empty")
      return true
    }
    reply(await insert(transcript).rawValue)
    return true
  }

  private func reply(_ line: String) {
    connection.send(content: Data("\(line)\n".utf8), completion: .idempotent)
  }

  /// Sends a final line and only then hangs up. Cancelling straight after an
  /// `.idempotent` send discards what is still buffered, so a client refused
  /// for its token used to see the connection drop with no reason on it.
  private func closeAfterReplying(_ line: String) {
    guard !isClosed else { return }
    connection.send(
      content: Data("\(line)\n".utf8),
      completion: .contentProcessed { [weak self] _ in
        Task { @MainActor in self?.close() }
      })
  }
}
