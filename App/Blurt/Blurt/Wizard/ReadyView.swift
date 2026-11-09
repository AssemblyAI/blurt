import BlurtEngine
import SwiftUI

/// The main window once setup is complete, shaped like a dictation app's home:
/// Blurt's real work happens outside it, on the keys, so the keys lead — each
/// configured key and what it does, and the style in effect — over a feed of
/// what Blurt has done (the Library). Recording and file import, the one
/// thing done from the window itself, are toolbar buttons beside the Filter
/// menu, Settings and the search.
///
/// A grouped `Form`, the same surface the Settings window's panes use, rather
/// than hand-drawn cards: one inset-grouped style for every container means
/// one set of fills, radii and separators — the system's, which also carry
/// dark mode, Increase Contrast and vibrancy — instead of several custom greys
/// that each nearly matched.
struct ReadyView: View {
  var coordinator: AppCoordinator
  @Environment(\.openSettings) private var openSettings
  // Observed (not read once) so a change in the separate Settings window —
  // the dictation key, any key's action or mode — re-renders this window's
  // rows live (`ObservedKeyBindings`).
  @ObservedKeyBindings private var bindings
  /// The key that dictates, or nil when the Keys tab set every one to None.
  private var triggerKey: TriggerKey? { bindings.dictationKey }
  /// The dictation key's tap/hold mode, which the rows' tooltips and the
  /// Library's first-run prompt follow.
  private var activation: TriggerActivation { bindings.activation }

  /// Kept as view state because Settings is a separate scene: its defaults
  /// write can otherwise leave this already-open window displaying the old
  /// pop-up until relaunch. The store posts an explicit change notification
  /// after each list write, and this window reloads through the store so its
  /// decoding and normalization rules remain the single source of truth.
  @State private var profiles = StyleProfileStore().profiles
  /// The toolbar's Filter menu: everything, or one kind of entry.
  @State private var filter = LibraryFilter.all
  /// The toolbar's search, and whether the cursor is in it (⌘F).
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  /// The toolbar's Browse open panel.
  @State private var isImporting = false
  @AppStorage(StyleProfileStore.activeDefaultsKey) private var rawActiveID = ""

  /// The one page the window pushes: whatever the model has open.
  private enum Route: Hashable { case openItem }

  /// The navigation path, bound to the model: a page while it has something
  /// open — an item, a recording, a file going up, which open themselves as
  /// often as a click opens them — and none when it's idle. Popping (back,
  /// or Esc) lets go of it, abandoning a file going up.
  private var path: Binding<[Route]> {
    Binding(
      get: { coordinator.transcripts.state == .idle ? [] : [.openItem] },
      set: { if $0.isEmpty { coordinator.transcripts.dismiss() } })
  }

