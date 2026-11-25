import BlurtEngine
import BlurtiOSCore
import Foundation
import UIKit

/// What keeps the microphone closed between dictations, when anything does.
/// `HeldIdle` keeps nothing: the mic stays open for the window, the orange
/// dot with it. `PictureInPictureIdle` parks it under a Picture in Picture
/// keeper. The window calls the hooks at the matching effects, so a mode is
/// a plug: one whose `windowOpened` throws leaves the window held.
///
/// Every report carries the generation of the window the mode was armed for
/// (`windowOpened`'s): a keeper's start or stop lands on its own schedule, so
/// one that arrives after that window closed is reported for it, and the
/// window drops it rather than acting on the next window.
@MainActor
protocol IdleMode: AnyObject {
  /// The mode's name for the record; the machine's `idle` follows the reports.
  var kind: ListeningState.Idle { get }
  /// "A press records now", as far as the mode can tell: the source open —
  /// and, once parked, the keeper alive over it.
  var isLive: Bool { get }
  /// Where the mode reports, with the generation the report is about. The
  /// window sets it before the first `windowOpened`.
  var report: ((IdleReport, ListeningWindowMachine.Generation) -> Void)? { get set }
  /// The source is open and held under this generation: the mode may take over from here.
  func windowOpened(source: any ListeningSource, generation: ListeningWindowMachine.Generation) async throws
  /// A dictation is about to record.
  func utteranceWillBegin()
  /// A dictation ended, however it ended.
  func utteranceDidEnd()
  /// The source is about to close: let go of everything, and return only once
  /// the mode has — the next window opens after this, under whatever it kept.
  func windowClosing() async
}
