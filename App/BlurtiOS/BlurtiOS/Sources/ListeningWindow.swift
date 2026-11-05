import BlurtEngine
import BlurtiOSCore
import Foundation
import Observation
import UIKit

/// The stretch of time the app keeps the microphone open so the keyboard can
/// start a dictation without bringing the app forward — Wispr calls the same
/// thing a "Flow Session".
///
/// Opening needs the app in front (iOS refuses to start capture from the
/// background), which is why the keyboard's mic key opens `blurt://start` when
/// no window is open. Once open, `UIBackgroundModes: audio` plus the active
/// audio session keep it alive after the user swipes back; the idle mode
/// (`IdleMode`) says what the mic does between dictations. The window's
/// lifetime counts from the last word (`SharedStore.windowMinutes`; 0 means
/// until stopped); a call, Siri or another app taking the microphone pauses
/// it rather than ending it, and it resumes when they are done or when Blurt
/// is next in front.
///
/// This is the interpreter of `ListeningWindowMachine`, which owns every rule:
/// what happened arrives here as an event — from the coordinator, the source,
/// the audio session, the timers, the idle mode — and what the machine asks
/// for is carried out in order (`ListeningWindow+Effects.swift`). Events go
/// through one serial loop, so an effect still running (the source opening)
/// is never interleaved with the next event's. Everything the machine
/// publishes is the keyboard's whole picture of the window
/// (`SharedStore.publish`), and is logged as one line per transition.
@MainActor
@Observable
final class ListeningWindow {
  typealias Machine = ListeningWindowMachine
  static let log = HostIdentity.current.logger("ListeningWindow")
  /// How long a resume waits for the source to come back on its own after an
  /// interruption ends, polling, before the window stays interrupted until
  /// the next foreground (DESIGN.md).
  static let resumePoll: Duration = .milliseconds(500)
  static let resumePollStep: Duration = .milliseconds(50)
  /// The background task held through an interruption, so the dictation it
  /// cut short can still release and land.
  static let interruptionTask = "blurt.interruption"

  let source: any ListeningSource
  let launchID: UUID
  @ObservationIgnored let audioSession: any AudioSessionControlling
  @ObservationIgnored let appState: () -> UIApplication.State
  /// Shared with the coordinator, which holds its release task beside the
  /// window's interruption task.
  @ObservationIgnored let backgroundTasks: any BackgroundTasking
  @ObservationIgnored let clock: any Clock<Duration>
  @ObservationIgnored let idle: any IdleMode
  @ObservationIgnored private(set) var machine: Machine
  /// The last record published: what the keyboard reads, and what the home
  /// screen draws the session from. Set only by `publish`
  /// (`ListeningWindow+Effects.swift`; internal because the split keeps
  /// `private(set)` out).
  var state: ListeningState?
  /// Why the last open or resume failed, in the source's own words, for the
  /// home screen; nil once a window is opening or open again.
  var lastError: String?
  /// Run before the source closes or pauses with a dictation in flight: the
  /// coordinator ends it through the session — released with its words, or
  /// cancelled — while the feed still holds its audio.
  @ObservationIgnored var onEndingUtterance: ((_ keepWords: Bool) async -> Void)?
  /// Run when a published record's window differs from the last one's.
  @ObservationIgnored var onStateChanged: ((ListeningState) -> Void)?
  @ObservationIgnored private let inbox: AsyncStream<Input>.Continuation
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var readers: [Task<Void, Never>] = []
  @ObservationIgnored var expiry: Task<Void, Never>?
  @ObservationIgnored var heartbeat: Task<Void, Never>?
  /// The audio session's `.began` is still on: the source's own
  /// `interrupted` then says nothing new, and deactivating would throw.
  @ObservationIgnored var sessionInterrupted = false
  /// `activateSession` threw: the open that follows fails rather than
  /// starting a source under a session that isn't there.
  @ObservationIgnored var activationFailed = false

  /// What the loop takes: the machine's events, and the heartbeat's turn.
  enum Input: Sendable {
    case event(Machine.Event)
    case heartbeat
  }

