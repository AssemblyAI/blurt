import BlurtEngine
import SwiftUI

/// The AssemblyAI account section of the setup/settings screen.
///
/// Shaped the way macOS treats a third-party service credential (HIG "Managing
/// accounts" — the pattern behind System Settings › Internet Accounts, Mail's
/// account list, and Xcode › Settings › Accounts): the pane carries a **status
/// row** showing the connection's identity and state plus one button, and the
/// credential itself is entered in a **sheet**, which is where a modal task with
/// an explicit commit-or-cancel belongs.
///
/// Two deliberate departures from the neighbouring permission rows:
///
/// - The row shows the stored key's last four characters, not the green
///   checkmark `PermissionsStepView` uses. A permission is on or off; an account
///   has an identity, and "which key is this?" is the question a checkmark can't
///   answer.
/// - The button titles carry ellipses ("Connect…", "Change…") because they need
///   more input before the action completes — the same rule that already gives
///   "Open Accessibility Settings…" its ellipsis.
///
/// Everything the row can't hold — why a key is needed at all, where it's
/// stored, how to get one, and what went wrong when AssemblyAI rejects one —
/// lives in the sheet, which has room for it without crowding the form.
struct APIKeyStepView: View {
  var apiKey: APIKeyModel

  /// The key currently in the Keychain, loaded on appear (empty when none).
  @State private var savedKey = ""
  @State private var isPresentingEditor = false

  var body: some View {
    Section {
      SettingRow(title: "API Key", systemImage: "key.fill") {
        HStack(spacing: 12) {
          statusLabel
          Button(savedKey.isEmpty ? "Connect…" : "Change…") { isPresentingEditor = true }
            .accessibilityIdentifier(
              savedKey.isEmpty ? UITestIdentifiers.apiKeyConnect : UITestIdentifiers.apiKeyChange
            )
        }
      }
    } header: {
      Text("AssemblyAI")
    } footer: {
      // HIG asks you to explain why something is needed at the moment you ask
      // for it. This is the only place in the app that says audio leaves the
      // machine before the user has already gone looking for a key.
      Text("Blurt sends your audio to AssemblyAI to transcribe it.")
    }
    .onAppear {
      savedKey = apiKey.current ?? ""
      // Keep the readiness gate in sync with what's actually in the Keychain. If
      // a key is already saved, this flips `hasAPIKey` true so the wizard advances
      // to the ready screen instead of stranding the user on a setup step.
      apiKey.refreshStatus()
    }
    // The setup window and Settings both host this section, so a key connected
    // in one has to reach the other's row — a snapshot taken once on appear
    // would leave the second window insisting "Not connected" and reopening its
    // sheet in first-connect mode. `hasAPIKey` is the observable edge; the
    // sheet's `onSaved` covers a rotation, which never moves it.
    .onChange(of: apiKey.hasAPIKey) {
      savedKey = apiKey.current ?? ""
    }
    .sheet(isPresented: $isPresentingEditor) {
      APIKeyEditorSheet(apiKey: apiKey, savedKey: savedKey) { savedKey = $0 }
    }
  }

  /// The row's state: "Not connected", or the stored key's masked tail once one
  /// exists. Monospaced so the four revealed characters line up as an identifier
  /// rather than reading as prose.
  @ViewBuilder
  private var statusLabel: some View {
    if savedKey.isEmpty {
      Text("Not connected")
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(UITestIdentifiers.apiKeyNotConnected)
    } else {
      Text(maskedKey)
        .font(.body.monospaced())
        .foregroundStyle(.secondary)
        // The bullets are decoration; spell the state out for VoiceOver.
        .accessibilityLabel("Connected, key ending \(savedKey.suffix(4))")
        .accessibilityIdentifier(UITestIdentifiers.apiKeySavedStatus)
    }
  }

  /// The stored key as `••••` plus its last four characters — enough to tell two
  /// keys apart (which account is this?) without putting the secret on screen.
  private var maskedKey: String { "••••\(savedKey.suffix(4))" }
}

