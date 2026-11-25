#if os(macOS)
  import Synchronization

  /// True from `claim()` the first time only, from any thread: the speaker
  /// reports levels off the main actor, many times a second. `TextReader` uses
  /// it to fire `onStart` once.
  final class OnceFlag: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
      claimed.withLock { claimed in
        defer { claimed = true }
        return !claimed
      }
    }
  }
#endif
