import Accessibility
import BlurtEngine
import SwiftUI

/// The "Recent" section of the ready screen's grouped form: the last few
/// dictations, newest first, one form row apiece — a truncated transcript
/// line with the style and a live relative time as plain secondary text on
/// the trailing edge, the way System Settings and Mail show a row's details.
/// Real form rows, so the separators, insets and type size are the form's own
/// and match the Shortcut and Style rows above.
///
/// The section holds its height as dictations arrive, so the window never
/// resizes: every row's content is pinned to `rowHeight`, and the empty state
/// (the first-dictation prompt) is one row pinned to the height of a full
/// list — `displayCapacity` rows plus the form's spacing between them.
struct RecentDictationsSection: View {
  let entries: [RecentDictations.Entry]
  /// The bound key, for the empty state's instruction — drawn as the same
  /// keycap the shortcut row above uses, so the two name one key one way.
  let triggerKey: TriggerKey
  /// How that key is configured to start a dictation, so the instruction
  /// says "tap" or "hold" to match.
  let activation: TriggerActivation

  /// Content height of one row: a line of body text, with the hover Copy
  /// swap happening inside the trailing slot so revealing it never changes
  /// the row height.
  private static let rowHeight: CGFloat = 22
  /// What the grouped form adds between two rows' content — its vertical row
  /// padding and the separator. Measured off a build (a filled list against
  /// the empty state at the same window height) rather than derived: the
  /// form doesn't publish it.
  private static let interRowSpacing: CGFloat = 21

  /// How often the relative timestamps re-render. Half the engine's "just now"
  /// window, so a row can't read as stale for longer than that window lasts —
  /// derived from the threshold rather than a bare `30` in case it changes.
  private static let timestampRefresh = RecentDictations.Entry.justNowThreshold / 2

  /// Content height of the empty state's single row: a full list's worth of
  /// rows and the spacing between them, so the prompt row and a filled list
  /// stand the same height. The row-count arithmetic is the engine's, next to
  /// the `displayCapacity` it depends on.
  private var emptyStateHeight: CGFloat {
    RecentDictations.reservedHeight(
      rowHeight: Self.rowHeight, rowSpacing: Self.interRowSpacing)
  }

  var body: some View {
    Section("Recent") {
      if entries.isEmpty {
        emptyPrompt
          .frame(maxWidth: .infinity)
          .frame(height: emptyStateHeight)
      } else {
        // Live relative timestamps ("2 minutes ago") without a stored clock:
        // the TimelineView re-renders on a coarse cadence (`timestampRefresh`)
        // and each row formats against its current date. One per row, so each
        // stays a direct child of the section and the form draws it as a row.
        ForEach(entries) { entry in
          TimelineView(.periodic(from: .now, by: Self.timestampRefresh)) { timeline in
            RecentDictationRow(entry: entry, now: timeline.date)
              .frame(height: Self.rowHeight)
          }
        }
        // Blank rows hold the slots a short list hasn't filled, so the
        // section is a full list's height from the first dictation on.
        ForEach(entries.count..<RecentDictations.displayCapacity, id: \.self) { _ in
          Color.clear
            .frame(height: Self.rowHeight)
            .accessibilityHidden(true)
        }
      }
    }
  }

  /// The empty list as the first-run prompt rather than a placeholder that
  /// only says nothing has happened yet: it names the one thing to try, in the
  /// order the user does it.
  private var emptyPrompt: some View {
    VStack(spacing: 4) {
      // Two lines, broken after the keycap: on one the sentence runs past
      // the row's width.
      HStack(spacing: 4) {
        Text("Click into any text field, \(activation.startVerb)")
        KeyCap(label: triggerKey.keycapLabel)
      }
      Text("and say “Hello from Blurt.”")
    }
    .foregroundStyle(.secondary)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Click into any text field, \(activation.startVerb) \(triggerKey.spokenName), and say “Hello from Blurt.”"
    )
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier(UITestIdentifiers.recentEmptyPrompt)
  }
}

/// A single recent-dictation row: the transcript (one truncated line) with a
/// secondary trailing slot — the name of the style the dictation was made with
/// (omitted for the base Default styling, see `Entry.style`), then the
/// relative time (`Entry.relativeLabel` against `now`, which the enclosing
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
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      trailingAccessory
    }
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
    // Body size, secondary colour: a form row's trailing value is the same
    // size as its label, set apart by colour alone.
    .foregroundStyle(.secondary)
    .fixedSize()
    .animation(.easeOut(duration: 0.12), value: trailingSlot)
  }

  /// The slot's resting face: the style name, then the relative time, as one
  /// run of secondary text ("Slack · just now") — the way a macOS list shows a
  /// row's details, rather than a tag-like chip. Default-styled rows carry no
  /// style — the base treatment is every row's default, so naming it would be
  /// noise (the same rule as `Entry.style`). The time's wording — "just now",
  /// then the system's relative phrasing — is the engine's (unit-tested there).
  private var styleAndTime: some View {
    Text([entry.style, entry.relativeLabel(now: now)].compactMap { $0 }.joined(separator: " · "))
      .lineLimit(1)
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
      .foregroundStyle(BlurtBrand.accent)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(BlurtBrand.accent.opacity(highlightOpacity))
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
