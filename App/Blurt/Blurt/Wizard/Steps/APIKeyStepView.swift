import BlurtAssemblyAI
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
///
/// With sign-in configured (`AssemblyAIAccount.isAvailable`), signing in fills
/// the same key a paste would. Which single row the section shows — the choice
/// between the two, the key row, or the signed-in account row — is the engine's
/// `CredentialRows`, where the reasons for each are.
struct APIKeyStepView: View {
  var apiKey: APIKeyModel
  var account: AssemblyAIAccount

  /// The key currently in the Keychain, loaded on appear (empty when none).
  @State private var savedKey = ""
  @State private var isPresentingEditor = false

  /// How the stored key is presented — the masking rule, the status wording, and
  /// the control titles all live in the engine's `APIKeyDisplay`, where they're
  /// unit-tested (a fixed `suffix(4)` here once put a short key on screen whole).
  /// This view just renders what it resolves to.
  private var display: APIKeyDisplay { .resolve(key: savedKey) }

  /// Which row shows — the engine's `CredentialRows`, so the rule is tested
  /// rather than restated here.
  private var rows: CredentialRows {
    .resolve(isKeyStored: display.isConnected, isSignInAvailable: account.isAvailable, status: account.status)
  }

  var body: some View {
    Section {
      switch rows {
      case .choice, .accountRow:
        // One view for both: the sign-in's state (the web session, the
        // in-flight flag, the last failure) lives in it, and must survive the
        // row turning from the choice into "Signed in as …".
        AccountRowView(account: account, isPresentingKeyEditor: $isPresentingEditor)

      case .keyRow(let connectIsPrimary):
        SettingRow(title: "API Key", systemImage: "key.fill") {
          HStack(spacing: 12) {
            statusLabel
            Button(display.editButtonTitle) { isPresentingEditor = true }
              // Prominent (brand-green fill) only while it is the one thing
              // setup is waiting on.
              .glassButtonStyleCompat(prominent: connectIsPrimary)
              .accessibilityIdentifier(
                display.isConnected ? UITestIdentifiers.apiKeyChange : UITestIdentifiers.apiKeyConnect
              )
          }
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
      account.refreshStatus()
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
  /// exists. Monospaced only when the text *is* an identifier, so the revealed
  /// characters line up as a key ending rather than prose being set in code type.
  private var statusLabel: some View {
    Text(display.statusText)
      .font(display.rendersIdentifier ? .body.monospaced() : .body)
      .foregroundStyle(.secondary)
      // The bullets are decoration; the engine's label spells the state out.
      .accessibilityLabel(display.accessibilityLabel)
      .accessibilityIdentifier(
        display.isConnected
          ? UITestIdentifiers.apiKeySavedStatus : UITestIdentifiers.apiKeyNotConnected
      )
  }
}
