import AssemblyAI
import BlurtDesign
import BlurtEngine
import CoreFoundation
import Foundation
import Testing

@testable import BlurtiOS
@testable import BlurtiOSCore

/// Every number in DESIGN.md › The two processes, and every number, read off
/// its named constant: one test per row asserts the value the table
/// documents, and the last greps the table for each constant's name beside
/// the value the code holds — so the two cannot drift apart silently. A
/// constant that moves fails here until its row says the new number; a row
/// reworded away from its constant fails the same way.
@Suite("The contract's numbers, against DESIGN.md")
struct SessionContractNumbersTests {
  /// One thing the table must say: the constant as the table names it,
  /// beside its value as the table writes it, built from the live value.
  struct Row: Sendable, CustomStringConvertible {
    let rule: String
    let needle: String
    var description: String { "\(rule): \(needle)" }
  }

  private static func seconds(_ value: TimeInterval) -> String {
    value.rounded() == value ? "\(Int(value)) s" : "\(value) s"
  }

  private static func milliseconds(_ value: Duration) -> String { "\(Int(value / .milliseconds(1))) ms" }

  private static func points(_ value: CGFloat) -> String {
    value.rounded() == value ? "\(Int(value)) pt" : "\(value) pt"
  }

  private static func row(_ rule: String, _ needle: String) -> Row { Row(rule: rule, needle: needle) }

