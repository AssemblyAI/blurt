/// The application that was frontmost when the user pressed the trigger — the
/// paste target, and the context's app name.
///
/// A pid (an `Int32`, which is what `pid_t` is) and a display name rather than
/// an `NSRunningApplication`, so the value crosses the engine's public seams
/// (`InjectorProtocol.setTarget`, `DictationSession.HostFocusCapture`) on every
/// platform the engine builds for. `KeyInjector` resolves the process handle
/// from the pid on macOS; a host on iOS has no process to name — a keyboard
/// cannot see which app hosts it — and passes nil.
public struct CapturedFocus: Sendable {
  public let pid: Int32
  public let processName: String?

  public init(pid: Int32, processName: String?) {
    self.pid = pid
    self.processName = processName
  }
}
