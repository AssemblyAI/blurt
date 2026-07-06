import Accessibility
import BlurtEngine
import SwiftUI

private enum ReadyBrandPalette {
  static func keycapFill(for colorScheme: ColorScheme) -> Color {
    switch colorScheme {
    case .dark:
      return Color(red: 0.12, green: 0.16, blue: 0.2)
    default:
      return Color(red: 0.965, green: 0.985, blue: 1.0)
    }
  }

  static func keycapStroke(for colorScheme: ColorScheme) -> Color {
    switch colorScheme {
    case .dark:
      return Color(red: 0.38, green: 0.82, blue: 0.96).opacity(0.85)
    default:
      return Color(red: 0.42, green: 0.82, blue: 0.95).opacity(0.4)
    }
  }

  static func settingsButtonFill(for colorScheme: ColorScheme, isHovered: Bool, isPressed: Bool) -> Color {
    guard isHovered || isPressed else { return .clear }

    let opacity = isPressed ? 0.11 : 0.06
    switch colorScheme {
    case .dark:
      return Color.white.opacity(opacity)
    default:
      return Color.black.opacity(opacity)
    }
  }
}

/// The "you're all set" screen shown in the main window once setup is complete.
/// It just states the dictation shortcut and offers a native-feeling link to the
/// Settings window — there's nothing to configure here.
struct ReadyView: View {
  var coordinator: AppCoordinator
  var openSettings: () -> Void
  // Observe the persisted trigger keycode directly so changing the dictation key
  // in the (separate) Settings window re-renders this window's keycap live.
  // `@AppStorage` reflects writes to the same default across windows; reading
  // `TriggerKeyStore` (plain UserDefaults) would not trigger a re-render.
  @AppStorage(TriggerKeyStore.defaultsKey) private var triggerKeyCode: Int =
    TriggerKey.rightCommand.rawValue

  var body: some View {
    VStack(spacing: 18) {
      ReadyBrandingView()
        // The logo PNG carries ~16% transparent margin top & bottom. The top
        // margin gives welcome clearance from the traffic lights; cancel the
        // bottom one so the gap to the text is the VStack spacing, not ~2x it.
        .padding(.bottom, -16)

      shortcutReadout

      RecentDictationsSection(entries: coordinator.recentDictations.entries)

      Button(action: openSettings) {
        Label("Settings", systemImage: "gearshape")
      }
      .buttonStyle(ReadySettingsButtonStyle())
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 32)
    .padding(.top, 4)
    .padding(.bottom, 26)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// "Tap or hold ⌘ to blurt", with the key drawn as a rounded keycap.
  private var shortcutReadout: some View {
    HStack(spacing: 6) {
      Text("Tap or hold")
        .foregroundStyle(.secondary)
      KeyCap(label: TriggerKey.fromPersisted(triggerKeyCode).label)
      Text("to blurt")
        .foregroundStyle(.secondary)
    }
    .font(.title3)
  }
}

/// The "Recent" list under the shortcut readout: the last few dictations, newest
/// first, each a single truncated line with a live relative timestamp. The list
/// area reserves a fixed height for `RecentDictations.capacity` rows so the
/// window never resizes and nothing above it moves as dictations arrive; unused
/// slots are held open (empty → a muted placeholder fills the whole area).
private struct RecentDictationsSection: View {
  let entries: [RecentDictations.Entry]

  private static let rowHeight: CGFloat = 30
  private static let separatorThickness: CGFloat = 1
  /// Height of a full `capacity`-row list (rows + the separators between them);
  /// the container is pinned to this whether it holds 0, 1, or `capacity` rows.
  private var reservedHeight: CGFloat {
    let rows = CGFloat(RecentDictations.capacity) * Self.rowHeight
    let separators = CGFloat(RecentDictations.capacity - 1) * Self.separatorThickness
    return rows + separators
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recent")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)

      listBody
        .frame(height: reservedHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quinary)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  @ViewBuilder
  private var listBody: some View {
    if entries.isEmpty {
      Text("Your recent blurts will appear here")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      // Live relative timestamps ("2 minutes ago") without a stored clock: the
      // TimelineView re-renders on a coarse cadence and each row formats against
      // its current date. 30 s is fine — the smallest unit shown is minutes.
      TimelineView(.periodic(from: .now, by: 30)) { timeline in
        VStack(spacing: 0) {
          ForEach(entries) { entry in
            RecentDictationRow(entry: entry, now: timeline.date)
              .frame(height: Self.rowHeight)
            if entry.id != entries.last?.id {
              // Semantic separator (adapts to light/dark + Increase Contrast),
              // full-bleed across the grouped container — the rows carry no
              // leading icon to inset past, so an edge-to-edge rule reads cleaner.
              Divider()
            }
          }
        }
      }
    }
  }
}

/// A single recent-dictation row: the transcript (one truncated line) with a
/// relative timestamp trailing it, formatted against `now` (supplied by the
/// enclosing `TimelineView` so it advances over time), and a copy affordance.
///
/// Copy follows the standard macOS list-row shape: on hover (or keyboard
/// focus, for Full Keyboard Access) a borderless "Copy" button takes the
/// timestamp's place at the trailing edge; the same command is in the row's
/// contextual menu and a VoiceOver custom action, so it's never reachable
/// through hover alone. Copying briefly swaps the button for a "Copied"
/// confirmation — and posts it as an accessibility announcement — since
/// putting text on the pasteboard has no visible effect of its own.
private struct RecentDictationRow: View {
  let entry: RecentDictations.Entry
  let now: Date