/// The credential-entry task itself, presented as a sheet from the settings row.
///
/// A sheet because this is exactly what HIG reserves them for: a focused, modal
/// step that must be committed or cancelled before anything else happens. It
/// also gives the field the room an inline settings row can't — a standing label
/// (a placeholder disappears the moment text lands, so it can't be the only
/// label), a "Show key" checkbox rather than a bare glyph toggle, and a footer
/// that swaps the storage reassurance for a specific error.
///
/// Button layout follows the sheet convention: the non-dismissing secondary
/// action sits at the leading edge, clear of the Cancel / default-action pair at
/// the trailing edge, and Return / Escape are scoped to the sheet rather than
/// to the whole window.
private struct APIKeyEditorSheet: View {
  var apiKey: APIKeyModel
  /// The key already stored, empty on first run. Drives the first-connect vs.
  /// rotate wording, and whether the "get a key" action is worth showing at all
  /// (once a key exists the user has clearly already found the dashboard).
  let savedKey: String
  /// Reports a newly-stored key back to the settings row.
  var onSaved: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  @State private var draft: String
  @State private var isRevealed = false
  @State private var isValidating = false
  /// Inline, recoverable problems (wrong key, server unreachable) — shown above
  /// the buttons so the user just edits the field and retries.
  @State private var errorMessage: String?
  /// A non-inline system fault (the Keychain write itself failed). Retyping the
  /// key can't fix it, so it's surfaced as an alert rather than footer text —
  /// the convention for genuine faults, and the reason the recoverable cases
  /// above are *not* alerts.
  @State private var showSaveFault = false
  /// The in-flight verify-then-store. Held so dismissing the sheet can cancel
  /// it: without that, Cancel/Escape during a check would let the submission run
  /// on and persist the key anyway — a Cancel that silently commits.
  @State private var submitTask: Task<Void, Never>?
  @FocusState private var fieldFocused: Bool

  init(apiKey: APIKeyModel, savedKey: String, onSaved: @escaping (String) -> Void) {
    self.apiKey = apiKey
    self.savedKey = savedKey
    self.onSaved = onSaved
    _draft = State(initialValue: savedKey)
  }

  /// The draft trimmed to usable text (the engine's shared rule), nil when blank.
  private var trimmedKey: String? { draft.trimmedNonEmpty() }

  /// Enabled for any non-empty key while no validation is in flight. We don't
  /// gate on "differs from the saved key" — re-submitting an unchanged key is a
  /// harmless re-validate against AssemblyAI, and a button that's disabled for a
  /// reason the user can't see is worse than a redundant round trip.
  private var canSubmit: Bool { trimmedKey != nil && !isValidating }

  /// A verb describing what the button does. "Save" describes storage; the
  /// operation is really verify-then-store, and on first run it's a connection.
  private var actionTitle: String { savedKey.isEmpty ? "Connect" : "Update" }

