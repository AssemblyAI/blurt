import BlurtEngine
import SwiftUI

/// The AssemblyAI API-key section of the setup/settings screen. Saving checks
/// the key against AssemblyAI before storing it, so a wrong key surfaces an
/// inline error here instead of silently failing later during dictation.
///
/// Once a key is saved the field collapses to a "✓ Saved" status row matching
/// the Microphone/Accessibility permission rows, so a completed step reads as
/// done at a glance rather than as a pre-filled field that still looks pending.
/// A "Change" button re-opens the editable field (pre-filled, masked) when the
/// key needs rotating; "Cancel" there discards the edit and restores the row.
struct APIKeyStepView: View {
  var coordinator: AppCoordinator

  /// The key currently in the Keychain, loaded on appear (empty when none).
  @State private var savedKey = ""
  @State private var draft = ""
  /// True while the editable field is shown for an already-saved key (the user
  /// tapped "Change"). When a key is saved and we're not editing, the section
  /// collapses to the "✓ Saved" status row instead.
  @State private var isEditing = false
  @State private var isRevealed = false
  @State private var isValidating = false
  /// Inline, recoverable validation problems (wrong key, server unreachable) —
  /// shown in the footer so the user just edits the field and retries.
  @State private var errorMessage: String?
  /// A non-inline system fault (the Keychain write itself failed). Retyping the
  /// key can't fix it, so it's surfaced as an alert rather than footer text —
  /// the AppKit `presentError:` convention for genuine `NSError`-class faults.
  @State private var showSaveFault = false

  private var trimmed: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Enabled for any non-empty key while no validation is in flight. We don't
  /// gate on "differs from the saved key" — a disabled-until-changed button
  /// renders as dimmed caption text on the common return visit (field pre-filled
  /// with the saved key), so people don't see it at all. Re-submitting an
  /// unchanged key is a harmless re-validate against AssemblyAI.
  private var canSubmit: Bool { !trimmed.isEmpty && !isValidating }

  /// "Save" for the first key, "Update" once one exists.
  private var actionTitle: String { savedKey.isEmpty ? "Save" : "Update" }

