import BlurtEngine
import SwiftUI

/// The sheet while recording: a pulsing red dot and the elapsed time, the
/// transcript as it streams in — settled turns in full, the words being spoken
/// now in secondary — following the newest line, and Stop (the default) beside
/// Discard…, which asks first: a recording thrown away is gone.
struct LiveRecordingView: View {
  var model: TranscriptsModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isConfirmingDiscard = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
        .foregroundStyle(model.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        .pulsingOpacity(period: 1.2, minOpacity: 0.4, animated: !reduceMotion && !model.isPaused)
        .accessibilityHidden(true)
      // The system's own running clock: it redraws itself, holds still while
      // paused, and shows hours once there are any.
      Text(
        "\(model.isPaused ? "Paused" : "Recording") \(Text(timerInterval: model.clockStart...Date.distantFuture, pauseTime: model.pausedAt, countsDown: false))"
      )
      .monospacedDigit()
      .font(.headline)
      Spacer()
    }
    ScrollView {
      Group {
        if model.live.finals.isEmpty, model.live.partial == nil {
          Text("Listening…").foregroundStyle(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 6) {
            SpeakerTurnsView(turns: model.live.speakerTurns).equatable()
            // The words being spoken now: shown last, dimmed.
            if let partial = model.live.partial {
              Text(partial).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
          }
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
    // Follows the newest line as the transcript grows.
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .textAreaSurface()
    HStack {
      Button("Discard…", role: .destructive) { isConfirmingDiscard = true }
      Spacer()
      Button {
        model.togglePause()
      } label: {
        Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "record.circle" : "pause.fill")
      }
      .help(model.isPaused ? "Carry on recording" : "Pause: nothing is recorded until you resume")
      Button {
        model.stopRecording()
      } label: {
        Label("Stop", systemImage: "stop.fill")
      }
      .keyboardShortcut(.defaultAction)
    }
    .confirmationDialog("Discard this recording?", isPresented: $isConfirmingDiscard) {
      Button("Discard", role: .destructive) { model.discardRecording() }
    } message: {
      Text("The recording and its transcript will be deleted.")
    }
  }
}