  /// The table, as the code would write it.
  static let rows: [Row] =
    [
      row("presence", "`SharedStore.appHeartbeatInterval` \(seconds(SharedStore.appHeartbeatInterval))"),
      row("presence", "`SharedStore.keyboardHeartbeatInterval` \(seconds(SharedStore.keyboardHeartbeatInterval))"),
      row("presence", "`SharedStore.presenceWindow` \(seconds(SharedStore.presenceWindow))"),
      row("keyboard presence", "`SharedStore.writeKeyboardPresence(_:ifOwnedBy:)`"),
      row("leaving with a stop out", "`KeyboardModel.leaveGrace` \(seconds(KeyboardModel.leaveGrace))"),
      row("readiness lease", "`ListeningState.lease` \(seconds(ListeningState.lease))"),
      row("window lifetime", "`ListeningWindowMachine.untilStopped` \(ListeningWindowMachine.untilStopped)"),
      row("window lifetime", "`SyncSTTLimits.maxAudioSeconds` \(seconds(SyncSTTLimits.maxAudioSeconds))"),
      row("interruption → resume", "`ListeningWindow.resumePoll` \(milliseconds(ListeningWindow.resumePoll))"),
      row("background task", "`BlurtShared.releaseBackgroundTask` \(seconds(BlurtShared.releaseBackgroundTask))"),
      row("owner watchdog", "`BlurtShared.ownerWatchdog` \(seconds(BlurtShared.ownerWatchdog))"),
      row("owner watchdog", "`SyncSTTLimits.autoReleaseSeconds` \(seconds(SyncSTTLimits.autoReleaseSeconds))"),
      row("press ack", "`BlurtShared.pressDeadline` \(seconds(BlurtShared.pressDeadline))"),
      row("stop ack", "`BlurtShared.stopDeadline` \(seconds(BlurtShared.stopDeadline))"),
      row("command retry", "`KeyboardModel.commandRetryDelay` \(milliseconds(KeyboardModel.commandRetryDelay))"),
      row("hop URLs", "`BlurtShared.fullAccessNeed`"),
      row("result freshness", "`KeyboardModel.resultFreshnessWindow` \(seconds(KeyboardModel.resultFreshnessWindow))"),
      row(
        "result delivery", "`KeyboardRelayInjector.deliveryTimeout` \(seconds(KeyboardRelayInjector.deliveryTimeout))"),
      row(
        "result delivery", "`KeyboardRelayInjector.deliveryPoll` \(milliseconds(KeyboardRelayInjector.deliveryPoll))"),
      row("result re-signal", "`KeyboardRelayInjector.resignalAfter` \(seconds(KeyboardRelayInjector.resignalAfter))"),
      row("command freshness", "`BlurtShared.commandFreshnessWindow` \(seconds(BlurtShared.commandFreshnessWindow))"),
      row("phase staleness", "`PhaseSnapshot.noticeStaleAfter` \(seconds(PhaseSnapshot.noticeStaleAfter))"),
      row("phase staleness", "`PhaseSnapshot.inFlightStaleAfter` \(seconds(PhaseSnapshot.inFlightStaleAfter))"),
      row("notice dwell", "`PhaseSnapshot.pastedDwell` \(seconds(PhaseSnapshot.pastedDwell))"),
      row("notice dwell", "`PhaseSnapshot.noticeDwell` \(seconds(PhaseSnapshot.noticeDwell))"),
      row("status line", "`VoiceNotice.transcribingPatience` \(seconds(VoiceNotice.transcribingPatience))"),
      row("status line", "`VoiceNotice.countdownWindow` \(seconds(VoiceNotice.countdownWindow))"),
      row("status line", "\"\(VoiceNotice.Copy.secondsLeft(Int(VoiceNotice.countdownWindow)))\""),
      row("held error", "`KeyboardModel.heldError`"),
      row("the line's place", "`size/line` \(points(DesignTokens.Typography.sizeLine))"),
      row("the line's place", "`VoiceBar.lineHeight`, \(String(format: "%.1f", VoiceBar.lineHeight)) pt"),
      row("the line's place", "`voicebar/height` \(points(DesignTokens.Metrics.voicebarHeight))"),
      row("the line's place", "`voice/bar-height` \(points(DesignTokens.Metrics.voiceBarHeight))"),
      row("the line's place", "`grille/bar-height` \(points(DesignTokens.Metrics.grilleBarHeight))"),
      row(
        "press delay on the mic",
        "`KeyboardInteraction.micPressDelay` \(milliseconds(KeyboardInteraction.micPressDelay))"),
      row("tap travel", "`KeyboardInteraction.tapTravel` \(points(KeyboardInteraction.tapTravel))"),
      row("tap travel", "`KeyboardInteraction.tapSlop` \(points(KeyboardInteraction.tapSlop))"),
      row("tap travel", "`KeyboardInteraction.micTravel` \(points(KeyboardInteraction.micTravel))"),
      row("tap travel", "`KeyboardInteraction.swipeDistance` \(points(KeyboardInteraction.swipeDistance))"),
      row("tap travel", "`KeyboardInteraction.swipeRatio` \(KeyboardInteraction.swipeRatio)×"),
      row("silence watchdog", "`UtteranceFeed.silenceSeconds` \(seconds(TimeInterval(UtteranceFeed.silenceSeconds)))"),
      row(
        "silence watchdog",
        "`UtteranceFeed.startGraceSeconds` \(seconds(TimeInterval(UtteranceFeed.startGraceSeconds)))"),
      row("home error", "`HomeStatus.errorDwell` \(seconds(HomeStatus.errorDwell))"),
      row("lexicon refresh", "`KeyboardModel.lexiconRefreshInterval` \(seconds(KeyboardModel.lexiconRefreshInterval))"),
      row("height change", "`Motion.heightChange` \(seconds(DesignTokens.Motion.heightChange))"),
      row("the profile", "`KeyboardProfile.glassOSMajor` \(KeyboardProfile.glassOSMajor)"),
      row("the profile", "`container/inset-min` \(points(DesignTokens.Metrics.containerInsetMin))"),
      row("term packs", "`TermPack.fileCap` \(TermPack.fileCap / 1024) KB"),
      row("term packs", "`KeyTerms.termCap` \(KeyTerms.termCap) terms"),
      row("term packs", "`TermPack.lengthCap` \(TermPack.lengthCap) characters"),
      row("idle keeper", "`PictureInPictureKeeper.frameWidth` \(PictureInPictureKeeper.frameWidth)"),
      row("idle keeper", "`frameHeight` \(PictureInPictureKeeper.frameHeight)"),
      row(
        "idle keeper",
        "`sourceSize` \(Int(PictureInPictureKeeper.sourceSize.width)) × \(PictureInPictureKeeper.sourceSize.height) pt"),
      row("log subsystem", "`BlurtShared.logSubsystem` `\(BlurtShared.logSubsystem)`"),
    ] + FailureReason.allCases.map { row("hop URLs", "`\($0.rawValue)`") }
    + [
      VoiceNotice.Copy.fullAccess, VoiceNotice.Copy.tapToOpen, VoiceNotice.Copy.interrupted,
      VoiceNotice.Copy.openToStart, VoiceNotice.Copy.micDenied, VoiceNotice.Copy.noKey, VoiceNotice.Copy.noConsent,
      VoiceNotice.Copy.micBusy, VoiceNotice.Copy.micSilent, VoiceNotice.Copy.mediaReset, VoiceNotice.Copy.network,
      VoiceNotice.Copy.stillTranscribing, VoiceNotice.Copy.copied,
    ].map { row("status line", "\"\($0)\"") }

