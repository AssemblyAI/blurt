import Accessibility
import AppKit
import AssemblyAI
import BlurtEngine
import SwiftUI

extension View {
  /// Makes the whole view a drop target for audio and video files: a drop
  /// starts a transcription in `model`, and the result comes up in a sheet
  /// over the window. The hover state is published through
  /// the environment, so the drop well (`TranscribeRow`) lights up wherever over the window the file
  /// is held — the window is the target, the well is where it says so.
  func audioFileDropTarget(_ model: TranscriptsModel) -> some View {
    modifier(AudioFileDropTarget(model: model))
  }
}

extension EnvironmentValues {
  /// Whether a file is being dragged over the window's drop target.
  @Entry var isFileDropTargeted = false
}

private struct AudioFileDropTarget: ViewModifier {
  var model: TranscriptsModel
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .environment(\.isFileDropTargeted, isTargeted)
      .dropDestination(for: URL.self) { urls, _ in
        // One file at a time: the sheet shows one transcript.
        // A refused file says why rather than just snapping back: the zone
        // already promised a transcription.
        // Never over a recording: it owns the sheet until it's saved.
        guard !model.isRecordingBusy else { return false }
        guard let url = urls.first(where: TranscriptsModel.accepts) else {
          model.refuse(urls.first)
          return true
        }
        model.transcribe(url)
        return true
      } isTargeted: {
        isTargeted = $0
      }
      .sheet(isPresented: isPresented) {
        TranscriptSheet(model: model)
      }
  }

  /// The sheet is up whenever a file is in flight or has an outcome to show;
  /// closing it by any route (Done, Esc) goes through `dismiss()`.
  private var isPresented: Binding<Bool> {
    Binding(
      get: { model.state != .idle },
      set: { if !$0 { model.dismiss() } })
  }
}