  var body: some View {
    // The system's push and back, as Journal's entries open.
    NavigationStack(path: path) {
      home
        .frame(minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: .infinity)
        .toolbar { toolbarItems }
        // The system's search: its own capsule at the toolbar's trailing
        // edge, widening when clicked into, as Finder's and Mail's do.
        .searchable(text: $query, placement: .toolbar, prompt: "Search Blurt")
        .searchFocused($searchFocused)
        // Not the field a window opens in: focused, it widens and pushes
        // Filter and Settings behind a » menu. Click or ⌘F puts it there.
        .defaultFocus($searchFocused, false)
        .task { searchFocused = false }
        // A click anywhere in the window's content lets go of the search, as
        // clicking off a field does. Alongside, not instead of, what the
        // click does — a card still opens, a menu still drops.
        .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        .navigationDestination(for: Route.self) { _ in
          TranscriptPage(model: coordinator.transcripts)
            .frame(minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: .infinity)
            // A recording holds the page until it's stopped or discarded.
            .navigationBarBackButtonHidden(coordinator.transcripts.isRecordingBusy)
        }
    }
    .frame(width: MainWindow.contentWidth)
    // No rule under the toolbar: the window reads as one surface, the
    // backdrop running up behind the toolbar as Journal's does.
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    // No title beside the search: it left the field no room to grow when
    // focused, and the toolbar overflowed into a » menu. An open item names
    // itself in its own toolbar. The window keeps its title for the Window
    // menu, Mission Control and accessibility.
    .toolbar(removing: .title)
    // Drop an audio or video file anywhere on the window to transcribe it.
    .audioFileDropTarget(coordinator.transcripts)
    // Edit › Find (⌘F), for this window: nothing to search before a first
    // entry.
    .focusedSceneValue(
      \.focusHistorySearch, coordinator.transcripts.history.isEmpty ? nil : { searchFocused = true }
    )
    // File › Open… (⌘O), for this window: Browse's panel. Not over a
    // recording, which `transcribe(_:)` refuses.
    .focusedSceneValue(\.importAudioFile, coordinator.transcripts.isRecordingBusy ? nil : { isImporting = true })
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audiovisualContent]) { result in
      if case .success(let url) = result { coordinator.transcripts.transcribe(url) }
    }
    // Esc cancels the in-flight dictation — same command the overlay's owner
    // submits (`.cancel`), scoped to this window by living on a button in it.
    // Present through all of capture (not just `.recording`), so Esc during
    // the mic bring-up also cancels rather than beeping.
    .background {
      if coordinator.isCapturing {
        Button("Cancel Dictation") { coordinator.session.submit(.cancel) }
          .keyboardShortcut(.cancelAction)
          .hidden()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: StyleProfileStore.profilesDidChangeNotification)
    ) { _ in
      profiles = StyleProfileStore().profiles
    }
  }

  /// The window's height: free between these, as its content scrolls; an
  /// open item takes the same, so the window doesn't jump as it comes and goes.
  private static let minHeight: CGFloat = 420
  private static let idealHeight: CGFloat = 640

  /// The keys over the Library, as white cards on the brand gradient: what
  /// the window shows with nothing open.
  @ViewBuilder private var home: some View {
    // Decoded and resolved once per render: `body` re-runs on every dictation
    // (the Library is live), and both answers cost a JSON decode. Which
    // style is active is the engine's rule — the stored pointer, `nil` for the
    // Default sentinel, or the first profile when it names nothing — never a
    // second reading here.
    let active = StyleProfileStore.active(in: profiles, id: rawActiveID)
    // One list for the whole window: the keys lead it and scroll away with
    // the Library under them, and its scroller is the window's own.
    LibrarySection(
      coordinator: coordinator, triggerKey: triggerKey, activation: activation, query: query, filter: filter
    ) {
      // What you can press — Blurt's real work happens outside this window,
      // on these keys. A legend under a Keys heading, not a white card: only the
      // Library's entries are cards, and the keys are drawn as keycaps, to
      // press rather than click. Once a custom style exists, the writing
      // style the dictation keys use closes the group.
      VStack(alignment: .leading, spacing: 0) {
        Text("Keys")
          .font(.headline)
          .padding(.leading, 4)
          .padding(.bottom, 4)
          .accessibilityAddTraits(.isHeader)
        // A soft, translucent panel — rounded like the cards but flat and
        // see-through, so it reads as a legend rather than another card to
        // click.
        VStack(alignment: .leading, spacing: 0) {
          shortcutRow.keyRow()
          // Every other key given an action in the Keys tab, in its order,
          // each under a faint hairline across the row, pairing each action
          // with its key.
          ForEach(bindings.extraKeys, id: \.self) { key in
            KeyDivider()
            extraKeyRow(key, profiles: profiles).keyRow()
          }
        }
        .padding(.vertical, 6)
        .background(
          Color(nsColor: .textBackgroundColor).opacity(0.55),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Only once there is a custom style: with none, every dictation is
        // Default and the row would offer no choice. Never locked during a
        // dictation: each one's style is fixed as its key goes down
        // (`PressStyle`), so a pick mid-utterance applies to the next.
        if !profiles.isEmpty {
          StyleRow(profiles: profiles, activeID: active?.id)
            .keyRow()
          // The caveat is about styles, so it goes with the row.
          StylesInertNotice()
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        }
      }
    }
    .background(BlurtBrand.backdrop.ignoresSafeArea())
  }

  /// The dictation shortcut as a form row: "Dictate" leading, the bound key
  /// trailing, and how its gesture works in the tooltip. Still while a key is
  /// down: how a dictation is going is the pill's to say, not the window's.
  /// With no key dictating it stays, with a button to Settings in place of
  /// the keycap, so the panel says dictation is off and how to turn it back
  /// on rather than quietly losing a row.
  @ViewBuilder private var shortcutRow: some View {
    if let triggerKey {
      SettingRow(title: "Dictate", systemImage: TriggerKeyAction.dictate.systemImage) {
        KeyCap(label: triggerKey.spokenName)
      }
      .help(activation.hint(for: .dictate))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Dictate: \(triggerKey.spokenName). \(activation.hint(for: .dictate))")
    } else {
      SettingRow(title: "Dictate", systemImage: TriggerKeyAction.dictate.systemImage) {
        Button("Choose Key…") { openSettings() }
          .buttonStyle(.link)
          .help("Choose a key in Settings › Keys.")
          .accessibilityLabel("Choose a dictation key")
          .accessibilityHint("Opens Settings. Choose a key for Dictate in the Keys tab.")
      }
      // Contained, not ignored: the button has to stay reachable.
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Dictate: None")
    }
  }

  /// One extra key's row: what it does — with the style a dictating key uses
  /// when it isn't the main window's — leading, its keycap trailing, and how
  /// its gesture works in the tooltip.
  private func extraKeyRow(_ key: TriggerKey, profiles: [StyleProfile]) -> some View {
    let choice = bindings.choice(for: key, profiles: profiles)
    let title: String =
      switch choice {
      case .readAloud: LibraryKind.readAloud.name
      case .ask: LibraryKind.ask.name
      case .rewrite: KeyActionName.rewrite
      case .compose: KeyActionName.compose
      case .command: KeyActionName.command
      case .dictate(TriggerKeyChoice.mainWindowStyle), .off: "Dictate"
      case .dictate(let style):
        "Dictate: \(StyleProfileStore.active(in: profiles, id: style)?.name ?? StyleProfileStore.defaultStyleName)"
      }
    let symbol = choice.action.systemImage
    let hint = bindings.activation.hint(for: choice.action)
    return SettingRow(title: title, systemImage: symbol) {
      KeyCap(label: key.spokenName)
    }
    .help(hint)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(key.spokenName). \(hint)")
  }

  /// The toolbar: Record and Browse leading, as a window's own actions are;
  /// beside the search, the Library's Filter menu and Settings.
  @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
    let model = coordinator.transcripts
    ToolbarItemGroup(placement: .navigation) {
      Button {
        model.startRecording()
      } label: {
        Label("Record", systemImage: "record.circle")
      }
      // Disabled while anything else has the transcript sheet; a running
      // recording's Stop lives in that sheet.
      .disabled(!model.canRecord)
      .help(
        model.canRecord
          ? "Record your microphone and your Mac's audio together, transcribed live"
          : "Available when the current transcription finishes"
      )
      .accessibilityIdentifier(UITestIdentifiers.transcribeRecordButton)
      Button {
        isImporting = true
      } label: {
        Label("Browse", systemImage: "folder")
      }
      // `transcribe(_:)` refuses while a recording is busy, so the button
      // says so rather than opening a panel that does nothing.
      .disabled(model.isRecordingBusy)
      .help("Choose an audio or video file to transcribe")
      .accessibilityIdentifier(UITestIdentifiers.transcribeBrowseButton)
    }
    ToolbarItem {
      // Mail's Filter button: one kind of entry, or all of them. The icon
      // fills while a filter is on, so a shortened list never looks complete.
      Menu {
        Picker("Show", selection: $filter) {
          ForEach(LibraryFilter.allCases, id: \.self) { kind in
            Label(kind.title, systemImage: kind.systemImage).tag(kind)
          }
        }
        .pickerStyle(.inline)
      } label: {
        Label(
          "Filter",
          systemImage: filter == .all
            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
      }
      .help(filter == .all ? "Show one kind of entry" : "Showing \(filter.title.lowercased())")
      .accessibilityIdentifier(UITestIdentifiers.libraryFilterMenu)
    }
    ToolbarItem {
      Button {
        openSettings()
      } label: {
        Label("Settings", systemImage: "slider.horizontal.3")
      }
      .help("Settings")
    }
    // The search in a group of its own, apart from Settings.
    if #available(macOS 26, *) {
      ToolbarSpacer(.fixed)
    }
  }
}

