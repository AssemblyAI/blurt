#if UITEST_HOOKS

  import AppKit
  import BlurtEngine
  import Foundation
  import Observation
  import SwiftUI

  // Test scaffolding that lets the XCUITest suite drive the real app against
  // deterministic, offline doubles. Gated on the `UITEST_HOOKS` compilation
  // condition (defined for the Debug config, so Xcode, check.sh, and the UI/leak
  // scripts all get it) rather than bare `#if DEBUG`, so `scripts/dev-build.sh`
  // — which strips the condition — produces a clean local build without any of
  // it. Never compiled into the notarized Release build, and even when compiled
  // it only activates under the `-BlurtUITest` launch argument.
  //
  // The doubles stand in for exactly the three pipeline seams that need real
  // hardware / network / Accessibility (mic, transcriber, injector) plus the
  // Keychain-backed key store, so a UI test exercises the full
  // `DictationSession` → `AppCoordinator` render path and the settings flows
  // without any of those external dependencies.

  /// Whether this process was launched for UI testing. Cheap enough to read on
  /// demand; the test runner sets the flag via `XCUIApplication.launchArguments`.
  enum UITestMode {
    static let launchArgument = "-BlurtUITest"
    /// Opt-in flag that forces the fully-configured "ready" state so the main
    /// window renders `ReadyView` instead of the setup wizard — the only way the
    /// test host can reach that screen, since it can't grant real TCC
    /// permissions. See `AppDelegate.applicationDidFinishLaunching`.
    static let readyStateArgument = "-BlurtUITestReady"

    static var isActive: Bool {
      ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Whether the runner asked for the forced-ready state (implies `isActive`).
    static var isReadyStateRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(readyStateArgument)
    }
  }

  /// Accessibility identifiers and window id for the test harness, kept in one
  /// place. The XCUITest target re-declares the same string values (it's a
  /// separate module and can't import these), so keep the two in sync.
  enum UITestID {
    static let harnessWindow = "uitest.harness"
    static let transcriptField = "uitest.transcript"
    static let setKeyButton = "uitest.setKey"
    static let startButton = "uitest.start"
    static let stopButton = "uitest.stop"
    static let cancelButton = "uitest.cancel"
    static let hotkeyPressButton = "uitest.hotkeyPress"
    static let hotkeyReleaseButton = "uitest.hotkeyRelease"
    static let statusLabel = "uitest.status"
    static let pastedLabel = "uitest.pasted"
    static let transcriptEchoLabel = "uitest.transcriptEcho"
  }

  /// Shared, observable state the harness window renders and the stub injector /
  /// transcriber read. Main-actor (the app target's default isolation) because
  /// the UI and `AppCoordinator` both live there; the stubs hop onto the main
  /// actor to touch it.
  @Observable
  final class UITestState {
    static let shared = UITestState()

    /// The transcript the stub transcriber will "recognize". Bound to a text
    /// field in the harness so a test can set the expected paste payload.
    var cannedTranscript = "hello world"

    /// What the stub injector last "pasted" — i.e. the text `DictationSession`
    /// handed to `insert`. The harness renders it so a test can read it back and
    /// confirm the transcript flowed through the whole pipeline to injection.
    private(set) var pastedText = ""

    func recordPaste(_ text: String) { pastedText = text }
  }

  // MARK: - Pipeline doubles

  // The three pipeline doubles are `nonisolated`, opting out of the app target's
  // MainActor default: they witness the engine's nonisolated protocol seams and
  // must keep running wherever the session calls them (hopping every stub call
  // through the main actor would serialize the pipeline behind the UI).

  /// Stub mic: captures nothing, returns a fixed buffer comfortably above
  /// `SyncSTTLimits.minSamples` so the pipeline clears the too-short-audio guard
  /// and proceeds to transcribe.
  nonisolated struct UITestMic: MicCaptureProtocol {
    func start() async throws {}
    func stop() async throws -> [Float] {
      Array(repeating: 0, count: SyncSTTLimits.minSamples * 2)
    }
  }

  /// Stub transcriber: returns the harness's canned transcript, so the "spoken"
  /// text is whatever the test set — no network, fully deterministic.
  nonisolated struct UITestTranscriber: TranscriberProtocol {
    func transcribe(samples: [Float], sampleRate: Int, context: TranscriptionContext?) async throws -> String {
      await MainActor.run { UITestState.shared.cannedTranscript }
    }
  }

  /// Stub injector: records what would have been pasted into the focused app
  /// rather than posting a Cmd-V `CGEvent` (which needs Accessibility and a real
  /// target app). The harness window plays the role of "the app being pasted
  /// into", surfacing the recorded text for the test to assert on.
  nonisolated struct UITestInjector: InjectorProtocol {
    func setTargetApp(_ app: NSRunningApplication?) async {}
    func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {
      await MainActor.run { UITestState.shared.recordPaste(text) }
    }
  }

  // The real Keychain stays untouched under UI testing via the engine's
  // `InMemoryAPIKeyStore` (`Sources/BlurtEngine/Config/APIKeyGateway.swift`),
  // injected as the coordinator's key store in `AppDelegate`.

  extension DictationComponents {
    /// The all-stub pipeline used under UI testing: no mic, no network, no
    /// Accessibility paste. `UITestMic` inherits `MicCaptureProtocol`'s default
    /// empty `levels` stream (the overlay meter isn't asserted) and no-op
    /// `warmUp()`.
    static func uiTest() -> DictationComponents {
      DictationComponents(
        mic: UITestMic(),
        transcriber: UITestTranscriber(),
        injector: UITestInjector()
      )
    }
  }

  // MARK: - Harness window

  /// The test harness window. It exposes buttons that drive the same pipeline
  /// the hotkey would (`AppCoordinator.beginDictation`/`…end`/`…cancel`), a
  /// field to set the canned
  /// transcript, and read-outs for the live pipeline status and the last
  /// "pasted" text — everything the XCUITest suite needs to observe the
  /// record → transcribe → paste flow deterministically.
  struct UITestHarnessView: View {
    var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    private var coordinator: AppCoordinator? { appDelegate.coordinator }

    var body: some View {
      // Local `@Bindable` over the shared observable — the pattern for binding to
      // an `@Observable` that isn't owned by `@State`. `body` is main-actor
      // isolated, so reaching the `@MainActor` singleton here is safe.
      @Bindable var state = UITestState.shared
      return VStack(alignment: .leading, spacing: 12) {
        Text("Blurt UI Test Harness")
          .font(.headline)

        TextField("Transcript", text: $state.cannedTranscript)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier(UITestID.transcriptField)

        HStack(spacing: 8) {
          Button("Set API Key") { coordinator?.apiKey.save(UITestKeys.validAPIKey) }
            .accessibilityIdentifier(UITestID.setKeyButton)
          Button("Start") { Task { await coordinator?.beginDictation() } }
            .accessibilityIdentifier(UITestID.startButton)
          Button("Stop") { Task { await coordinator?.endDictation() } }
            .accessibilityIdentifier(UITestID.stopButton)
          Button("Cancel") { Task { await coordinator?.cancelDictation() } }
            .accessibilityIdentifier(UITestID.cancelButton)
        }

        // A second row that drives dictation through the *real* key tap
        // (DictationKeyTap → DictationKeyGate → the coordinator's onStart/onStop),
        // rather than calling the session directly like Start/Stop above. Lets a
        // UI test exercise the hotkey path end to end without synthesizing the
        // lone-modifier CGEvent (which needs Accessibility trust the test host
        // lacks). Press then Release is a hold, so it records then transcribes.
        HStack(spacing: 8) {
          Button("Hotkey Press") { coordinator?.simulateDictationPressForTesting() }
            .accessibilityIdentifier(UITestID.hotkeyPressButton)
          Button("Hotkey Release") { coordinator?.simulateDictationReleaseForTesting() }
            .accessibilityIdentifier(UITestID.hotkeyReleaseButton)
        }

        // The live pipeline status, mirrored off the same `menuBarStatus` the
        // menu bar indicator renders, so the test can watch idle → recording →
        // transcribing → idle transitions.
        LabeledContent("Status") {
          Text(statusText)
            .accessibilityIdentifier(UITestID.statusLabel)
        }

        // What the injector last "pasted" — the role the focused app plays.
        LabeledContent("Pasted") {
          Text(state.pastedText)
            .accessibilityIdentifier(UITestID.pastedLabel)
        }

        // Mirrors the newest entry of `AppCoordinator.recentDictations` (the
        // ready-window "Recent" list) so a test can watch it populate on a
        // completed dictation. Placeholder "—" stands in for the empty list so
        // the read-out is a stable element to assert against.
        LabeledContent("Echo") {
          Text(coordinator?.recentDictations.entries.first?.text ?? "—")
            .accessibilityIdentifier(UITestID.transcriptEchoLabel)
        }
      }
      .padding(20)
      .frame(width: 360)
      .onAppear {
        // UI tests need the main Window scene to be present even when SwiftUI's
        // restoration state remembers it as closed from a prior test. The harness
        // scene is always presented in UI-test mode, so capture its openWindow
        // action and use it to deterministically restore the main window.
        appDelegate.openWindowByID = { openWindow(id: $0) }
        appDelegate.openMainWindow()
      }
    }

    private var statusText: String {
      switch coordinator?.menuBarStatus ?? .idle {
      case .idle: "idle"
      case .recording: "recording"
      case .transcribing: "transcribing"
      }
    }
  }

#endif
