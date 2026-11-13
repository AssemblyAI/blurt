import BlurtEngine
import Foundation
import UIKit

// MARK: - Lifecycle, presence and the app's signals

extension KeyboardModel {
  package func attach(to controller: UIInputViewController) {
    self.controller = controller
    observers = [
      DarwinObserver(name: BlurtShared.Signal.phase) { [weak self] in
        Task { @MainActor in self?.phaseChanged() }
      },
      DarwinObserver(name: BlurtShared.Signal.result) { [weak self] in
        Task { @MainActor in self?.resultArrived() }
      },
      DarwinObserver(name: BlurtShared.Signal.state) { [weak self] in
        Task { @MainActor in self?.stateChanged() }
      },
      DarwinObserver(name: BlurtShared.Signal.ack) { [weak self] in
        Task { @MainActor in self?.ackArrived() }
      },
    ]
  }

  /// The controller is going away: nothing may fire into a model whose
  /// keyboard is gone. The observers deregister as they are dropped.
  package func detach() {
    heartbeat?.cancel()
    heartbeat = nil
    // A leave still waiting on the app's answer ends now: the process is
    // dropping the controller, and nothing will be there to write it later.
    if leaving != nil { leave() }
    noticeDwell?.cancel()
    noticeClock?.cancel()
    termNotice?.cancel()
    cancelTicks()
    observers = []
    controller = nil
  }

  package func appeared() {
    // Back before a leave held behind a stop could land: the record this
    // appearance writes is the truth, and the pending one must not undo it.
    leaving?.cancel()
    leaving = nil
    // Without a controller (a test's model) the access stays as it was set.
    hasFullAccess = controller?.hasFullAccess ?? hasFullAccess
    // Every appearance starts with no term half-typed. The page, the case
    // and the return key are KeyboardKit's to read off the field.
    endTermField()
    dismissedSelection = nil
    termNotice?.cancel()
    termSavedAt = nil
    readSelection()
    hostBundleID = controller.flatMap(HostApp.bundleID(of:))
    KeyboardLog.appeared(
      pid: Self.pid, process: KeyboardProcess.id, controller: controllerID, fullAccess: hasFullAccess,
      host: hostBundleID)
    if hostBundleID == nil, let controller { KeyboardLog.hostUnknown(holders: HostApp.holderNames(of: controller)) }
    // Without Full Access the App Group is out of reach: the keyboard still
    // types, and says what it needs (`VoiceRowHost`), but nothing below can
    // run — and nothing from a previous appearance (a phase, a latched gate,
    // a press out) may linger over a keyboard that can't hear the app.
    guard hasFullAccess else {
      snapshot = .idle
      heldError = nil
      gate.reset()
      handshake = PressHandshake(retryDelay: handshake.retryDelay)
      showsConnecting = false
      cancelTicks()
      noticeDwell?.cancel()
      return
    }
    SharedStore.keyboardEverSeen = true
    // A press or a stop still out is not cleared here: an appearance can
    // follow another with no disappearance between (iOS does that), and its
    // answer, or its deadline, is what ends it.
    writePresence(onScreen: true)
    SharedStore.post(BlurtShared.Signal.keyboard)
    refresh()
    startHeartbeat()
    requestLexicon()
    // Words that landed while this keyboard was away, still fresh and meant
    // for whoever is up, go in now rather than waiting for a signal nobody
    // will send again.
    resultArrived()
    if SharedStore.autoDictate { autoStart() }
  }

  /// Hands-free: a dictation begins the moment the keyboard is up, as if the
  /// mic had been tapped — the same tap through the handshake, so it is a
  /// press with an ack, it latches, and the next real tap stops it. Only
  /// when the app is listening and nothing is in flight; otherwise the orb
  /// sits dimmed and the first tap opens Blurt.
  private func autoStart() {
    guard isListening, isSettled, gate.isIdle, handshake.isIdle else { return }
    tapMic()
  }

