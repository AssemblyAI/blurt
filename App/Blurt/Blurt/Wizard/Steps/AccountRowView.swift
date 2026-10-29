import BlurtEngine
import SwiftUI

/// The "Sign in with AssemblyAI" row of the AssemblyAI section: "Sign In…"
/// while signed out, or who is signed in and "Sign Out". The wording and the
/// inline-vs-alert split are the engine's (`AssemblyAIAccount.Status.statusText`,
/// `SignInFailure.failureReport`, `signOut()`), the same split the key sheet
/// follows: a problem a retry can fix shows under the row, only a Keychain fault
/// is an alert.
struct AccountRowView: View {
  var account: AssemblyAIAccount
  /// Whether "Sign In…" is the section's filled button (`CredentialRows.primary`).
  let isPrimary: Bool

  @State private var signIn = AccountSignIn()
  /// A sign-in or sign-out in flight; the button is disabled so they can't overlap.
  @State private var isWorking = false
  /// The last attempt's failure, until the next attempt: a recoverable one in
  /// red under the row, a Keychain fault as an alert. The strings are the
  /// engine's.
  @State private var failure: APIKeySubmission.FailureReport?

  private var alert: (title: String, message: String)? {
    if case .alert(let title, let message) = failure { (title, message) } else { nil }
  }

  private var isPresentingAlert: Binding<Bool> {
    Binding(get: { alert != nil }, set: { if !$0 { failure = nil } })
  }

  var body: some View {
    // A `Group` so the row and its inline error stay sibling rows of the
    // parent `Section` while sharing the alert and the teardown.
    Group {
      row
      if case .inline(let message) = failure {
        // Red, no caution glyph: "retry this", not "something broke".
        Text(message)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .alert(alert?.title ?? "", isPresented: isPresentingAlert, presenting: alert) { _ in
      Button("OK", role: .cancel) {}
    } message: { alert in
      Text(alert.message)
    }
    // The row goes away with its window or a Settings tab switch; either ends
    // the browser session too, since nothing would be left to finish it.
    .onDisappear { signIn.cancel() }
  }

  private var row: some View {
    SettingRow(title: "Account", systemImage: "person.crop.circle") {
      HStack(spacing: 12) {
        if let statusText = account.status.statusText {
          Text(statusText)
            .foregroundStyle(.secondary)
            // A long work address mustn't push Sign Out off the row; the full
            // text is on hover.
            .lineLimit(1)
            .truncationMode(.middle)
            .help(statusText)
        }
        if isWorking {
          ProgressView().controlSize(.small)
            .accessibilityLabel(account.status.statusText == nil ? "Signing in" : "Signing out")
        }
        if account.status != .signedOut {
          Button("Sign Out", action: signOut)
            .disabled(isWorking)
        } else {
          Button("Sign In with AssemblyAI…", action: startSignIn)
            .glassButtonStyleCompat(prominent: isPrimary)
            .disabled(isWorking)
        }
      }
    }
  }

  private func startSignIn() {
    begin()
    Task {
      let outcome = await signIn.run(account)
      isWorking = false
      if case .failed(let reason) = outcome { failure = reason.failureReport }
    }
  }

  private func signOut() {
    begin()
    Task {
      failure = await account.signOut()
      isWorking = false
    }
  }

  private func begin() {
    isWorking = true
    failure = nil
  }
}
