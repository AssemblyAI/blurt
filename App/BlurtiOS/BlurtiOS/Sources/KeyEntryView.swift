import BlurtEngine
import SwiftUI

/// Paste an AssemblyAI API key, verified against the API before it is saved
/// (`APIKeySubmission` owns that rule). Debug builds only: the shipping app
/// signs in with AssemblyAI and never shows a key. It exists so the pipeline can
/// be tested on a phone before that service is in place.
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
            Text(inlineError).font(.footnote).foregroundStyle(BlurtBrand.errorOrange)
          }
        } footer: {
          Text("Keys live at assemblyai.com/dashboard/api-keys. Stored in the Keychain on this phone.")
        }
      }
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
    case nil: dismiss()
    case .inline(let message): inlineError = message
    case .alert(let title, let message): inlineError = "\(title) \(message)"
    }
  }
}