  var body: some View {
    Section {
      if savedKey.isEmpty || isEditing {
        keyField
      } else {
        savedRow
      }
    } header: {
      Text("AssemblyAI API Key")
    } footer: {
      statusFooter
    }
    .onAppear {
      savedKey = coordinator.currentAPIKey ?? ""
      draft = savedKey
      // Keep the readiness gate in sync with what's actually in the Keychain. If
      // a key is already saved, this flips `hasAPIKey` true so the wizard advances
      // to the ready screen instead of stranding the user here with a pre-filled
      // key and a disabled "Update" (its only control) and no way forward.
      coordinator.refreshAPIKeyStatus()
    }
    .alert("Couldn’t Save Your Key", isPresented: $showSaveFault) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Blurt couldn’t write the key to your macOS Keychain. Check Keychain access and try again.")
    }
  }

  /// The collapsed state once a key is saved: a "✓ Saved" status row matching the
  /// permission rows, with a "Change" button that re-opens the editable field.
  /// Mirrors `PermissionsStepView.permissionRow` so a done step looks done.
  private var savedRow: some View {
    LabeledContent {
      HStack(spacing: 12) {
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          Text("Saved").foregroundStyle(.secondary)
            .accessibilityIdentifier("settings.apiKey.savedStatus")
        }
        Button("Change") {
          isEditing = true
        }
        .accessibilityIdentifier("settings.apiKey.change")
      }
    } label: {
      Label("API Key", systemImage: "key.fill")
    }
  }

  /// Masked field by default with a reveal toggle so the user can confirm a
  /// pasted key. Not `.textContentType(.password)`: an API key isn't a website
  /// credential, and that hint triggers password autofill / "save password".
  private var keyField: some View {
    HStack(spacing: 8) {
      // Leading glyph so this row matches the icon'd permission/shortcut rows.
      Image(systemName: "key.fill")
        .foregroundStyle(.secondary)
      Group {
        // The title string is the field's native placeholder (rendered as
        // `NSTextField.placeholderString`), shown greyed when the field is empty.
        if isRevealed {
          TextField("Enter your API key", text: $draft)
            .accessibilityIdentifier("settings.apiKey.field")
        } else {
          SecureField("Enter your API key", text: $draft)
            .accessibilityIdentifier("settings.apiKey.field")
        }
      }
      .lineLimit(1)
      .disableAutocorrection(true)
      .onSubmit(submit)
      .onChange(of: draft) { errorMessage = nil }

      Button {
        isRevealed.toggle()
      } label: {
        Image(systemName: isRevealed ? "eye.slash" : "eye")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(isRevealed ? "Hide API key" : "Show API key")
      .accessibilityIdentifier("settings.apiKey.reveal")

      // Keep the button mounted across all states (idle / disabled / in-flight)
      // so its footprint and identity stay stable — the spinner sits beside it
      // rather than replacing it. Prominent + default-action styling gives it
      // visible chrome even when disabled, so it never reads as plain caption
      // text the way a borderless title does.
      if isValidating {
        ProgressView().controlSize(.small)
      }
      // When changing an already-saved key, offer a way back to the "✓ Saved"
      // row without committing an edit. HIG order: Cancel (Escape, plain) sits to
      // the left of the prominent default action (Return). Absent during first-run
      // entry — there's no saved key to cancel back to.
      if isEditing {
        Button("Cancel") {
          draft = savedKey
          errorMessage = nil
          isEditing = false
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("settings.apiKey.cancel")
      }
      Button(actionTitle, action: submit)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .accessibilityIdentifier("settings.apiKey.save")
    }
  }

  /// Inline footer: a recoverable error in red (no caution glyph — that reads as
  /// critical/destructive, not "retype this"), otherwise the neutral help line.
  /// The "Get your API key" link sits below as a distinct recovery affordance —
  /// but only while no key is saved yet. Once a key exists the link is dead
  /// weight (the user clearly already found one), so it's dropped.
  private var statusFooter: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityIdentifier("settings.apiKey.error")
      } else {
        Text("Your key is stored securely in the macOS Keychain.")
          .foregroundStyle(.secondary)
      }
      // Render the link as a Text run carrying a `.link` attribute rather than a
      // `Link` view: a `Link` forces its own (body) font, which reads larger than
      // the surrounding footer copy. As plain `Text` it inherits the grouped
      // Form's native footer font, so the whole footer matches the other sections.
      if savedKey.isEmpty {
        getKeyLink
      }
    }
  }

  /// "Get your API key" as a tappable link that inherits the footer font (so it
  /// matches the help text rather than jumping to a `Link`'s body size).
  private var getKeyLink: Text {
    var link = AttributedString("Get your API key")
    link.link = APIKeyStore.dashboardURL
    return Text(link)
  }

  private func submit() {
    guard canSubmit else { return }
    let key = trimmed
    isValidating = true
    errorMessage = nil
    Task {
      let result = await coordinator.submitAPIKey(key)
      isValidating = false
      switch result {
      case .valid:
        // Saved — record it and collapse the section to the "✓ Saved" status
        // row. The controller reveals the overlay via its hasAPIKey observer.
        savedKey = key
        draft = key
        isEditing = false
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

/// The "Key Terms" section of the Settings window: a free-text
/// area where the user lists comma-separated domain words (names, jargon, product
/// names). These are folded into every transcription's prompt as spelling priming
/// (see `KeyTermsStore` / `TranscriptionPrompt.build`), so the model favors those
/// spellings. Optional — it never gates setup; an empty list just sends no terms.
struct KeyTermsStepView: View {
  /// Seeded from the store on first render; written back as the user edits.
  @State private var text = KeyTermsStore.get() ?? ""

  var body: some View {
    Section {
      // A vertical-axis TextField gives a native placeholder (`prompt`) and grows
      // with content up to `lineLimit`, so there's no need to fake a placeholder by
      // overlaying Text on a TextEditor. `labelsHidden` keeps the title for
      // accessibility without repeating the section header inline.
      TextField(
        text: $text,
        prompt: Text("e.g. AssemblyAI, Kubernetes, Anthropic, Blurt"),
        axis: .vertical
      ) {
        Text("Key Terms")
      }
      .labelsHidden()
      .lineLimit(2...6)
      .font(.body)
      .disableAutocorrection(true)
      .accessibilityIdentifier("settings.keyTerms.field")
      .onChange(of: text) { KeyTermsStore.set(text) }
    } header: {
      Text("Key Terms")
    } footer: {
      Text("Names, jargon, and product terms to prime transcription spelling.")
    }
  }
}
