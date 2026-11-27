#if os(macOS)
  import Foundation
  import Synchronization

  /// Which Chromium browser Blurt turned `AXEnhancedUserInterface` on for,
  /// so it clears only what it set — never a flag another tool (Homerow,
  /// Vimac) turned on — and so a lingering clear from an earlier command
  /// can't undo a newer one's.
  final class EnhancedInterface: Sendable {
    private struct State {
      var pid: pid_t?
      var generation = 0
    }

    private let state = Mutex(State())

    /// Records `pid` as Blurt's to clear; answers this claim's generation.
    func claim(_ pid: pid_t) -> Int {
      state.withLock { state in
        state.pid = pid
        state.generation += 1  // mutate-ok: generations are only compared for equality; counting down is as unique
        return state.generation
      }
    }

    func owns(_ pid: pid_t) -> Bool { state.withLock { $0.pid == pid } }

    /// The pid to clear, if Blurt still holds it — and `generation`, when
    /// given, is still the latest claim.
    func release(generation: Int? = nil) -> pid_t? {
      state.withLock { state in
        guard let pid = state.pid, generation == nil || generation == state.generation else {
          return nil
        }
        state.pid = nil
        return pid
      }
    }
  }
#endif
