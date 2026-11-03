import SwiftUI

/// The way in for audio, as the ready screen's first form row: "Record or
/// transcribe" over a hint, and trailing **Record** (the window's prominent
/// action) and **Browse…** (the open panel). The whole window takes a dropped
/// file (`audioFileDropTarget`); while one hovers anywhere over it, the whole
/// row turns into the drop target — accent-tinted, a dashed accent outline,
/// and one line saying what letting go will do — so there's no mistaking it.
///
/// Record is disabled while anything else has the transcript sheet; a running
/// recording's Stop lives in that sheet, which can't be dismissed without one.
struct TranscribeRow: View {
  var model: TranscriptsModel
  @Environment(\.isFileDropTargeted) private var isTargeted
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isImporting = false

  var body: some View {
    Group {
      if isTargeted {
        dropTarget
      } else {
        row
      }
    }
    .listRowBackground(
      ZStack {
        if isTargeted {
          Rectangle().fill(BlurtBrand.accent.opacity(0.12))
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(BlurtBrand.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
      }
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTargeted)
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audiovisualContent]) { result in
      if case .success(let url) = result { model.transcribe(url) }
    }
  }

  /// The row while a file hovers over the window: one centered line in the
  /// accent, at the row's usual height.
  private var dropTarget: some View {
    Label("Drop to transcribe", systemImage: "arrow.down.doc")
      .font(.headline)
      .foregroundStyle(BlurtBrand.accent)
      .frame(maxWidth: .infinity, minHeight: 36)
  }

  private var row: some View {
    SettingRow(
      title: "Record or transcribe", systemImage: "waveform", subtitle: "Record a meeting, or drop in audio."
    ) {
      HStack(spacing: 6) {
        Button {
          model.startRecording()
        } label: {
          Label("Record", systemImage: "record.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canRecord)
        .accessibilityIdentifier(UITestIdentifiers.transcribeRecordButton)
        .help(
          model.canRecord
            ? "Record your microphone and your Mac's audio together, transcribed live"
            : "Available when the current transcription finishes")
        Button("Browse…") { isImporting = true }
          // `transcribe(_:)` refuses while a recording is busy, so the button
          // says so rather than opening a panel that does nothing.
          .disabled(model.isRecordingBusy)
          .help("Choose an audio or video file to transcribe")
          .accessibilityIdentifier(UITestIdentifiers.transcribeBrowseButton)
      }
      .fixedSize()
    }
  }
}
