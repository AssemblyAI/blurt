import BlurtEngine
import SwiftUI

/// The credential-entry task itself, presented as a sheet from the settings row.
///
/// A sheet because this is exactly what HIG reserves them for: a focused, modal
/// step that must be committed or cancelled before anything else happens. It
/// also gives the field the room an inline settings row can't — a full-width
/// field under a headline that names it (the placeholder disappears the moment
/// text lands, so it can't be the only label), a "Show key" checkbox rather than
/// a bare glyph toggle, and a footer that swaps the storage reassurance for a
/// specific error.
///
/// Button layout follows the sheet convention: the non-dismissing secondary
/// action sits at the leading edge, clear of the Cancel / default-action pair at
/// the trailing edge, and Return / Escape are scoped to the sheet rather than
/// to the whole window.
struct APIKeyEditorSheet: View {
  /// The alert-shaped failure the engine reported, carried as view state so the
  /// alert can present it. Purely a container — the strings are the engine's.
  private struct SaveFault {
    let title: String
    let message: String
  }

  var apiKey: APIKeyModel
  /// The key already stored, empty on first run. Drives the first-connect vs.
  /// rotate wording, and whether the "get a key" action is worth showing at all
  /// (once a key exists the user has clearly already found the dashboard).
  let savedKey: String
  /// Reports a newly-stored key back to the settings row.
  var onSaved: (String) -> Void

  @Environment(\.dismiss)
  private var dismiss
  @Environment(\.openURL)
  private var openURL

  @State private var draft: String
  @State private var isRevealed = false
  @State private var isValidating = false
  /// Inline, recoverable problems (wrong key, server unreachable) — shown above
  /// the buttons so the user just edits the field and retries.
  @State private var errorMessage: String?
  /// A non-inline system fault (the Keychain write itself failed). Retyping the
  /// key can't fix it, so it's surfaced as an alert rather than footer text —
  /// the convention for genuine faults, and the reason the recoverable cases
  /// above are *not* alerts. Which outcomes land here rather than inline is the
  /// engine's call (`APIKeySubmission.Outcome.failureReport`), wording included.
  @State private var saveFault: SaveFault?
  /// The in-flight verify-then-store. Held so dismissing the sheet can cancel
  /// it: without that, Cancel/Escape during a check would let the submission run
  /// on and persist the key anyway — a Cancel that silently commits.
  @State private var submitTask: Task<Void, Never>?
  @FocusState private var fieldFocused: Bool

  /// The draft trimmed to usable text (the engine's shared rule), nil when blank.
  private var trimmedKey: String? { draft.trimmedNonEmpty() }

  /// The first-connect vs. rotate wording, resolved from the same engine
  /// projection the row uses so the sheet and the row can't disagree about
  /// whether a key is stored.
  private var display: APIKeyDisplay { .resolve(key: savedKey) }

  /// Enabled for any non-empty key while no validation is in flight. We don't
  /// gate on "differs from the saved key" — re-submitting an unchanged key is a
  /// harmless re-validate against AssemblyAI, and a button that's disabled for a
  /// reason the user can't see is worse than a redundant round trip.
  private var canSubmit: Bool { trimmedKey != nil && !isValidating }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("AssemblyAI API Key")
          .font(.headline)
        Text(display.rationale)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      // A single credential field reads as more native left un-labelled and
      // full-width: the headline above already names it, so a right-aligned
      // "API Key:" column would only repeat it. This matches the plain-field
      // layout of a system sign-in sheet rather than a settings form row.
      VStack(alignment: .leading, spacing: 8) {
        keyField
        // Pin the checkbox style: outside a `Form` the default toggle style
        // still renders as a checkbox here, but stating it keeps the reveal a
        // labeled checkbox (the Wi-Fi "Show password" idiom) rather than
        // leaving it to the ambient style.
        Toggle("Show key", isOn: $isRevealed)
          .toggleStyle(.checkbox)
          .accessibilityIdentifier(UITestIdentifiers.apiKeyReveal)
      }

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
    .alert(
      saveFault?.title ?? "", isPresented: $saveFault.isPresent(), presenting: saveFault
    ) { _ in
      Button("OK", role: .cancel) {
        // Dismissing is the whole action: the system closes the alert.
      }
    } message: { fault in
      Text(fault.message)
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
  @ViewBuilder private var statusText: some View {
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
      if !display.isConnected {
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
      Button(display.commitButtonTitle, action: submit)
        .glassButtonStyleCompat(prominent: true)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .accessibilityIdentifier(UITestIdentifiers.apiKeySave)
    }
  }

  init(apiKey: APIKeyModel, savedKey: String, onSaved: @escaping (String) -> Void) {
    self.apiKey = apiKey
    self.savedKey = savedKey
    self.onSaved = onSaved
    _draft = State(initialValue: savedKey)
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
    guard canSubmit, let key = trimmedKey else {
      return
    }
    isValidating = true
    errorMessage = nil
    submitTask = Task {
      let result = await apiKey.submit(key)
      // The sheet may be gone — cancelled, or dismissed by the window closing.
      // Writing `@State` on a torn-down view can't surface anything (a
      // `.saveFailed` alert would have nowhere to appear), so stop here.
      guard !Task.isCancelled else {
        return
      }
      isValidating = false
      // Which outcomes are recoverable-inline and which is a genuine fault (and
      // what each one says) is the engine's single classification, so this can't
      // disagree with it — nor ship a new outcome that reports nothing at all.
      switch result.failureReport {
      case nil:
        // Verified and stored — hand the key back to the row and close. The
        // controller reveals the overlay via its hasAPIKey observer.
        onSaved(key)
        dismiss()

      case .some(.inline(let message)):
        errorMessage = message

      case let .some(.alert(title, message)):
        // A system fault retyping can't fix — surface it as an alert, not inline.
        saveFault = SaveFault(title: title, message: message)
      }
    }
  }
}