  @State private var isHovered = false
  @State private var showsCopyConfirmation = false
  @State private var copyConfirmationReset: Task<Void, Never>?
  @FocusState private var copyButtonFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Text(entry.text)
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      trailingAccessory
    }
    .padding(.horizontal, 12)
    .frame(maxHeight: .infinity)
    // Hover tooltip with the full transcript, so a pointer user can read what
    // the single truncated line cuts off (VoiceOver already gets it via the
    // label below).
    .help(entry.text)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Copy") { copyTranscript() }
    }
    // One VoiceOver element per row; the explicit label controls the phrasing
    // (transcript then relative time), so ignore the children rather than merge.
    // Copy is re-exposed as a custom action since the hover button is ignored
    // with the rest of the children.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(entry.text), \(relativeTimestamp)")
    .accessibilityAction(named: "Copy") { copyTranscript() }
  }

  /// Whether the trailing slot currently shows the copy button instead of the
  /// timestamp. Keyboard focus counts as well as hover, so Full Keyboard Access
  /// users tabbing to the (otherwise invisible) button can see what they're on.
  private var showsCopyButton: Bool {
    (isHovered || copyButtonFocused) && !showsCopyConfirmation
  }

  /// The row's trailing slot: normally the relative timestamp, swapped for the
  /// "Copy" button on hover/focus, and for a transient "Copied" confirmation
  /// right after a copy. All three are layered (faded, not swapped out of the
  /// hierarchy) so the button never loses keyboard focus mid-confirmation, and
  /// the slot sizes to the widest so nothing shifts as they trade places.
  private var trailingAccessory: some View {
    ZStack(alignment: .trailing) {
      Text(relativeTimestamp)
        .opacity(showsCopyButton || showsCopyConfirmation ? 0 : 1)
      Button(action: copyTranscript) {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .buttonStyle(.borderless)
      .focused($copyButtonFocused)
      .opacity(showsCopyButton ? 1 : 0)
      .help("Copy")
      Label("Copied", systemImage: "checkmark")
        .opacity(showsCopyConfirmation ? 1 : 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize()
    .animation(.easeOut(duration: 0.12), value: showsCopyButton)
    .animation(.easeOut(duration: 0.12), value: showsCopyConfirmation)
  }

  private func copyTranscript() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(entry.text, forType: .string)

    // The pasteboard write is invisible, so confirm it: VoiceOver hears it...
    AccessibilityNotification.Announcement("Copied").post()

    // ...and sighted users see "Copied" for a beat before the slot reverts.
    // Rapid re-copies restart the clock instead of racing the earlier reset.
    copyConfirmationReset?.cancel()
    showsCopyConfirmation = true
    copyConfirmationReset = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      showsCopyConfirmation = false
    }
  }

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full  // e.g. "2 minutes ago"
    return formatter
  }()

  /// "just now" for the first minute (the formatter's bare "in 0 seconds" reads
  /// oddly for a dictation that just landed), then the relative phrasing.
  private var relativeTimestamp: String {
    if now.timeIntervalSince(entry.timestamp) < 60 {
      return "just now"
    }
    return Self.relativeFormatter.localizedString(for: entry.timestamp, relativeTo: now)
  }
}

private struct ReadyBrandingView: View {
  var body: some View {
    if let brandingURL,
      let image = NSImage(contentsOf: brandingURL)
    {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: 280)
        .accessibilityLabel("Blurt logo")
    } else {
      // Fallback if the bundled logo can't be loaded — keep the ready screen's
      // identity (icon + name) rather than rendering an empty, contextless view.
      VStack(spacing: 8) {
        Image(systemName: "mic.fill")
          .font(.system(size: 44))
          .foregroundStyle(.secondary)
        Text("Blurt is ready")
          .font(.title2.weight(.semibold))
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Blurt is ready")
    }
  }

  private var brandingURL: URL? {
    Bundle.main.url(forResource: "blurt-ready-logo", withExtension: "png")
  }
}

/// A single rounded key-cap, e.g. "⌃" or "D".
private struct KeyCap: View {
  var label: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text(label)
      .font(.title3.weight(.medium).monospaced())
      .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(ReadyBrandPalette.keycapFill(for: colorScheme))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(ReadyBrandPalette.keycapStroke(for: colorScheme), lineWidth: 1)
      )
  }
}

private struct ReadySettingsButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    ReadySettingsButton(configuration: configuration)
  }
}

private struct ReadySettingsButton: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .font(.subheadline.weight(.medium))
      .labelStyle(.titleAndIcon)
      .symbolRenderingMode(.hierarchical)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            ReadyBrandPalette.settingsButtonFill(
              for: colorScheme,
              isHovered: isHovered,
              isPressed: configuration.isPressed
            )
          )
      )
      .foregroundStyle(.secondary)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .onHover { isHovered = $0 }
  }
}