  init(
    source: any ListeningSource, audioSession: any AudioSessionControlling,
    appState: @escaping () -> UIApplication.State, backgroundTasks: any BackgroundTasking,
    clock: any Clock<Duration>, idle: any IdleMode, launchID: UUID = UUID()
  ) {
    self.source = source
    self.audioSession = audioSession
    self.appState = appState
    self.backgroundTasks = backgroundTasks
    self.clock = clock
    self.idle = idle
    self.launchID = launchID
    machine = Machine(
      launchID: launchID, windowMinutes: SharedStore.windowMinutes, maxAudioSeconds: SyncSTTLimits.maxAudioSeconds)
    let (inputs, continuation) = AsyncStream<Input>.makeStream()
    inbox = continuation
    idle.report = { [weak self] report in self?.idleReported(report) }
    loop = Task { [weak self] in
      for await input in inputs {
        guard let self else { return }
        await self.take(input)
      }
    }
    readers = [readSourceEvents(), readSessionEvents()]
  }

  /// The phone's window: its capture source (the simulator's in the
  /// simulator), the system audio session, the application's own state, and
  /// the idle mode the device supports.
  convenience init() {
    #if targetEnvironment(simulator)
      // The simulator's capture session carries no audio; see SimulatorAudioSource.
      let source: any ListeningSource = SimulatorAudioSource()
    #else
      let source: any ListeningSource = WindowedAudioSource()
    #endif
    let appState = { UIApplication.shared.applicationState }
    self.init(
      source: source, audioSession: SystemAudioSession(), appState: appState,
      backgroundTasks: SystemBackgroundTasks(), clock: ContinuousClock(),
      idle: IdleModes.production(appState: appState))
  }

  deinit {
    loop?.cancel()
    for reader in readers { reader.cancel() }
    expiry?.cancel()
    heartbeat?.cancel()
  }

  // MARK: What the app asks

  /// A window exists — opening, open, paused or closing — as the session
  /// switch shows it.
  var isOn: Bool {
    if case .closed = machine.state { false } else { true }
  }

  /// The Picture in Picture keeper, when that is the idle mode: its source
  /// layer has to be in the view hierarchy for the window to start.
  var pictureInPictureKeeper: PictureInPictureKeeper? { (idle as? PictureInPictureIdle)?.keeper }

  /// Asks for a window. The machine refuses an ask from the background (iOS
  /// would refuse the capture), refreshes a window that is open, and reopens
  /// one that is paused or closing.
  func open() {
    feed(.openRequested(inForeground: appState() != .background))
  }

  /// The switch or Stop: the dictation in flight is cancelled, the source closed.
  func close() {
    feed(.closeRequested)
  }

  /// The app came to the front; `turnedOff` is the session switch's word.
  func foregrounded(turnedOff: Bool) {
    feed(.foregrounded(turnedOff: turnedOff))
  }

  /// Settings changed `SharedStore.windowMinutes`: applied to the window that is open.
  func windowMinutesChanged() {
    feed(.windowMinutesChanged(SharedStore.windowMinutes))
  }

  /// A dictation is recording: the window's lifetime holds past it.
  func utteranceStarted() {
    idle.utteranceWillBegin()
    withGeneration { .utteranceStarted($0) }
  }

  /// A dictation stopped recording, however it ended: the lifetime counts from now.
  func utteranceEnded() {
    idle.utteranceDidEnd()
    withGeneration { .utteranceEnded($0) }
  }

  /// A press's start failed with this reason: the source is lost until it
  /// resumes (a refused background start, a dead or silent mic). The session
  /// being off is no news to the window.
  func captureFailed(reason: FailureReason) {
    guard reason != .sessionOff else { return }
    withGeneration { .sourceDied($0, reason) }
  }

  // MARK: The loop

  func feed(_ event: Machine.Event) {
    inbox.yield(.event(event))
  }

  /// A heartbeat's turn on the loop.
  func beat() {
    inbox.yield(.heartbeat)
  }

  /// An event about the source carries the generation it is about; none, no event.
  private func withGeneration(_ make: (Machine.Generation) -> Machine.Event) {
    guard let generation = machine.state.generation else { return }
    feed(make(generation))
  }

  private func take(_ input: Input) async {
    switch input {
    case .event(let event):
      let from = machine.state
      let effects = machine.handle(event, now: Date())
      if machine.state != from { logTransition(from: from, to: machine.state, on: event) }
      await run(effects)
    case .heartbeat:
      await run(machine.heartbeat(micLive: idle.isLive, now: Date()))
    }
  }