  private var rationale: String {
    savedKey.isEmpty
      ? "Blurt needs an AssemblyAI API key to transcribe your speech. A free-tier key works."
      : "Paste a new key to replace the one Blurt is using."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("AssemblyAI API Key")
          .font(.headline)
        Text(rationale)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      // `.columns` is the aligned-label form layout: a right-aligned "API Key:"
      // in the label column with the field beside it, so the label stays put
      // once the field has content.
      Form {
        LabeledContent("API Key:") {
          VStack(alignment: .leading, spacing: 8) {
            keyField
            Toggle("Show key", isOn: $isRevealed)
              .accessibilityIdentifier(UITestIdentifiers.apiKeyReveal)
          }
        }
      }
      .formStyle(.columns)

      statusText

      buttonRow
    }
    .padding(20)
    .frame(width: 420)
    // Focus the field on open so the common path — arrive with the key on the
    // clipboard — is ⌘V then Return, with no click at all.
    .defaultFocus($fieldFocused, true)
    // Cancel is not the only way out — the window can close under the sheet.
    // Catch every dismissal, not just the button.
    .onDisappear { submitTask?.cancel() }
    .alert("Couldn’t Save Your Key", isPresented: $showSaveFault) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Blurt couldn’t write the key to your macOS Keychain. Check Keychain access and try again.")
    }
  }

  /// Masked by default with a "Show key" checkbox so a pasted key can be read
  /// back. Not `.textContentType(.password)`: an API key isn't a website
  /// credential, and that hint triggers password autofill / "save password".
  private var keyField: some View {
    Group {
      if isRevealed {
        TextField("", text: $draft, prompt: Text("Paste your key"))
          .accessibilityIdentifier(UITestIdentifiers.apiKeyField)
      } else {
        SecureField("", text: $draft, prompt: Text("Paste your key"))
          .accessibilityIdentifier(UITestIdentifiers.apiKeyField)
      }
    }
    .lineLimit(1)
    .disableAutocorrection(true)
    .focused($fieldFocused)
    .onSubmit(submit)
    .onChange(of: draft) { errorMessage = nil }
    // `LabeledContent`'s label doesn't reliably reach the field itself, and the
    // title above is empty (the prompt is the placeholder), so name it here.
    .accessibilityLabel("API Key")
  }

  /// A recoverable error in red (no caution glyph — that reads as critical or
  /// destructive, not "retype this"), otherwise where the key ends up.
  @ViewBuilder
  private var statusText: some View {
    if let errorMessage {
      Text(errorMessage)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(UITestIdentifiers.apiKeyError)
    } else {
      Text("Your key is stored in your Mac’s Keychain.")
        .foregroundStyle(.secondary)
    }
  }

  private var buttonRow: some View {
    HStack(spacing: 12) {
      // The one action a user with no key can actually take, as a real button
      // rather than caption-sized footer text. It doesn't dismiss the sheet, so
      // it sits at the leading edge, away from Cancel / the default action —
      // and the sheet stays open behind the browser, ready for the paste.
      if savedKey.isEmpty {
        Button("Get a Free Key") { openURL(APIKeyStore.dashboardURL) }
          .accessibilityIdentifier(UITestIdentifiers.apiKeyGetKey)
      }
      Spacer(minLength: 12)
      if isValidating {
        ProgressView().controlSize(.small)
      }
      Button("Cancel", action: cancel)
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier(UITestIdentifiers.apiKeyCancel)
      Button(actionTitle, action: submit)
        .glassButtonStyleCompat(prominent: true)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .accessibilityIdentifier(UITestIdentifiers.apiKeySave)
    }
  }

  /// Abandons an in-flight check and closes. Cancelling the task cancels the
  /// `URLSession` request inside `APIKeyValidator`, which reports `.unreachable`
  /// — and `APIKeySubmission` never persists on that outcome, so the key stays
  /// unsaved. (A response that has already landed can still commit; the write is
  /// synchronous past that point. Vanishingly narrow, and it stores a key the
  /// user did type and submit.)
  private func cancel() {
    submitTask?.cancel()
    submitTask = nil
    dismiss()
  }

  private func submit() {
    guard canSubmit, let key = trimmedKey else { return }
    isValidating = true
    errorMessage = nil
    submitTask = Task {
      let result = await apiKey.submit(key)
      // The sheet may be gone — cancelled, or dismissed by the window closing.
      // Writing `@State` on a torn-down view can't surface anything (a
      // `.saveFailed` alert would have nowhere to appear), so stop here.
      guard !Task.isCancelled else { return }
      isValidating = false
      switch result {
      case .valid:
        // Verified and stored — hand the key back to the row and close. The
        // controller reveals the overlay via its hasAPIKey observer.
        onSaved(key)
        dismiss()
      case .invalid:
        errorMessage = "AssemblyAI rejected that key. Double-check it and try again."
      case .unreachable:
        errorMessage = "Couldn't reach AssemblyAI. Check your connection and try again."
      case .saveFailed:
        // A system fault retyping can't fix — surface it as an alert, not inline.
        showSaveFault = true
      }
    }
  }
}
