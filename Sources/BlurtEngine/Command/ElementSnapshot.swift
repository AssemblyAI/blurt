#if os(macOS)
  import ApplicationServices
  import Synchronization

  // The command key's state that outlives one step: which elements a snapshot
  // numbered, and which browser Blurt turned the enhanced-interface flag on
  // for. Apart from the system shells (`SystemVoiceCommandPerformer+*`) so
  // the coverage gate counts it: it's lock-guarded policy, not system calls.

  /// The elements one `screenContext()` numbered, and the app they belong to:
  /// a `press` or `focus` step acts on the element its number was read from,
  /// never on whatever is at that place now. Replaced by each snapshot.
  final class ElementSnapshot: Sendable {
    /// An element reference carried across threads. Unchecked because
    /// `AXUIElement` doesn't declare it, though it is an immutable CF handle
    /// the Accessibility API takes from any thread (the paste's AX reads run
    /// off the main thread too).
    struct Handle: @unchecked Sendable {
      let element: AXUIElement
    }

    private struct State {
      var pid: pid_t
      var elements: [Int: Handle]
    }

    private let state = Mutex<State?>(nil)
    /// The Electron apps already switched to building their tree: the switch
    /// costs the app two seconds of work each time it flips, so it's set
    /// once per process and left on.
    private let manualAccessibility = Mutex<Set<pid_t>>([])

    func replace(pid: pid_t, elements: [Int: Handle]) {
      state.withLock { $0 = State(pid: pid, elements: elements) }
    }

    /// The element numbered `id`, if this snapshot listed it and `pid` is
    /// still the app it was read from.
    func element(_ id: Int, pid: pid_t?) throws -> Handle {
      try state.withLock { state in
        guard let state else { throw VoiceCommandError.unknownElement(id) }
        guard state.pid == pid else { throw VoiceCommandError.screenChanged }
        guard let handle = state.elements[id] else { throw VoiceCommandError.unknownElement(id) }
        return handle
      }
    }

    /// Whether `pid` is still to be switched on: true once per process.
    func claimManualAccessibility(_ pid: pid_t) -> Bool {
      manualAccessibility.withLock { $0.insert(pid).inserted }
    }
  }

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
        state.generation += 1
        return state.generation
      }
    }

    func owns(_ pid: pid_t) -> Bool { state.withLock { $0.pid == pid } }

    /// The pid to clear, if Blurt still holds it — and `generation`, when
    /// given, is still the latest claim.
    func release(generation: Int? = nil) -> pid_t? {
      state.withLock { state in
        guard let pid = state.pid, generation == nil || generation == state.generation else { return nil }
        state.pid = nil
        return pid
      }
    }
  }
#endif
