import AVFoundation
import BlurtDesign
import BlurtEngine
import SwiftUI

/// Paste a key, checked with AssemblyAI before it is saved (`APIKeySubmission`
/// owns that rule): the field, Continue, Get a free key, and what happens to
/// the key and the audio.
struct KeyStep: View {
  var apiKey: APIKeyModel
  @Environment(\.openURL)
  private var openURL
  @State private var draft = ""
  @State private var isChecking = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      SecureField("Paste your API key", text: $draft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit { Task { await submit() } }
        .brandInput()
      if let errorMessage {
        Text(errorMessage)
          .bodyFont(DesignTokens.Typography.sizeCaption)
          .foregroundStyle(BlurtBrand.errorOrange)
          .fixedSize(horizontal: false, vertical: true)
      }
      // Stacked, not side by side: at half the card's width the mono labels
      // wrap ("GET A / FREE KEY").
      VStack(spacing: DesignTokens.Metrics.appChipGap) {
        Button(isChecking ? "Checking…" : "Continue") { Task { await submit() } }
          .buttonStyle(BrandButtonStyle())
          .disabled(isChecking || draft.trimmedNonEmpty() == nil)
        Button("Get a free key") { openURL(APIKeyStore.dashboardURL) }
          .buttonStyle(BrandButtonStyle(role: .secondary))
      }
      Text(
        "Blurt sends what you dictate to AssemblyAI to transcribe it, using this key. "
          + "New accounts come with free credits. The key is stored in this iPhone's Keychain."
      )
      .brandFootnote()
    }
  }

  private func submit() async {
    guard !isChecking else {
      return
    }
    isChecking = true
    defer { isChecking = false }
    switch await apiKey.submit(draft).failureReport {
    case .none:
      errorMessage = nil
      draft = ""

    case .some(.inline(let message)):
      errorMessage = message

    case let .some(.alert(title, message)):
      errorMessage = "\(title) \(message)"
    }
  }
}