  /// `App/BlurtiOS/DESIGN.md`, beside this test's own folder in the source tree.
  private static func design() throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("DESIGN.md")
    return try String(contentsOf: url, encoding: .utf8)
  }

  // MARK: One test per row

  @Test("presence: the beats and the window they must fall inside")
  func presence() {
    #expect(SharedStore.appHeartbeatInterval == 5)
    #expect(SharedStore.keyboardHeartbeatInterval == 4)
    #expect(SharedStore.presenceWindow == 15)
  }

  @Test("readiness lease: how long a record counts the app as there")
  func lease() {
    #expect(ListeningState.lease == 15)
  }

  @Test("press ack, stop ack and the command retry: the deadlines and the one resend inside them")
  func deadlines() {
    #expect(BlurtShared.pressDeadline == 1.2)
    #expect(BlurtShared.stopDeadline == 1.2)
    #expect(KeyboardModel.commandRetryDelay == .milliseconds(600))
    #expect(PressHandshake.defaultRetryDelay == 0.6)
    #expect(PressHandshake.defaultRetryDelay < BlurtShared.pressDeadline)
  }

  @Test("leaving with a stop out: the grace is the stop's own deadline")
  func leaveGrace() {
    #expect(KeyboardModel.leaveGrace == 1.2)
    #expect(KeyboardModel.leaveGrace == BlurtShared.stopDeadline)
  }

  @Test("owner watchdog, background task and the resume poll")
  func watchdogAndTasks() {
    #expect(BlurtShared.ownerWatchdog == 10)
    #expect(BlurtShared.ownerWatchdog > 2 * SharedStore.keyboardHeartbeatInterval)
    #expect(BlurtShared.releaseBackgroundTask == 25)
    #expect(ListeningWindow.resumePoll == .milliseconds(500))
  }

  @Test("window lifetime: until stopped is zero minutes, and a minute is sixty seconds")
  func windowLifetime() {
    #expect(ListeningWindowMachine.untilStopped == 0)
    #expect(ListeningWindowMachine.secondsPerMinute == 60)
    #expect(SyncSTTLimits.maxAudioSeconds == 1200)
  }

  @Test("command freshness and result freshness")
  func freshness() {
    #expect(BlurtShared.commandFreshnessWindow == 10)
    #expect(KeyboardModel.resultFreshnessWindow == 10)
  }

  @Test("result delivery and the re-signal")
  func delivery() {
    #expect(KeyboardRelayInjector.deliveryTimeout == 3)
    #expect(KeyboardRelayInjector.deliveryPoll == .milliseconds(250))
    #expect(KeyboardRelayInjector.resignalAfter == 1)
  }

  @Test("phase staleness: the longest dwell plus a second; the cap plus ten")
  func staleness() {
    #expect(PhaseSnapshot.noticeStaleAfter == 3)
    #expect(PhaseSnapshot.inFlightStaleAfter == 1210)
    #expect(SyncSTTLimits.autoReleaseSeconds == 1195)
  }

  @Test("notice dwell: pasted a little longer than the Mac's, copied and error longer still")
  func dwell() {
    #expect(PhaseSnapshot.pastedDwell == 1.2)
    #expect(PhaseSnapshot.noticeDwell == 2)
  }

  @Test("status line: the transcription's patience and the countdown's window")
  func statusLine() {
    #expect(VoiceNotice.transcribingPatience == 3)
    #expect(VoiceNotice.countdownWindow == 30)
  }

  @Test("the line's place: in the bar the band above the line still holds the grille")
  func linePlace() {
    #expect(DesignTokens.Typography.sizeLine == 12)
    #expect(DesignTokens.Metrics.voicebarHeight == 44)
    #expect(DesignTokens.Metrics.voiceBarHeight == 32)
    #expect(DesignTokens.Metrics.grilleBarHeight == 28)
    #expect(VoiceBar.lineHeight > DesignTokens.Typography.sizeLine)
    #expect(DesignTokens.Metrics.voicebarHeight - VoiceBar.lineHeight >= DesignTokens.Metrics.grilleBarHeight)
  }

  @Test("press delay and tap travel")
  func touches() {
    #expect(KeyboardInteraction.micPressDelay == .milliseconds(90))
    #expect(KeyboardInteraction.tapTravel == 12)
    #expect(KeyboardInteraction.tapSlop == 8)
    #expect(KeyboardInteraction.micTravel == 24)
    #expect(KeyboardInteraction.swipeDistance == 48)
    #expect(KeyboardInteraction.swipeRatio == 1.5)
  }

  @Test("silence watchdog and the home error")
  func silenceAndHome() {
    #expect(UtteranceFeed.silenceSeconds == 1)
    #expect(UtteranceFeed.startGraceSeconds == 3)
    #expect(HomeStatus.errorDwell == 3)
  }

  @Test("lexicon refresh, the height change and the profile")
  func keyboardNumbers() {
    #expect(KeyboardModel.lexiconRefreshInterval == 3600)
    #expect(DesignTokens.Motion.heightChange == 0.25)
    #expect(KeyboardProfile.glassOSMajor == 26)
    #expect(DesignTokens.Metrics.containerInsetMin == 8)
  }

  @Test("term packs: the file, the list and a term")
  func termPacks() {
    #expect(TermPack.fileCap == 64 * 1024)
    #expect(KeyTerms.termCap == 100)
    #expect(TermPack.lengthCap == 80)
  }

  @Test("idle keeper: the frame and the layer Typeless proved on a phone")
  func keeper() {
    #expect(PictureInPictureKeeper.frameWidth == 4683)
    #expect(PictureInPictureKeeper.frameHeight == 1)
    #expect(PictureInPictureKeeper.sourceSize == CGSize(width: 369, height: 0.079))
  }

  @Test("hop URLs: every reason rides the start link and comes back out of it")
  func hops() {
    #expect(FailureReason.allCases.count == 13)
    #expect(BlurtShared.fullAccessNeed == "fullAccess")
    for reason in FailureReason.allCases {
      let url = BlurtShared.startURL(reason: reason)
      #expect(BlurtShared.isStart(url) && BlurtShared.hopReason(url) == reason, "\(reason)")
    }
    #expect(BlurtShared.hopReason(BlurtShared.startURL(reason: nil)) == nil)
    #expect(BlurtShared.isSetup(BlurtShared.setupURL(need: BlurtShared.fullAccessNeed)))
  }

  @Test("log subsystem: the keyboard logs under the app's, read through one constant")
  func logSubsystem() {
    #expect(BlurtShared.logSubsystem == "com.assemblyai.blurt.iphone")
    // The test host is the app: its `init` configured the engine's identity
    // from the same constant before anything else ran.
    #expect(HostIdentity.current.subsystem == BlurtShared.logSubsystem)
    #expect(KeyboardLog.category == "Keyboard")
  }

  // MARK: The table

  @Test("DESIGN.md names every constant beside the value the code holds")
  func documented() throws {
    let design = try Self.design()
    let table = try #require(design.range(of: "## The two processes, and every number"))
    let rows = design[table.lowerBound...]
    #expect(Self.rows.count > 60)
    for row in Self.rows {
      #expect(rows.contains(row.needle), "the \(row.rule) row of The two processes lost “\(row.needle)”")
    }
  }
}
