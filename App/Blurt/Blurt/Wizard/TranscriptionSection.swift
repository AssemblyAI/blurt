import BlurtEngine
import SwiftUI

/// The Styles pane's leading section: the enhanced-transcripts switch. Every dictation request asks AssemblyAI's dictation API for its
/// server-side cleanup rewrite, so the response always holds both versions;
/// while this is on (the default) the polished one is pasted, and turned off
/// the verbatim transcript is pasted exactly as spoken. The transcriber reads
/// the same default this toggle writes at every request, so a change applies to
/// the next dictation — see `AssemblyAITranscriber.transcript(from:)`.
/// Settings-only — not a wizard step, since it never gates setup.
struct TranscriptionSection: View {
  // The unset default comes from the store, not a literal here: the transcriber
  // reads the same slot per request, and two spellings of "unset means on" would let
  // the toggle and the request disagree about an untouched install.
  @AppStorage(EnhancedTranscriptsStore.defaultsKey)
  private var enhancedTranscripts = EnhancedTranscriptsStore.defaultValue

  // "" is "nothing persisted"; the unset default belongs to
  // `RewriteMode.fromPersisted`, as the key slots' defaults belong to `TriggerKeyBindings`.
  @AppStorage(RewriteModeStore.defaultsKey)
  private var rewriteModeRaw = ""

  private var rewriteMode: Binding<RewriteMode> {
    Binding(
      get: { RewriteMode.fromPersisted(rewriteModeRaw) },
      // Through the store, which owns the encoding (see `KeysSettingsTab`).
      set: { RewriteModeStore().mode = $0 }
    )
  }

  var body: some View {
    Section {
      Toggle(isOn: $enhancedTranscripts) {
        SettingLabel(
          title: "Enhanced transcripts",
          systemImage: "wand.and.stars",
          subtitle: "Removes filler words and fixes punctuation."
        )
      }
      .accessibilityIdentifier(UITestIdentifiers.enhancedTranscriptsToggle)
      // Picks the model for the rewrite the switch above pastes, so it is
      // disabled with it, as the styles below are.
      PickerSettingRow(
        title: "Dictation mode",
        systemImage: "speedometer",
        accessibilityID: UITestIdentifiers.rewriteModePicker,
        subtitle: "Fast for speed. Smart for better rewrites.",
        selection: rewriteMode
      ) {
        ForEach(RewriteMode.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .disabled(!enhancedTranscripts)
      .help(RewriteMode.guidance)
    } footer: {
      Text("Turn off Enhanced transcripts to paste the transcript without cleanup or custom styling.")
    }
  }
}
