import Accessibility
import BlurtEngine
import SwiftUI

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
    // Sections sit 20 pt apart; the logo and shortcut readout are one idea,
    // so they nest in a tighter 14 pt group rather than spreading to match.
    VStack(spacing: 20) {
      VStack(spacing: 14) {
        ReadyBrandingView()
          // The logo PNG carries ~16% transparent margin top & bottom. The top
          // margin gives welcome clearance from the traffic lights; cancel the
          // bottom one so the gap to the text is the VStack spacing, not ~2x it.
          .padding(.bottom, -16)

        shortcutReadout
      }

      RecentDictationsSection(entries: coordinator.recentDictations.entries)

      Button(action: openSettings) {
        Label("Settings", systemImage: "gearshape")
          .labelStyle(.titleAndIcon)
          .symbolRenderingMode(.hierarchical)
      }
      // The system Liquid Glass button — hover/press chrome, edge highlights,
      // and accessibility fallbacks come from the style, not hand-rolled fills.
      .buttonStyle(.glass)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 32)
    .padding(.top, 4)
    .padding(.bottom, 20)
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

  private static let rowHeight: CGFloat = 28
  private static let separatorThickness: CGFloat = 1
  /// Height of a full `capacity`-row list (rows + the separators between them);
  /// the container is pinned to this whether it holds 0, 1, or `capacity` rows.
  private var reservedHeight: CGFloat {
    let rows = CGFloat(RecentDictations.capacity) * Self.rowHeight
    let separators = CGFloat(RecentDictations.capacity - 1) * Self.separatorThickness
    return rows + separators
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
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
/// Copy follows the standard macOS list-row shape: on hover (or keyboard focus,
/// for Full Keyboard Access) a "Copy" button takes the timestamp's place; the
/// same command is in the row's contextual menu and a VoiceOver custom action,
/// so it's never reachable through hover alone. Copying briefly shows "Copied"
/// (and announces it), since a pasteboard write has no visible effect.
private struct RecentDictationRow: View {
  let entry: RecentDictations.Entry
  let now: Date

  @State private var isHovered = false
  @State private var showsCopyConfirmation = false
  /// Counts copies of this row; the confirmation-reset `.task(id:)` keys off
  /// it, so each copy cancels the running timer and starts a fresh one.
  @State private var copyCount = 0
  @FocusState private var copyButtonFocused: Bool

  /// The three things the trailing slot can show. Deriving the visible one
  /// from a single value keeps the exclusivity structural rather than spread
  /// across per-layer boolean conditions.
  private enum TrailingSlot { case timestamp, copyButton, copiedConfirmation }

  /// Keyboard focus counts as well as hover for revealing the copy button, so
  /// Full Keyboard Access users tabbing to the (otherwise invisible) button
  /// can see what they're on.
  private var trailingSlot: TrailingSlot {
    if showsCopyConfirmation { return .copiedConfirmation }
    if isHovered || copyButtonFocused { return .copyButton }
    return .timestamp
  }

  var body: some View {
    // Formatted once per render; feeds the trailing text and VoiceOver label.
    // The "just now"/relative-phrasing rule is the engine's (unit-tested there).
    let timestamp = entry.relativeLabel(now: now)
    HStack(spacing: 10) {
      Text(entry.text)
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      trailingAccessory(timestamp: timestamp)
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
    // One VoiceOver element per row; the explicit label controls the phrasing,
    // so ignore the children rather than merge. Copy is re-exposed as a custom
    // action since the hover button is ignored with the rest of the children.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(entry.text), \(timestamp)")
    .accessibilityAction(named: "Copy") { copyTranscript() }
    // Reverts the "Copied" confirmation after a beat. The cancelled-sleep guard
    // keeps a superseded timer from clearing the newer copy's confirmation.
    .task(id: copyCount) {
      guard copyCount > 0 else { return }
      guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
      showsCopyConfirmation = false
    }
  }

  /// The row's trailing slot: the relative timestamp, swapped for the "Copy"
  /// button on hover/focus and a transient "Copied" confirmation after a copy.
  /// All three are layered (faded, not swapped out of the hierarchy) so the
  /// button never loses keyboard focus mid-confirmation, and the slot sizes to
  /// the widest so nothing shifts as they trade places.
  private func trailingAccessory(timestamp: String) -> some View {
    ZStack(alignment: .trailing) {
      Text(timestamp)
        .opacity(trailingSlot == .timestamp ? 1 : 0)
      Button(action: copyTranscript) {
        // Hand-rolled label: `Label`'s default icon–title gap reads as two
        // separate items at this size; pull the glyph in tight.
        HStack(spacing: 3) {
          Image(systemName: "doc.on.doc")
          Text("Copy")
        }
      }
      .buttonStyle(RecentCopyButtonStyle())
      .focused($copyButtonFocused)
      .opacity(trailingSlot == .copyButton ? 1 : 0)
      // Opacity-0 views still hit-test; only take clicks while visible (this
      // gates pointer input without breaking keyboard focus/activation).
      .allowsHitTesting(trailingSlot == .copyButton)
      Label("Copied", systemImage: "checkmark")
        .opacity(trailingSlot == .copiedConfirmation ? 1 : 0)
        // Let clicks fall through rather than swallowing them while the
        // confirmation sits above the (hidden) copy button.
        .allowsHitTesting(false)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize()
    .animation(.easeOut(duration: 0.12), value: trailingSlot)
  }

  private func copyTranscript() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(entry.text, forType: .string)

    // The invisible pasteboard write gets audible + visible confirmation:
    AccessibilityNotification.Announcement("Copied").post()
    showsCopyConfirmation = true
    copyCount += 1
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

/// A single rounded key-cap, e.g. "⌃" or "D". A quiet semantic chip, not
/// Liquid Glass: over the ready window's flat background a glass chip has
/// nothing to refract and reads as bare floating text, and the HIG reserves
/// glass for the floating control layer rather than in-window content.
/// `.quinary` + `.separator` adapt to light/dark and Increase Contrast for
/// free, and match the Recent card's container fill above.
private struct KeyCap: View {
  var label: String

  var body: some View {
    Text(label)
      .font(.title3.weight(.medium).monospaced())
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.quinary)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(.separator, lineWidth: 1)
      )
  }
}

/// The Recent row's Copy control: accent-tinted (marking it clickable, vs. the
/// secondary timestamp it replaces) with an accent highlight on hover/press,
/// painted outside the layout bounds so the trailing alignment doesn't shift.
private struct RecentCopyButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    RecentCopyButton(configuration: configuration)
  }
}

private struct RecentCopyButton: View {
  let configuration: ButtonStyleConfiguration
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .foregroundStyle(Color.accentColor)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.accentColor.opacity(highlightOpacity))
          .padding(.horizontal, -5)
          .padding(.vertical, -3)
      }
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .onHover { isHovered = $0 }
  }

  private var highlightOpacity: Double {
    configuration.isPressed ? 0.2 : isHovered ? 0.12 : 0
  }
}
