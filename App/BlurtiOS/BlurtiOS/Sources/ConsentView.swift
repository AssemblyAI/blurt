import BlurtiOSCore
import SwiftUI

/// "Send your voice to AssemblyAI?" — asked once, before the listening window
/// first opens (App Review 5.1.2(i)). It names the third party, says plainly
/// what goes to it, and links the privacy policy. The list is the disclosure
/// `AIConsent.version` covers: change one, change the other.
struct ConsentView: View {
  let allow: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "Blurt turns your voice into text with AssemblyAI, a third-party AI service. "
              + "It records only while you dictate.")
        }
        Section {
          Label("Your voice while you dictate", systemImage: "waveform")
          Label("The text just before your cursor", systemImage: "text.cursor")
          Label("Your recent dictations", systemImage: "clock.arrow.circlepath")
          Label("Your key terms, including contact names", systemImage: "person.text.rectangle")
        } header: {
          Eyebrow("Sent to AssemblyAI")
        } footer: {
          Text("The context helps AssemblyAI spell names right and continue your sentence.")
        }
        Section {
          Link("AssemblyAI's privacy policy", destination: AIConsent.privacyPolicyURL)
        }
      }
      .brandForm()
      .navigationTitle("Before you blurt")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Allow") {
            dismiss()
            allow()
          }
        }
      }
    }
    .tint(BlurtBrand.accent)
  }
}
