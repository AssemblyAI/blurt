#if os(macOS)
  import Synchronization

  /// True from `claim()` the first time only, from any thread: the speaker
  /// reports levels off the main actor, many times a second. `TextReader` uses
  /// it to fire `onStart` once.
  final class OnceFlag: Sendable {
    private let claimed = Atomic(false)

    func claim() -> Bool {
      claimed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
    }
  }
#endif
