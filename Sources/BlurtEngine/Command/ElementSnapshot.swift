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

    /// Whether `pid` is still to be switched on: true once per process. Left
    /// on, unlike Chromium's `AXEnhancedUserInterface` (`EnhancedInterface`),
    /// which is cleared after every command: that flag also changes how
    /// Chromium behaves (window animations, a tree rebuilt from scratch each
    /// time), while `AXManualAccessibility` only keeps Electron's tree built,
    /// as it would be for VoiceOver — so one flag per process, cleared when
    /// the app quits, beats rebuilding the tree for every command.
    func claimManualAccessibility(_ pid: pid_t) -> Bool {
      manualAccessibility.withLock { $0.insert(pid).inserted }
    }
  }
#endif
