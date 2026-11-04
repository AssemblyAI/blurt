import BlurtEngine
import Foundation

/// The one line of text under the keyboard's mic, and what a tap on the mic
/// does while it shows. Pure: the keyboard hands in what it knows — Full
/// Access, the app's readiness record, the phase it published, the press it
/// has in flight — and gets back the line or nil (ready and idle is wordless,
/// as Apple's). The rows are DESIGN.md's status-line table; the strings live
/// in `Copy` so the document can quote them.
package nonisolated enum VoiceNotice {
  /// The keyboard's press, as much of it as the line needs: a mirror of the
  /// handshake's states, so this unit never depends on the handshake itself.
  package nonisolated enum Handshake: Equatable, Sendable {
    case idle
    /// A press sent and unanswered. Its age is the deadline's business, not
    /// the line's: nothing is said until the deadline resets the gate.
    case pressing(since: Date)
    /// The press was answered and the dictation is this keyboard's.
    case owned
    /// A release or cancel sent and unanswered.
    case stopping(since: Date)
    /// The press was refused, or expired unanswered: the line says why, and
    /// the next tap hops.
    case unready(FailureReason)
  }

  /// What a tap on the mic does while the line shows, for the view to route.
  package nonisolated enum Tap: Equatable, Sendable {
    /// The usual press (a stop while recording).
    case press
    /// Opens the app, saying why (`BlurtShared.startURL`).
    case hop(FailureReason?)
    /// Opens the app's setup (`BlurtShared.setupURL`).
    case setup
    /// Nothing to do but wait.
    case none
  }

  package nonisolated struct Line: Equatable, Sendable {
    package let text: String
    package let tapOpens: Tap

    package init(text: String, tapOpens: Tap) {
      self.text = text
      self.tapOpens = tapOpens
    }
  }

  package nonisolated struct Input: Sendable {
    package let hasFullAccess: Bool
    /// The app's readiness record; nil when no app has ever written one.
    package let state: ListeningState?
    package let snapshot: PhaseSnapshot
    package let handshake: Handshake
    package let now: Date
    /// When a held recording auto-releases, counted from `recordingSince`.
    package let autoReleaseSeconds: TimeInterval

    package init(
      hasFullAccess: Bool, state: ListeningState?, snapshot: PhaseSnapshot, handshake: Handshake, now: Date,
      autoReleaseSeconds: TimeInterval = SyncSTTLimits.autoReleaseSeconds
    ) {
      self.hasFullAccess = hasFullAccess
      self.state = state
      self.snapshot = snapshot
      self.handshake = handshake
      self.now = now
      self.autoReleaseSeconds = autoReleaseSeconds
    }
  }

  /// Every sentence the line can show, in one place.
  package nonisolated enum Copy {
    package static let fullAccess = "Allow Full Access in Settings"
    package static let tapToOpen = "Tap to open Blurt"
    package static let interrupted = "Mic paused by a call — tap to open Blurt"
    package static let openToStart = "Open Blurt to start"
    package static let micDenied = "Allow the microphone in Settings"
    package static let noKey = "Add your API key in Blurt"
    package static let noConsent = "Open Blurt to continue"
    package static let micBusy = "Another app has the mic — tap to open Blurt"
    package static let micSilent = "The mic went silent — tap to open Blurt"
    package static let mediaReset = "Audio was reset — tap to open Blurt"
    package static let network = "No connection — tap to try again"
    package static let stillTranscribing = "Still transcribing…"
    package static let copied = "Copied to the clipboard"

    /// The countdown to the auto-release: "30 s left".
    package static func secondsLeft(_ seconds: Int) -> String { "\(seconds) s left" }
  }

  /// How long the words may take before the line says they are still being
  /// made, counted from the phase's `at`.
  package static let transcribingPatience: TimeInterval = 3
  /// How much of a recording's last stretch before the auto-release the
  /// countdown covers.
  package static let countdownWindow: TimeInterval = 30

  package static func line(for input: Input) -> Line? {
    // Without Full Access there is no App Group to read, so nothing else
    // below can be true: the note is the key.
    guard input.hasFullAccess else { return Line(text: Copy.fullAccess, tapOpens: .setup) }
    // A notice or a live phase is about this moment and beats the standing
    // readiness line; the view's dwell settles it back to idle afterwards.
    if let notice = noticeLine(for: input) { return notice }
    guard let reason = readiness(for: input) else { return nil }
    return Line(text: reason.line, tapOpens: tap(for: reason))
  }

  /// Why a press would not record now, or nil while one would — or while the
  /// handshake has a press in flight, which is its own business to resolve.
  private static func readiness(for input: Input) -> FailureReason? {
    switch input.handshake {
    case .pressing, .owned, .stopping: return nil
    case .unready(let reason): return reason
    case .idle: break
    }
    guard let state = input.state else { return .sessionOff }
    return state.notReady(now: input.now)
  }

  /// The line the phase itself asks for, if any.
  private static func noticeLine(for input: Input) -> Line? {
    let snapshot = input.snapshot
    switch snapshot.state {
    case .error:
      if let reason = snapshot.reason { return Line(text: reason.line, tapOpens: tap(for: reason)) }
      // The engine's own words, when the failure has no name; the glyph
      // alone says it when it has no words either.
      guard let message = snapshot.message else { return nil }
      let tap = readiness(for: input).map(tap(for:)) ?? .press
      return Line(text: message, tapOpens: tap)
    case .copied:
      return Line(text: Copy.copied, tapOpens: .press)
    case .processing:
      guard input.now.timeIntervalSince(snapshot.at) > transcribingPatience else { return nil }
      return Line(text: Copy.stillTranscribing, tapOpens: .none)
    case .recording:
      guard let since = snapshot.recordingSince else { return nil }
      let remaining = input.autoReleaseSeconds - input.now.timeIntervalSince(since)
      guard remaining <= countdownWindow else { return nil }
      // A countdown says "1 s left" until the moment it is over, never a
      // negative number once the engine has stopped on its own.
      return Line(text: Copy.secondsLeft(Int(max(remaining, 0).rounded(.up))), tapOpens: .press)
    case .idle, .connecting, .pasted:
      return nil
    }
  }

  /// What a tap does about a reason: a hop to the app for every one but a
  /// failed request, which the next press simply retries.
  package static func tap(for reason: FailureReason) -> Tap {
    switch reason {
    case .network: .press
    case .sessionOff, .needsForeground, .opening, .interrupted, .micBusy, .micSilent, .mediaReset, .noKey,
      .noConsent, .micDenied, .unanswered, .suspended:
      .hop(reason)
    }
  }
}

nonisolated extension FailureReason {
  /// The one sentence the keyboard shows for this reason (`VoiceNotice`).
  package var line: String {
    switch self {
    case .sessionOff, .unanswered, .suspended: VoiceNotice.Copy.tapToOpen
    case .needsForeground, .opening: VoiceNotice.Copy.openToStart
    case .interrupted: VoiceNotice.Copy.interrupted
    case .micBusy: VoiceNotice.Copy.micBusy
    case .micSilent: VoiceNotice.Copy.micSilent
    case .mediaReset: VoiceNotice.Copy.mediaReset
    case .noKey: VoiceNotice.Copy.noKey
    case .noConsent: VoiceNotice.Copy.noConsent
    case .micDenied: VoiceNotice.Copy.micDenied
    case .network: VoiceNotice.Copy.network
    }
  }
}