  /// The keyboard is leaving the screen. A dictation it owns must not run on
  /// without it: a recording is released (the words still land, on the
  /// clipboard if no keyboard is there to take them), one still connecting
  /// is cancelled. Words already being transcribed are left to finish — the
  /// mic is off, and a cancel would throw them away — and so is a dictation
  /// another keyboard started. Presence ends, so a result that finishes
  /// after this goes to the clipboard rather than to a keyboard nobody can
  /// see; the app's watchdog ends a dictation whose keyboard was killed.
  ///
  /// With a release or cancel of ours still out — the one just sent, or an
  /// earlier one — presence does not end yet. The command is answered by the
  /// app reading it; a record off screen is answered by its watchdog, which
  /// reads a dictation whose keyboard is gone as one to release. Posted
  /// together they race, and the watchdog's release lands on the dictation
  /// the command is already ending: a second release, logged as a dead
  /// keyboard. So the record stays on screen until the app's ack settles the
  /// stop, or `leaveGrace` passes — whichever first (`leave`).
  package func disappeared() {
    heartbeat?.cancel()
    heartbeat = nil
    noticeClock?.cancel()
    endOwnedDictation()
    KeyboardLog.disappeared(pid: Self.pid, process: KeyboardProcess.id, controller: controllerID)
    guard handshake.stopID != nil else {
      leave()
      return
    }
    leaving?.cancel()
    leaving = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.leaveGrace))
      guard !Task.isCancelled, let self else { return }
      leave()
    }
  }

  /// Presence ends: the record off screen, the older key cleared, the
  /// `keyboard` signal. Only over this controller's own record: a keyboard
  /// leaving in one host must not erase the one that just appeared in
  /// another — nor, within one process, the controller that came up as this
  /// one went down — and the older key is that record's, so it stays with it.
  package func leave() {
    leaving?.cancel()
    leaving = nil
    guard SharedStore.keyboardPresence?.controllerID == controllerID,
      SharedStore.writeKeyboardPresence(presence(onScreen: false), ifOwnedBy: KeyboardProcess.id)
    else { return }
    SharedStore.keyboardSeenAt = nil
    SharedStore.post(BlurtShared.Signal.keyboard)
  }

  /// The host app is resigning or going to the background: the field is
  /// gone, so a dictation this keyboard owns ends now rather than running
  /// into a field nobody can see. Owned only, as on leaving the screen.
  package func hostLeaving() {
    KeyboardLog.hostLeaving(process: KeyboardProcess.id, controller: controllerID)
    endOwnedDictation()
  }

  /// A recording this keyboard owns is released, a dictation still coming up
  /// is cancelled; anything else — processing, another keyboard's, a press
  /// unanswered — is left to the app and its watchdog.
  private func endOwnedDictation() {
    guard case .owned(let dictation, let phase) = handshake.state else { return }
    switch phase {
    case .recording: perform([.sendRelease(dictation: dictation)])
    case .connecting: perform([.sendCancel(dictation: dictation)])
    case .idle, .processing, .pasted, .copied, .error: break
    }
  }

  // MARK: Presence

  package static var pid: Int32 { ProcessInfo.processInfo.processIdentifier }

  package func presence(onScreen: Bool) -> KeyboardPresenceRecord {
    KeyboardPresenceRecord(
      processID: KeyboardProcess.id, controllerID: controllerID, pid: Self.pid, seenAt: now(), onScreen: onScreen)
  }

  /// The presence record, and the older keys an app that reads those still
  /// needs for one release (`keyboardSeenAt`, `keyboardInstance`).
  private func writePresence(onScreen: Bool) {
    SharedStore.writeKeyboardPresence(presence(onScreen: onScreen))
    SharedStore.keyboardSeenAt = now()
    SharedStore.keyboardInstance = KeyboardProcess.id
  }

  /// Tells the app the keyboard is on screen, so a finished dictation is
  /// handed here rather than copied to the clipboard; reads the readiness
  /// record back each beat, so an app that died (its lease lapsed) is
  /// noticed with no signal; and takes a result a missed signal left behind.
  private func startHeartbeat() {
    heartbeat?.cancel()
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        writePresence(onScreen: true)
        readListeningState()
        perform(handshake.handle(.stateChanged(listeningState), now: now()))
        if expectsResult { resultArrived() }
        try? await Task.sleep(for: .seconds(SharedStore.keyboardHeartbeatInterval))
      }
    }
  }

  /// The readiness record, and whether a press would record by it.
  package func readListeningState() {
    listeningState = SharedStore.listeningState
    isListening = listeningState?.isReady(now: now()) ?? false
  }

  /// Catches up with whatever the app last published. No haptics: nothing
  /// just happened, the keyboard merely came up. A notice (pasted, copied,
  /// error) was for the keyboard that was up when it happened, not this
  /// appearance; a dictation in flight with the app gone is over.
  private func refresh() {
    readListeningState()
    perform(handshake.handle(.stateChanged(listeningState), now: now()))
    if let ack = SharedStore.commandAck { perform(handshake.handle(.ack(ack), now: now())) }
    guard let current = SharedStore.read(PhaseSnapshot.self, forKey: BlurtShared.Key.phase) else { return }
    apply(current.isStale(now: now()) || current.noticeDwellSeconds != nil ? .idle : current, haptics: false)
  }

  // MARK: The app's signals

  /// `Signal.state`: the record changed — opened, closed, interrupted, a relaunch.
  package func stateChanged() {
    readListeningState()
    perform(handshake.handle(.stateChanged(listeningState), now: now()))
  }

  /// `Signal.ack`: the app answered a command.
  package func ackArrived() {
    guard let ack = SharedStore.commandAck else { return }
    KeyboardLog.ack(ack)
    perform(handshake.handle(.ack(ack), now: now()))
  }
}
