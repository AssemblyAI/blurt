import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// Paste an AssemblyAI API key, verified against the API before it is saved
/// (`APIKeySubmission` owns that rule). Every build shows it, the way the Mac app
/// works, until Sign in with AssemblyAI exists; then it becomes the advanced
/// path for contributors and self-built copies.
struct KeyEntryView: View {
  var apiKey: APIKeyModel
  @Environment(\.dismiss) private var dismiss
  @State private var key = ""
  @State private var inlineError: String?
  @State private var isSubmitting = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("Paste your key", text: $key)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
          if let inlineError {
            Text(inlineError).font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(
              BlurtBrand.errorOrange)
          }
        } header: {
          Eyebrow("API key")
        } footer: {
          Text("Keys live at assemblyai.com/dashboard/api-keys. Stored in the Keychain on this phone.")
        }
      }
      .brandForm()
      .navigationTitle("API key")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSubmitting ? "Checking…" : "Connect") { Task { await submit() } }
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
        }
      }
    }
  }

  private func submit() async {
    isSubmitting = true
    defer { isSubmitting = false }
    let outcome = await apiKey.submit(key)
    switch outcome.failureReport {
    case .none: dismiss()
    case .some(.inline(let message)): inlineError = message
    case .some(.alert(let title, let message)): inlineError = "\(title) \(message)"
    }
  }
}