/// A transcript's progress and outcome: a spinner with Cancel while a file
/// uploads and transcribes, then the transcript — selectable, with Copy — or the reason
/// it failed.
private struct TranscriptSheet: View {
  var model: TranscriptsModel
  @State private var copied = false
  @State private var pendingDelete: SavedTranscript?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch model.state {
      case .idle:
        EmptyView()
      case .recording:
        LiveRecordingView(model: model)
      case .finishingRecording:
        header("Recording")
        ProgressLine("Finishing…").frame(maxWidth: .infinity, minHeight: 80)
      case .transcribing(let fileName, let phase):
        header(fileName)
        ProgressLine(phase == .uploading ? "Uploading…" : "Transcribing…").frame(maxWidth: .infinity, minHeight: 80)
        buttons { Button("Cancel", role: .cancel) { model.dismiss() }.keyboardShortcut(.cancelAction) }
      case .finished:
        finished(model.openEntry)
      case .failed(let fileName, let message):
        header(fileName)
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        buttons { Button("OK") { model.dismiss() }.keyboardShortcut(.defaultAction) }
      }
    }
    .padding(20)
    // Within the window's width — a sheet wider than its window looks
    // detached; the chips wrap to a third row instead.
    .frame(width: MainWindow.contentWidth - 40)
    // Esc closes the sheet in every state, not only while Cancel is showing.
    .onExitCommand { model.dismiss() }
    // The spinner's replacement is silent otherwise.
    .onChange(of: model.state) { _, state in
      switch state {
      case .finished: AccessibilityNotification.Announcement("Transcript ready").post()
      case .failed(_, let message): AccessibilityNotification.Announcement(message).post()
      case .recording: AccessibilityNotification.Announcement("Recording").post()
      case .idle, .transcribing, .finishingRecording: break
      }
    }
    .deleteConfirmation(for: $pendingDelete, model: model, closesSheet: true)
    // "Copied" belongs to the text that was copied, not the next facet's.
    .onChange(of: model.selection) { copied = false }
  }

  /// The open entry's transcript, its chips and actions.
  @ViewBuilder
  private func finished(_ entry: SavedTranscript?) -> some View {
    HStack {
      // The saved entry's title, which becomes the LLM's once it lands.
      header(entry?.title ?? "")
      Spacer()
      // Plays what's showing: Full's own audio, or a task result read aloud.
      if model.canPlayShown {
        let playing = model.isPlayingShown
        Button {
          model.togglePlayShown()
        } label: {
          Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
        }
        .controlSize(.small)
        .help(
          model.selection == .full && entry?.kind != .dictation
            ? "Play the audio"
            : "Read \(model.selection == .full ? "it" : model.selection.title.lowercased()) aloud")
      }
      // Where the audio lives, a click from Finder.
      if let url = entry?.audioURL {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Label("Show in Finder", systemImage: "folder")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(!FileManager.default.fileExists(atPath: url.path))
        .help("Show in Finder")
      }
    }
    TranscriptFacetPicker(model: model)
    facetContent
    HStack {
      if let entry {
        Button("Delete…", role: .destructive) { pendingDelete = entry }
      }
      Spacer()
      Button(copied ? "Copied" : "Copy") { model.selectedText.map(copy) }
        .disabled(model.selectedText == nil)
      Button("Done") { model.dismiss() }
        .keyboardShortcut(.defaultAction)
    }
  }

  /// The selected facet's text area: the text, or its progress, or why it
  /// failed with a way to try again.
  @ViewBuilder
  private var facetContent: some View {
    let content = model.contents[model.selection]
    Group {
      switch content {
      case .ready(let text):
        ScrollView {
          Group {
            // A transcript's Full tab, with speakers told apart, shows as
            // coloured turns (parsed once, `fullTurns`); everything else is
            // prose, shown as it is.
            if model.selection == .full, !model.fullTurns.isEmpty {
              SpeakerTurnsView(turns: model.fullTurns)
            } else {
              Text(text).textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }
      case .failed(let message):
        VStack(spacing: 8) {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button("Try Again") { model.retry() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
      case .loading:
        ProgressLine(model.selection.progressTitle).frame(maxWidth: .infinity, maxHeight: .infinity)
      case nil:
        // Custom before a request: the popover is asking for one.
        Text("Describe what to do with the transcript.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .textAreaSurface()
  }

  private func header(_ fileName: String) -> some View {
    Label(fileName, systemImage: "waveform")
      .font(.headline)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
    HStack {
      Spacer()
      content()
    }
  }

  private func copy(_ transcript: String) {
    NSPasteboard.copyAnnounced(transcript)
    copied = true
  }
}

/// The facet chips over the transcript: Full (the transcript itself, so the
/// original is always one click back), the stock transforms, and Custom, which
/// asks for its request in a popover. Capsules that wrap onto a second row;
/// the selected one takes the accent. A row of toggles in a single-choice
/// group, so each reads to VoiceOver as a button with the selected trait.
private struct TranscriptFacetPicker: View {
  var model: TranscriptsModel
  @State private var isEditingCustom = false
  @State private var customDraft = ""

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(model.availableFacets, id: \.self) { facet in
        chip(facet)
      }
    }
    // One single-choice group to VoiceOver, announced before the chip it's on.
    .accessibilityElement(children: .contain)
    .accessibilityLabel("View")
  }

  private func chip(_ facet: TranscriptFacet) -> some View {
    let isSelected = model.selection == facet
    return Button {
      // Custom is selected only once it has a request: the first click (and
      // a click on it while selected) asks for one; Cancel leaves the
      // selection where it was.
      if facet == .custom, model.customRequest.isEmpty || isSelected {
        customDraft = model.customRequest
        isEditingCustom = true
      } else {
        model.select(facet)
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: facet.systemImage)
        Text(facet.title)
        if model.contents[facet] == .loading, !isSelected {
          ProgressView().controlSize(.mini)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .background(
        isSelected ? AnyShapeStyle(BlurtBrand.accent) : AnyShapeStyle(.quaternary),
        in: Capsule()
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(UITestIdentifiers.facetChipPrefix + facet.rawValue)
    .popover(isPresented: facet == .custom ? $isEditingCustom : .constant(false), arrowEdge: .bottom) {
      customEditor
    }
  }

  /// Custom's request, asked for where the chip is.
  private var customEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("What should Blurt do with this transcript?")
        .font(.headline)
      TextField(
        "Custom request", text: $customDraft, prompt: Text("e.g. Write it up as a blog post"), axis: .vertical
      )
      .lineLimit(2...4)
      .textFieldStyle(.roundedBorder)
      .onSubmit(apply)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { isEditingCustom = false }
          .keyboardShortcut(.cancelAction)
        Button("Apply", action: apply)
          .keyboardShortcut(.defaultAction)
          .disabled(customDraft.trimmedNonEmpty() == nil)
      }
    }
    .padding(14)
    .frame(width: 320)
  }

  private func apply() {
    model.applyCustom(customDraft)
    isEditingCustom = false
  }
}

/// A spinner beside a word on what it's waiting for: every progress state in
/// the sheet, spelled once.
struct ProgressLine: View {
  let title: String
  init(_ title: String) { self.title = title }

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(title).foregroundStyle(.secondary)
    }
  }
}

extension View {
  /// The sheet's read-only text area: a fixed height on the text background,
  /// with an edge — the window colour would leave the text with none.
  func textAreaSurface() -> some View {
    frame(height: 260)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
  }
}
