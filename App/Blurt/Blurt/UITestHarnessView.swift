#if UITEST_HOOKS

  import BlurtEngine
  import SwiftUI

  /// The test harness window. It exposes buttons that drive the same
  /// `DictationSession` the hotkey would (`press`/`release`/`cancel`) and
  /// read-outs for the live pipeline status and the last "pasted" text —
  /// everything the XCUITest suite needs to observe the record → transcribe →
  /// paste flow deterministically.
  struct UITestHarnessView: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow)
    private var openWindow

    private var coordinator: AppCoordinator? { appDelegate.coordinator }

    /// The shared harness state, for the read-outs that only display it.
    /// `body` is main-actor isolated, so reaching the `@MainActor` singleton
    /// here is safe.
    private var state: UITestState { UITestState.shared }

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("Blurt UI Test Harness")
          .font(.headline)
        sessionControls
        keyControls
        pipelineReadOuts
        commandReadOuts
      }
      .padding(20)
      .frame(width: 360)
      .onAppear {
        // UI tests need the main Window scene to be present even when SwiftUI's
        // restoration state remembers it as closed from a prior test. The harness
        // scene is always presented in UI-test mode, so capture its openWindow
        // action and use it to deterministically restore the main window. Capture
        // the action alone — see `MainWindowRoot` for the cycle a bare
        // `openWindow(id:)` creates here.
        let openWindowAction = openWindow
        appDelegate.openWindowByID = { [openWindowAction] id in openWindowAction(id: id) }
        appDelegate.openMainWindow()
      }
    }

    /// The canned transcript and the buttons that drive the session directly.
    @ViewBuilder private var sessionControls: some View {
      // Local `@Bindable` over the shared observable — the pattern for binding to
      // an `@Observable` that isn't owned by `@State`.
      @Bindable var harness = UITestState.shared
      TextField("Transcript", text: $harness.cannedTranscript)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(UITestIdentifiers.transcriptField)

      HStack(spacing: 8) {
        Button("Set API Key") { coordinator?.apiKey.save(UITestIdentifiers.validAPIKey) }
          .accessibilityIdentifier(UITestIdentifiers.setKeyButton)
        Button("Start") { Task { await coordinator?.session.press() } }
          .accessibilityIdentifier(UITestIdentifiers.startButton)
        Button("Stop") { Task { await coordinator?.session.release() } }
          .accessibilityIdentifier(UITestIdentifiers.stopButton)
        Button("Cancel") { Task { await coordinator?.session.cancel() } }
          .accessibilityIdentifier(UITestIdentifiers.cancelButton)
      }

      // The Record button's scripted live session
      // (`TranscriptsModel.UITestLiveSession`): its next turn, or a dropped
      // connection.
      HStack(spacing: 8) {
        Button("Next Turn") { Task { await TranscriptsModel.UITestLiveSession.latest()?.next() } }
          .accessibilityIdentifier(UITestIdentifiers.harnessLiveNextTurn)
        Button("Fail Live") { Task { await TranscriptsModel.UITestLiveSession.latest()?.fail() } }
          .accessibilityIdentifier(UITestIdentifiers.harnessLiveFail)
      }
    }

    /// Drives the picked trigger key through the *real* key tap
    /// (DictationKeyTap → DictationKeyGate → the read-aloud router → the
    /// session), rather than calling the session directly like Start/Stop
    /// above. Lets a UI test exercise every key's path end to end without
    /// synthesizing the lone-modifier CGEvent (which needs Accessibility
    /// trust the test host lacks). Press then Release is a hold; Tap
    /// Release lets go quickly, as a tap.
    @ViewBuilder private var keyControls: some View {
      @Bindable var harness = UITestState.shared
      Picker("Key", selection: $harness.selectedKey) {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          Text(key.label).tag(key)
        }
      }
      .accessibilityIdentifier(UITestIdentifiers.harnessKeyPicker)
      keyChoiceButtons
      HStack(spacing: 8) {
        Button("Hotkey Press") { coordinator?.simulateKeyPressForTesting(state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.hotkeyPressButton)
        Button("Hotkey Release") { coordinator?.simulateKeyReleaseForTesting(state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.hotkeyReleaseButton)
        Button("Tap Release") { coordinator?.simulateKeyReleaseForTesting(state.selectedKey, asTap: true) }
          .accessibilityIdentifier(UITestIdentifiers.hotkeyTapReleaseButton)
      }
    }

    /// Sets what the picked key does, and how every key is pressed.
    private var keyChoiceButtons: some View {
      HStack(spacing: 8) {
        Button("Dictate") { coordinator?.setKeyChoiceForTesting(.dictate, for: state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetDictate)
        Button("Read") { coordinator?.setKeyChoiceForTesting(.readAloud, for: state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetReadAloud)
        Button("Ask") { coordinator?.setKeyChoiceForTesting(.ask, for: state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetAsk)
        Button("Off") { coordinator?.setKeyChoiceForTesting(.off, for: state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetOff)
        Button("Command") { coordinator?.setKeyChoiceForTesting(.command, for: state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetCommand)
        Button("Rewrite") { coordinator?.setKeyChoiceForTesting(.rewrite, for: state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetRewrite)
        Button("Compose") { coordinator?.setKeyChoiceForTesting(.compose, for: state.selectedKey) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetCompose)
        Button("Tap Mode") { coordinator?.setActivationForTesting(.tap) }
          .accessibilityIdentifier(UITestIdentifiers.harnessSetTapMode)
      }
    }

    @ViewBuilder private var pipelineReadOuts: some View {
      // The live pipeline status, mirrored off the same `menuBarStatus` the
      // menu bar indicator renders, so the test can watch idle → recording →
      // transcribing → idle transitions.
      LabeledContent("Status") {
        Text(statusText)
          .accessibilityIdentifier(UITestIdentifiers.statusLabel)
      }

      // What the injector last "pasted" — the role the focused app plays.
      LabeledContent("Pasted") {
        Text(state.pastedText)
          .accessibilityIdentifier(UITestIdentifiers.pastedLabel)
      }

      // Read-aloud: what the stub speaker was asked to read, whether a read is
      // playing, and the style the last dictation request carried.
      LabeledContent("Spoken") {
        Text(state.spokenText)
          .accessibilityIdentifier(UITestIdentifiers.spokenLabel)
      }
      LabeledContent("Reading") {
        Text(coordinator?.isReadingAloud == true ? "yes" : "no")
          .accessibilityIdentifier(UITestIdentifiers.readingLabel)
      }
      LabeledContent("Voice") {
        Text(state.spokenStyle)
          .accessibilityIdentifier(UITestIdentifiers.spokenStyleLabel)
      }
      LabeledContent("Style") {
        Text(state.sentStyle)
          .accessibilityIdentifier(UITestIdentifiers.sentStyleLabel)
      }
    }

    @ViewBuilder private var commandReadOuts: some View {
      // Control Your Mac: what the stub planner was asked, and what the
      // stub performer did, steps joined in order ("—" for none yet).
      LabeledContent("Planned") {
        Text(state.plannedCommand ?? "—")
          .accessibilityIdentifier(UITestIdentifiers.plannedLabel)
      }
      LabeledContent("Performed") {
        Text(state.performedSteps.isEmpty ? "—" : state.performedSteps.joined(separator: "; "))
          .accessibilityIdentifier(UITestIdentifiers.performedLabel)
      }
      LabeledContent("Notice") {
        Text(state.lastNotice ?? "—")
          .accessibilityIdentifier(UITestIdentifiers.noticeLabel)
      }

      // Mirrors the newest dictation in the saved history (the ready
      // window's "Recent" list) so a test can watch it populate on a
      // completed dictation. Placeholder "—" stands in for the empty list so
      // the read-out is a stable element to assert against.
      LabeledContent("Echo") {
        Text(coordinator?.transcripts.history.first { $0.kind == .dictation }?.text ?? "—")
          .accessibilityIdentifier(UITestIdentifiers.transcriptEchoLabel)
      }
    }

    private var statusText: String {
      switch coordinator?.menuBarStatus ?? .idle {
      case .idle:
        UITestIdentifiers.statusIdle

      case .recording:
        UITestIdentifiers.statusRecording

      case .transcribing:
        UITestIdentifiers.statusTranscribing

      // Not a pipeline phase: the menu bar folds the Record button's
      // recording in itself, and this mirrors only the dictation.
      case .recordingAudio:
        UITestIdentifiers.statusIdle
      }
    }
  }

#endif
