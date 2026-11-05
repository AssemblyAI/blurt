import AVFoundation
import BlurtEngine
import BlurtiOSCore
import Foundation
import UIKit

// MARK: - The listening window, from the app's side
//
// Every way to the microphone — the switch, the keyboard's hop, the app
// coming to the front — asks the window here, and the window asks back when
// a dictation has to end for it.

extension DictationCoordinator {
  /// Asks for a window. Foreground only — this is what `blurt://start`
  /// arrives to do; the machine refuses an ask from the background and
  /// refreshes a window already open. Not without a key: an open window
  /// whose every press fails quietly would look like a keyboard that ignores
  /// taps.
  func startListening() async {
    apiKey.refreshStatus()
    needsKey = !apiKey.hasAPIKey
    guard !needsKey else { return }
    // Every way to the microphone comes through here — the switch, the
    // keyboard's `blurt://start`, and the app coming to the front — so this
    // one gate covers them all.
    needsConsent = !AIConsent.isGranted()
    guard !needsConsent else { return }
    guard await AVAudioApplication.requestRecordPermission() else {
      microphoneDenied = true
      return
    }
    microphoneDenied = false
    window.open()
  }

  /// The app came to the front: a paused window may start its microphone
  /// again now, and — when nothing needs asking first and the user hasn't
  /// turned it off — a session comes on by itself, so using the Blurt
  /// keyboard needs no switch (`SessionAutoStart`).
  func startSessionIfReady() async {
    let turnedOff = SessionAutoStart.isTurnedOff()
    window.foregrounded(turnedOff: turnedOff)
    guard
      SessionAutoStart.shouldStart(
        windowOpen: window.isOn, hasKey: apiKey.hasAPIKey, consented: AIConsent.isGranted(),
        micGranted: AVAudioApplication.shared.recordPermission == .granted, turnedOff: turnedOff)
    else { return }
    await startListening()
  }

  /// The switch turned on: the user asked for a session, so Blurt goes back to
  /// turning one on by itself.
  func turnSessionOn() async {
    SessionAutoStart.setTurnedOff(false)
    await startListening()
  }

  /// The switch turned off: closed now, and left off until the user asks again.
  func turnSessionOff() {
    SessionAutoStart.setTurnedOff(true)
    stopListening()
  }

  /// The user agreed in `ConsentView`: record it and carry on opening the
  /// window they asked for.
  func grantConsent() async {
    AIConsent.grant()
    needsConsent = false
    await startListening()
  }

  /// Closes the window. A dictation in flight is cancelled first, upload and
  /// all (the machine's `endUtterance(keepWords: false)`): closing the feed
  /// alone would end the utterance and let the request complete, transcribing
  /// (and billing) audio nobody asked for.
  func stopListening() {
    window.close()
  }

  /// Settings changed the window's length: the window that is open takes it.
  func windowMinutesChanged() {
    window.windowMinutesChanged()
  }

  /// The window is pausing or closing with a dictation in flight. Its words
  /// still count when the window ends on its own — its time ran out, a call
  /// took the microphone — so that releases; the user's own stop cancels.
  /// The session decides on its turn: a recording is released and its words
  /// land (on the clipboard when no keyboard is up); a mic still coming up
  /// finishes, then releases a capture too short to transcribe; anything
  /// later is untouched. Under a background task, since the host app may
  /// have put Blurt in the background by now; the next terminal phase ends it.
  func endUtterance(keepWords: Bool) async {
    window.backgroundTasks.begin(Self.releaseTask)
    if keepWords {
      await session.release()
    } else {
      await session.cancel()
    }
  }

  func handle(_ url: URL) {
    if TermPack.looksLikePack(url) {
      if let pack = TermPack.from(url) {
        pendingTermPack = pack
      } else {
        termPackUnreadable = true
      }
      return
    }
    if BlurtShared.isSetup(url) {
      let need = Self.need(of: url)
      Self.log.notice("setup hop need=\(need ?? "none", privacy: .public)")
      DeviceTrace.record("hop", ["need": need ?? ""])
      needsFullAccess = need == BlurtShared.fullAccessNeed
      return
    }
    guard BlurtShared.isStart(url) else { return }
    let reason = BlurtShared.hopReason(url)
    Self.log.notice("start hop reason=\(reason?.rawValue ?? "none", privacy: .public)")
    DeviceTrace.record("hop", ["reason": reason?.rawValue ?? ""])
    startedFromKeyboard = UIApplication.shared.applicationState != .active
    // The keyboard's mic asked for a session: that undoes an earlier off.
    SessionAutoStart.setTurnedOff(false)
    Task { await startListening() }
  }

  /// `blurt://setup?need=<what>`: what the keyboard is missing.
  private static func need(of url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "need" }?.value
  }
}
