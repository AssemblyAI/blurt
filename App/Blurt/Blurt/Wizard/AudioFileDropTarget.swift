import SwiftUI

extension View {
  /// Makes the whole view a drop target for audio and video files, as
  /// MacWhisper's and ImageOptim's windows are: nothing on screen asks for a
  /// drop, and only while a file is held over the window does it say what
  /// letting go will do.
  func audioFileDropTarget(_ model: TranscriptsModel) -> some View {
    modifier(AudioFileDropTarget(model: model))
  }
}

private struct AudioFileDropTarget: ViewModifier {
  var model: TranscriptsModel
  @State private var isTargeted = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .dropDestination(for: URL.self) { urls, _ in
        // Never over a recording: it owns the sheet until it's saved.
        guard !model.isRecordingBusy else { return false }
        model.openFiles(urls)
        return true
      } isTargeted: {
        isTargeted = $0
      }
      // The window's content gives way entirely while a file is held over
      // it: one target, nothing behind it competing.
      .opacity(isTargeted ? 0 : 1)
      .overlay {
        if isTargeted { dropTarget }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTargeted)
  }

  /// What the window becomes while a file is held over it: a large dashed
  /// well in the accent around one glyph and one line, as a Mac app's empty
  /// drop well reads.
  private var dropTarget: some View {
    VStack(spacing: 12) {
      Image(systemName: "waveform.badge.plus")
        .font(.system(size: 44, weight: .light))
      Text("Drop to Transcribe")
        .font(.title2.weight(.semibold))
      Text("Audio or video files")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .foregroundStyle(BlurtBrand.accent)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(BlurtBrand.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        .padding(16)
    )
    .allowsHitTesting(false)
    .transition(.opacity)
  }
}
