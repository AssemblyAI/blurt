import AppKit
import BlurtEngine
import Foundation

// The app shell's one path that inserts text with no dictation behind it:
// another process on this Mac hands over a finished transcript and Blurt lands
// it where the user is typing. `LoopbackInsertListener` owns the socket, the
// wire format and the security posture; this is the wiring that gives it the
// pipeline's own injector.
//
// An extension in its own file for the same reason as
// `AppCoordinator+UITesting.swift`: the coordinator is at the file-length
// budget, and this is a feature beside the pipeline rather than part of it.

extension AppCoordinator {
  /// Builds the local-insertion listener and brings it into line with the
  /// switch. Nothing is bound unless the user turned it on in Settings ›
  /// Advanced — see `LoopbackInsertListener` for the socket, the token, and why
  /// the default is off.
  func startLoopbackListener() {
    #if UITEST_HOOKS
      // A UI-test run must not bind a socket in the developer's own Application
      // Support folder. The launch reset sweeps the engine's `PersistedSettings`
      // roster, which these app-side keys are deliberately not part of, so a
      // machine with the switch on would otherwise listen for the whole suite.
      if UITestMode.isActive { return }
    #endif
    let listener = LoopbackInsertListener { [weak self] text in
      await self?.insertFromLocalClient(text) ?? .failed
    }
    loopback = listener
    listener.sync()
  }

  /// Called when the Advanced pane's local-insertion switch or token changes,
  /// so the listener comes up, goes away, or picks up the new token without a
  /// relaunch.
  func loopbackInsertChanged() {
    loopback?.sync()
  }

  /// Inserts text a local client handed over, through the injector the
  /// dictation pipeline pastes with — the same instance, deliberately, since
  /// the spacing memory, the pasteboard save/restore and the chain that
  /// serializes two pastes are all `KeyInjector`'s per-instance state.
  ///
  /// The target is pinned to whatever is frontmost *now*, which here is the
  /// moment a trigger press would have captured: the words arrive already
  /// transcribed, so there is no earlier one. `priorText` and `windowTitle` stay
  /// nil because the Accessibility reads that fill them are the engine's
  /// (`FocusCapture`) and internal to it — worth neither a second
  /// implementation out here nor a second copy of the password-field guard that
  /// comes with the real one. `InsertionSeparator` therefore runs with no basis
  /// and adds no leading space; see the PR that introduced this for the
  /// one-line engine change that would close that gap.
  ///
  /// A refused paste is not a lost transcript: `KeyInjector` leaves the text on
  /// the clipboard whenever it can't type it, which is what `.copied` reports.
  private func insertFromLocalClient(_ text: String) async -> LoopbackInsertOutcome {
    let focus = NSWorkspace.shared.frontmostApplication.map {
      CapturedFocus(pid: $0.processIdentifier, processName: $0.localizedName)
    }
    await injector.setTarget(focus)
    do {
      try await injector.insert(text, after: nil, windowTitle: nil)
      return .inserted
    } catch BlurtError.noEditableTarget, BlurtError.targetAppLost {
      return .copied
    } catch {
      HostIdentity.current.logger("loopback").error(
        "handed-over text was not inserted: \(error.localizedDescription, privacy: .public)")
      return .failed
    }
  }
}
