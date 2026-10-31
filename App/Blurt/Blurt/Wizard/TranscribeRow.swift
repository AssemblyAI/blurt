import SwiftUI

/// The way in for audio, as its own drop well above the settings and the
/// history — the pattern of Apple's Transporter, scaled down: a dashed, rounded
/// well with a glyph and "Drop an audio file here", and Record and Browse… at
/// its end for the other two ways in. The whole window takes the drop (`audioFileDropTarget`); while a
/// file hovers anywhere over it, the well takes the accent and says so.
struct TranscribeRow: View {
  var model: TranscriptsModel
  @Environment(\.isFileDropTargeted) private var isTargeted
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isImporting = false

  private var shape: RoundedRectangle { FormPanel.shape }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: isTargeted ? "waveform.badge.plus" : "waveform")
        .foregroundStyle(BlurtBrand.accent)
        .frame(width: 22)
        .accessibilityHidden(true)
      Text(isTargeted ? "Drop to transcribe" : "Drop an audio file here")
        .foregroundStyle(isTargeted ? AnyShapeStyle(BlurtBrand.accent) : AnyShapeStyle(.secondary))
        .lineLimit(1)
      Spacer(minLength: 8)
      Button {
        model.startRecording()
      } label: {
        Label("Record", systemImage: "record.circle")
          .symbolRenderingMode(.monochrome)
      }
      .buttonStyle(.borderedProminent)
      .tint(BlurtBrand.accent)
      .disabled(!model.canRecord)
      .accessibilityIdentifier(UITestIdentifiers.transcribeRecordButton)
      .help("Record your microphone and your Mac's audio together, transcribed live")
      Button("Browse…") { isImporting = true }
        .help("Choose an audio or video file to transcribe")
        .accessibilityIdentifier(UITestIdentifiers.transcribeBrowseButton)
    }
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .background {
      shape.fill(BlurtBrand.accent.opacity(isTargeted ? 0.08 : 0))
      shape.strokeBorder(
        isTargeted ? AnyShapeStyle(BlurtBrand.accent) : AnyShapeStyle(Color(nsColor: .separatorColor).opacity(0.5)),
        style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [4, 3]))
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTargeted)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Transcribe: drop an audio or video file on the window, record, or browse")
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audiovisualContent]) { result in
      if case .success(let url) = result { model.transcribe(url) }
    }
  }
}
