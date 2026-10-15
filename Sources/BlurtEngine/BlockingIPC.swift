import Dispatch

/// Where blocking cross-process work runs: an Accessibility read, or a
/// pasteboard read that can make another app produce promised data. Each can
/// block its thread for seconds against a beachballing app (the AX messaging
/// timeout bounds each round trip, not the whole read), so none of it may run
/// on the Swift cooperative pool, which is sized to the core count and does
/// not overcommit: a few such calls could park every cooperative thread and
/// stall every actor. Dispatch overcommits, so a blocked call costs a thread
/// instead of the pool. Concurrent, so a hung read can't delay the next one.
///
/// Its own type rather than a member of `DictationSession`, because the press
/// pipeline is one of several callers: read-aloud's selection read and its
/// clipboard copy (`SelectionSpeaker`, `SelectionCopy`) run here too.
enum BlockingIPC {
  static let queue = DispatchQueue(
    label: HostIdentity.current.queueLabel("BlockingIPC"), qos: .userInitiated, attributes: .concurrent)

  /// Runs `work` on `queue` and awaits it: the awaitable form of
  /// `queue.async`, for a caller that needs the result.
  static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work()) }
    }
  }
}