  private func logTransition(from: Machine.State, to: Machine.State, on event: Machine.Event) {
    let generation = to.generation.map(String.init) ?? from.generation.map(String.init) ?? "none"
    Self.log.notice(
      "window \(from.window.rawValue, privacy: .public) → \(to.window.rawValue, privacy: .public) on \(event.name, privacy: .public) gen=\(generation, privacy: .public) launch=\(self.launchID, privacy: .public)"
    )
    let fields = [
      "from": from.window.rawValue, "to": to.window.rawValue, "event": event.name, "gen": generation,
      "launch": launchID.uuidString,
    ]
    DeviceTrace.record("window", fields)
  }

  // MARK: What the source, the session and the idle mode say

  private func readSourceEvents() -> Task<Void, Never> {
    let events = source.events
    return Task { [weak self] in
      for await event in events { self?.sourceEvent(event) }
    }
  }

  private func readSessionEvents() -> Task<Void, Never> {
    let events = audioSession.events
    return Task { [weak self] in
      for await event in events { self?.sessionEvent(event) }
    }
  }

  /// The capture session's word. An interruption the audio session already
  /// announced is the same interruption; one it didn't (another client took
  /// the input) is news. A dead session and a silent one are the source lost.
  private func sourceEvent(_ event: SourceEvent) {
    switch event {
    case .interrupted(let reason):
      guard !sessionInterrupted else { return }
      Self.log.notice("source interrupted (\(reason, privacy: .public)) with no audio session interruption")
      withGeneration { .interruptionBegan($0, .interrupted) }
    case .interruptionEnded:
      guard !sessionInterrupted else { return }
      withGeneration { .interruptionEnded($0, shouldResume: true) }
    case .runtimeError:
      withGeneration { .sourceDied($0, .micBusy) }
    case .silent:
      withGeneration { .sourceDied($0, .micSilent) }
    case .routeChanged(_, let input):
      Self.log.notice("route changed; input=\(input ?? "none", privacy: .public); preferred input re-applied")
      audioSession.applyPreferredInput()
    }
  }

  private func sessionEvent(_ event: AudioSessionEvent) {
    switch event {
    case .interruptionBegan:
      sessionInterrupted = true
      withGeneration { .interruptionBegan($0, .interrupted) }
    case .interruptionEnded(let shouldResume):
      sessionInterrupted = false
      withGeneration { .interruptionEnded($0, shouldResume: shouldResume) }
    case .mediaReset:
      sessionInterrupted = false
      withGeneration { .mediaReset($0) }
    }
  }

  private func idleReported(_ report: IdleReport) {
    switch report {
    case .idleChanged(let idle): withGeneration { .idleChanged($0, idle) }
    case .sourceDied(let reason): withGeneration { .sourceDied($0, reason) }
    }
  }
}

extension ListeningWindowMachine.Event {
  /// The event's name for the transition log: the case, and the reason where one rides along.
  var name: String {
    switch self {
    case .openRequested(let inForeground): inForeground ? "openRequested" : "openRequested(background)"
    case .opened: "opened"
    case .openFailed(_, let reason): "openFailed(\(reason.rawValue))"
    case .utteranceStarted: "utteranceStarted"
    case .utteranceEnded: "utteranceEnded"
    case .interruptionBegan(_, let reason): "interruptionBegan(\(reason.rawValue))"
    case .interruptionEnded(_, let shouldResume): shouldResume ? "interruptionEnded" : "interruptionEnded(noResume)"
    case .foregrounded(let turnedOff): turnedOff ? "foregrounded(turnedOff)" : "foregrounded"
    case .resumed: "resumed"
    case .resumeFailed(_, let reason): "resumeFailed(\(reason.rawValue))"
    case .sourceDied(_, let reason): "sourceDied(\(reason.rawValue))"
    case .mediaReset: "mediaReset"
    case .expired: "expired"
    case .closeRequested: "closeRequested"
    case .closed: "closed"
    case .idleChanged(_, let idle): "idleChanged(\(idle.rawValue))"
    case .windowMinutesChanged(let minutes): "windowMinutesChanged(\(minutes))"
    }
  }
}