/// The app's outbound links, in the Help menu (`BlurtCommands`). Failable
/// construction throughout, so a caller omits its link rather than
/// force-unwrapping.
enum BlurtLinks {
  /// The repo's GitHub issues.
  static let reportBug = URL(string: "https://github.com/AssemblyAI/blurt/issues")

  /// LinkedIn's share intent. It takes only a URL to share, so this one
  /// carries no message.
  static let shareOnLinkedIn: URL? = {
    var components = URLComponents(string: "https://www.linkedin.com/sharing/share-offsite/")
    components?.queryItems = [URLQueryItem(name: "url", value: "https://www.assemblyai.com/blurt")]
    return components?.url
  }()
}

/// The `blurt` wordmark over the setup screen's form (`WizardView`; the ready
/// screen goes without, its toolbar holding the search): the brand-green mark
/// (`Design/brand/blurt-ready-logo.png`, a 720×180 rasterization of the design's
/// vector wordmark, so its 72×18 pt slot is fed nearly 7× the pixels it needs and
/// stays crisp at any display scale). Smoothly interpolated — it's curved
/// letterforms now, not the pixel-art mark it replaced, which needed
/// nearest-neighbor to keep its pixels square. A header mark, not the window's
/// identity — the standard titlebar names the app — which is why it simply
/// omits itself if the PNG can't load rather than swapping in a fallback
/// identity view.
struct MainWindowBranding: View {
  /// Loaded once for the process rather than per `body` evaluation: a bundle
  /// lookup plus a PNG decode is not something to re-do on the main thread
  /// each time the setup screen re-renders.
  ///
  /// Left to the target's `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` default
  /// rather than spelled `nonisolated(unsafe)`: `body` reads it on the main actor
  /// either way, and this can't then break if a future SDK marks `NSImage`
  /// `Sendable` (which would make the attribute an "unnecessary" warning, and the
  /// app target builds with warnings-as-errors).
  private static let logo: NSImage? = Bundle.main
    .url(forResource: "blurt-ready-logo", withExtension: "png")
    .flatMap(NSImage.init(contentsOf:))

