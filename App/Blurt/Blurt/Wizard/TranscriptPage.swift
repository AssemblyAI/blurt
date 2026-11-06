import Accessibility
import AppKit
import AssemblyAI
import BlurtEngine
import SwiftUI

/// An opened item, pushed over the main window's Library on its
/// `NavigationStack` as an entry opens in Journal: the system's back button
/// leads the toolbar, the item's actions follow as icons — the View menu,
/// Play, Copy, Show in Finder, Delete — and its title heads the transcript
/// below. Nothing here is edited, so there's no Done or check mark: back (or
/// Esc) returns to the Library. The same page shows a recording as it runs, a
/// file's progress, and why one failed.
struct TranscriptPage: View {
  var model: TranscriptsModel
  @State private var copied = false
  @State private var pendingDelete: SavedTranscript?

  var body: some View {
    Group {
      if case .finished = model.state, case .ready = model.contents[model.selection] {
        // A transcript scrolls as one page with its title, as a note does:
        // the title goes up with the text rather than staying pinned, and the
        // scroller is the window's own.
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            titleLine
            facetContent
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          titleLine
          status
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }

    .toolbar { toolbarItems }
    // Esc goes back, as the back button does, wherever focus is — a hidden
    // button rather than `onExitCommand`, which needs the page focused and
    // lost it to the View menu. Not over a recording (`dismiss`).
    .background {
      if !model.isRecordingBusy {
        Button("Back") { model.dismiss() }
          .keyboardShortcut(.cancelAction)
          .hidden()
      }
    }
    // The page's replacement is silent otherwise.
    .onChange(of: model.state) { _, state in
      switch state {
      case .finished: AccessibilityNotification.Announcement("Transcript ready").post()
      case .failed(_, let message): AccessibilityNotification.Announcement(message).post()
      case .recording: AccessibilityNotification.Announcement("Recording").post()
      case .idle, .transcribing, .finishingRecording: break
      }
    }
    // "Copied" belongs to the text that was copied, not the next view's.
    .onChange(of: model.selection) { copied = false }
    // Asks first; deleting the open entry slides back to the Library.
    .deleteConfirmation(for: $pendingDelete, model: model)
  }

  /// The title heads the page, as Notes' date line heads a note: in the
  /// toolbar it took the actions' room, pushing them into a » menu. Only where
  /// it says something the text doesn't — a recording's or a file's; a
  /// dictation's or a read's would just repeat the words below it.
  @ViewBuilder private var titleLine: some View {
    if showsTitle {
      Text(title)
        .font(.body.weight(.semibold))
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }

  /// Everything but a transcript in hand: a recording, progress, a failure,
  /// or a task still on its way.
  @ViewBuilder private var status: some View {
    switch model.state {
    case .idle:
      EmptyView()
    case .recording:
      LiveRecordingView(model: model)
    case .finishingRecording:
      ProgressLine("Finishing…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .transcribing(_, let phase):
      ProgressLine(phase == .uploading ? "Uploading…" : "Transcribing…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .finished:
      facetContent
    case .failed(_, let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
  }

  /// Whether the page has a title: a saved recording's or file's, or a file
  /// going up — never an entry whose title is only the start of its text, nor
  /// a recording under way, whose live header ("● Recording 17:26") already
  /// says so.
  private var showsTitle: Bool {
    switch model.state {
    case .finished: model.openEntry?.isTranscript == true
    case .recording, .finishingRecording, .idle: false
    case .transcribing, .failed: true
    }
  }

  /// What the page is headed with: the saved entry's title (the LLM's once
  /// it lands), the file going up, or the recording.
  private var title: String {
    switch model.state {
    case .finished: model.openEntry?.title ?? ""
    case .transcribing(let fileName, _), .failed(let fileName, _): fileName
    case .recording, .finishingRecording: "Recording"
    case .idle: ""
    }
  }

  /// Once there's a transcript, its view and actions — the system's back
  /// button leads (`ReadyView`'s `NavigationStack`): the View
  /// menu, Play or Listen, Copy, and Show in Finder where
  /// there's a file, then Delete in a group of its own.
  @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
    if model.state == .finished { actions }
  }

  @ToolbarContentBuilder private var actions: some ToolbarContent {
    ToolbarItem {
      TranscriptFacetMenu(model: model)
    }
    ToolbarItemGroup {
      if model.canPlayShown { playButton }
      Button {
        model.selectedText.map(copy)
      } label: {
        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
      }
      .disabled(model.selectedText == nil)
      .help("Copy \(readingName == "it" ? "the transcript" : readingName)")
      if let url = model.openEntry?.audioURL {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        .disabled(!FileManager.default.fileExists(atPath: url.path))
        .help("Show in Finder")
      }
    }
    // Delete in a group of its own, apart from the actions that keep the item.
    if let entry = model.openEntry {
      if #available(macOS 26, *) {
        ToolbarSpacer(.fixed)
      }
      ToolbarItem {
        Button {
          pendingDelete = entry
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .help("Delete…")
      }
    }
  }

  /// Plays what's showing — the entry's own audio on Full, anything else read
  /// aloud in the user's voice, speech made on the spot — behind one Play and
  /// Stop for both, with a spinner until spoken words start. The tooltip says
  /// which it is. Toolbar-sized, as its neighbours are.
  @ViewBuilder private var playButton: some View {
    let original = model.showsOriginalAudio
    let playing = model.isPlayingShown
    Button {
      model.togglePlayShown()
    } label: {
      Label {
        Text(model.isPreparingShown ? "Preparing…" : playing ? "Stop" : "Play")
      } icon: {
        // One slot for every state, so the toolbar never re-lays itself out
        // as the button changes, and the same play and stop for the entry's
        // audio and for speech, so a press reads as the button changing state.
        Group {
          if model.isPreparingShown {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: playing ? "stop.circle" : "play.circle")
          }
        }
        .frame(width: Self.playIconSize, height: Self.playIconSize)
      }
    }
    .help(original ? "Play the audio" : "Read \(readingName) aloud")
  }

  /// The play button's icon slot: wide enough for the widest of its glyphs.
  private static let playIconSize: CGFloat = 22

  /// What Listen reads, mid-sentence: "it" for the transcript, else the view.
  private var readingName: String {
    model.selection == .full ? "it" : model.selection.title.lowercased()
  }

  /// The selected facet's text area: the text, or its progress, or why it
  /// failed with a way to try again.
  @ViewBuilder
  private var facetContent: some View {
    let content = model.contents[model.selection]
    Group {
      switch content {
      case .ready(let text):
        // Inside the page's own scroll (`body`). A transcript's Full tab,
        // with speakers told apart, shows as coloured turns (parsed once,
        // `fullTurns`); everything else is prose, shown as it is.
        Group {
          if model.selection == .full, !model.fullTurns.isEmpty {
            SpeakerTurnsView(turns: model.fullTurns)
          } else {
            Text(text).textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    // In the page's scroll a transcript takes its own height; anything else
    // fills what's left of the window.
    .frame(maxHeight: model.selectedText == nil ? .infinity : nil)
  }

  private func copy(_ transcript: String) {
    NSPasteboard.copyAnnounced(transcript)
    copied = true
  }
}

/// The view over the transcript, as a toolbar menu under an AI icon — the
/// transcript itself (Full, and Plain text where it differs), then the stock
/// transforms, then Custom, which asks for its request in a popover. The
/// current view is checked here and named in the window's subtitle.
private struct TranscriptFacetMenu: View {
  var model: TranscriptsModel
  @State private var isEditingCustom = false
  @State private var customDraft = ""

  /// Custom is selected only once it has a request: choosing it without one
  /// asks first, and Cancel leaves the selection where it was.
  private var selection: Binding<TranscriptFacet> {
    Binding(
      get: { model.selection },
      set: { facet in
        if facet == .custom, model.customRequest.isEmpty {
          editCustom()
        } else {
          model.select(facet)
        }
      })
  }

  var body: some View {
    let facets = model.availableFacets
    Menu {
      Picker("View", selection: selection) {
        ForEach(facets.filter { $0 == .full || $0 == .plain }, id: \.self, content: item)
        Divider()
        ForEach(facets.filter { ![.full, .plain, .custom].contains($0) }, id: \.self, content: item)
        Divider()
        item(.custom)
      }
      .pickerStyle(.inline)
      // Re-choosing the selected item doesn't reach the binding, so a
      // request already applied is changed from here.
      if model.selection == .custom {
        Button("Edit Custom Request…", action: editCustom)
      }
    } label: {
      Label("View", systemImage: "sparkles")
    }
    .help("Show the transcript or a task on it")
    .accessibilityIdentifier(UITestIdentifiers.facetPicker)
    .popover(isPresented: $isEditingCustom, arrowEdge: .bottom) { customEditor }
  }

  /// One view in the menu. Custom reads "Custom…" until it has a request,
  /// since choosing it asks for one first.
  private func item(_ facet: TranscriptFacet) -> some View {
    let title = facet == .custom && model.customRequest.isEmpty ? "Custom…" : facet.title
    return Label(title, systemImage: facet.systemImage).tag(facet)
  }

  private func editCustom() {
    customDraft = model.customRequest
    isEditingCustom = true
  }

  /// Custom's request, asked for under the toolbar's View menu.
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
/// the page, spelled once.
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
  /// The page's read-only text area: the rest of its height, the text right
  /// on the window under the title, as a Journal entry's is — no box or edge.
  func textAreaSurface() -> some View {
    frame(maxHeight: .infinity)
  }
}
