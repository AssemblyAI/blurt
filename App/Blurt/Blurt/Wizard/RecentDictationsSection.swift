import Accessibility
import BlurtEngine
import SwiftUI

/// The "Recent" list under the shortcut readout: the last few dictations, newest
/// first, each a truncated transcript line with the style chip and a live
/// relative time on the trailing edge. The list
/// area reserves a fixed height for `RecentDictations.displayCapacity` rows so the
/// window never resizes and nothing above it moves as dictations arrive; unused
/// slots are held open (empty → a muted placeholder fills the whole area).
struct RecentDictationsSection: View {
  let entries: [RecentDictations.Entry]

  /// One transcript line beside the trailing style-chip/time slot. Back to the
  /// single-line era's 28 — macOS-list density — now that the subtitle line is
  /// gone; the hover Copy swap happens inside this same slot, so revealing it
  /// never changes the row height. The reservation math in
  /// `RecentDictations.reservedHeight` is unchanged; only this input moves.
  private static let rowHeight: CGFloat = 28
  private static let separatorThickness: CGFloat = 1

  /// How often the relative timestamps re-render. Half the engine's "just now"
  /// window, so a row can't read as stale for longer than that window lasts —
  /// derived from the threshold rather than a bare `30` in case it changes.
  private static let timestampRefresh = RecentDictations.Entry.justNowThreshold / 2
  /// Height of a full `displayCapacity`-row list; the container is pinned to this
  /// whether it holds 0, 1, or `displayCapacity` rows. The row-count arithmetic is
  /// the engine's, next to the `displayCapacity` it depends on — which is the
  /// *displayed* count, not the much deeper `capacity` the ring remembers.
  private var reservedHeight: CGFloat {
    RecentDictations.reservedHeight(
      rowHeight: Self.rowHeight, separatorThickness: Self.separatorThickness)
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
      // TimelineView re-renders on a coarse cadence (`timestampRefresh`) and each
      // row formats against its current date.
      TimelineView(.periodic(from: .now, by: Self.timestampRefresh)) { timeline in
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
/// gray trailing slot — a small rounded chip naming the style the dictation was
/// made with (omitted for the base Default styling, see `Entry.style`), then
/// the relative time (`Entry.relativeLabel` against `now`, which the enclosing
/// `TimelineView` advances) — and a copy affordance.
///
/// Copy follows the standard macOS list-row shape: on hover (or keyboard focus,
/// for Full Keyboard Access) a "Copy" button replaces the chip and time in the
/// same trailing slot; the same command is in the row's contextual menu and a
/// VoiceOver custom action,
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

  /// The things the trailing slot can show — the style chip and time at rest,
  /// swapped for the copy affordance under the pointer. Deriving the visible
  /// one from a single value keeps the exclusivity structural rather than
  /// spread across per-layer boolean conditions.
  private enum TrailingSlot { case styleAndTime, copyButton, copiedConfirmation }

  /// Keyboard focus counts as well as hover for revealing the copy button, so
  /// Full Keyboard Access users tabbing to the (otherwise invisible) button
  /// can see what they're on.
  private var trailingSlot: TrailingSlot {
    if showsCopyConfirmation { return .copiedConfirmation }
    if isHovered || copyButtonFocused { return .copyButton }
    return .styleAndTime
  }

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
    // One VoiceOver element per row; the explicit label controls the phrasing,
    // so ignore the children rather than merge. Copy is re-exposed as a custom
    // action since the hover button is ignored with the rest of the children.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(voiceOverLabel)
    .accessibilityAction(named: "Copy") { copyTranscript() }
    // Reverts the "Copied" confirmation after a beat. The cancelled-sleep guard
    // keeps a superseded timer from clearing the newer copy's confirmation.
    .task(id: copyCount) {
      guard copyCount > 0 else { return }
      guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
      showsCopyConfirmation = false
    }
  }

  /// The row's trailing slot: the style chip and relative time at rest, the
  /// "Copy" button on hover/focus, and a transient "Copied" confirmation after
  /// a copy. The layers are faded,
  /// not swapped out of the hierarchy, so the button never loses keyboard focus
  /// mid-confirmation, and the slot sizes to the widest so nothing shifts as
  /// they trade places.
  private var trailingAccessory: some View {
    ZStack(alignment: .trailing) {
      styleAndTime
        .opacity(trailingSlot == .styleAndTime ? 1 : 0)
        // Passive text: let clicks fall through to the row (contextual menu)
        // rather than swallowing them at rest.
        .allowsHitTesting(false)
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

  /// The slot's resting face: a small gray rounded chip naming the style, then
  /// the relative time beside it. Default-styled rows carry no chip — the base
  /// treatment is every row's default, so naming it would be noise (the same
  /// rule as `Entry.style`). The time's wording — "just now", then the system's
  /// relative phrasing — is the engine's (unit-tested there).
  private var styleAndTime: some View {
    HStack(spacing: 6) {
      if let style = entry.style {
        Text(style)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(.quaternary))
          .lineLimit(1)
      }
      Text(entry.relativeLabel(now: now))
        .lineLimit(1)
    }
  }

  /// The row's one VoiceOver phrase: transcript, style (when the entry has
  /// one), relative time — the same pieces the row draws, joined with commas.
  private var voiceOverLabel: String {
    var parts = [entry.text]
    if let style = entry.style { parts.append(style) }
    parts.append(entry.relativeLabel(now: now))
    return parts.joined(separator: ", ")
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