  var body: some View {
    if let image = Self.logo {
      Image(nsImage: image)
        // Drawn as a template tinted with the accent rather than shipped in its
        // own color. The design draws the wordmark in two shades — `#01762F` on
        // light, `#67AD82` on dark (its `Logo_Dark` / `Logo_Light` pair) — and
        // those are precisely the accent's two appearances, so tinting gets the
        // dark-mode variant for free from one asset. A fixed-color PNG kept the
        // dark green on a dark window, where it goes muddy. It also means the
        // mark and the accent-filled buttons beside it can't drift apart: they
        // now resolve the same color, rather than agreeing by coincidence.
        .renderingMode(.template)
        .interpolation(.high)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 64)
        .foregroundStyle(BlurtBrand.accent)
        .accessibilityLabel("Blurt logo")
    }
  }
}

extension View {
  /// A key legend row's padding: room for the hairline between rows.
  fileprivate func keyRow() -> some View {
    padding(.horizontal, 10).padding(.vertical, 6)
  }
}

/// The hairline between key rows: the separator colour, faint on the pale
/// panel, across the whole row — icon and all — inset as the rows are.
private struct KeyDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor).opacity(0.6))
      .frame(height: 0.5)
      .padding(.horizontal, 10)
      .accessibilityHidden(true)
  }
}
