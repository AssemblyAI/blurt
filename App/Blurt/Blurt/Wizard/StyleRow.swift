import AppKit
import BlurtEngine
import SwiftUI

/// The style switcher: a labelled pop-up in the same warm card as the Recent
/// list below it, so the window's two in-content surfaces match. **Default** is
/// the base styling (no profile instructions appended) and the rest of the menu
/// is the user's profiles; a divider then separates the one item that isn't a
/// style at all, **Edit Styles…**, which opens Settings deep-linked to the
/// Advanced pane where profiles are created and edited (see
/// `SettingsWindowRoot`'s Styles section). This row owns only which style is in
/// effect.
///
/// A pop-up rather than a row of buttons or a segmented control, because style
/// names are user-authored and this card has a fixed width. A segmented
/// `Picker` reports its full-label width as its *minimum*: neither
/// `.lineLimit(1)` nor a `.frame(maxWidth:)` cap makes it truncate — the first
/// is ignored and the second just clips, drawing the control over its
/// neighbours — and at the reachable worst case (five segments at the
/// 24-character `nameLimit`) it pushed the caption and both card edges out of
/// the 480 pt window. A row of separate buttons solved that by tail-truncating
/// the names, and a pop-up keeps the same bargain in a smaller space: only one
/// item shows at a time, and `Bar` below holds every item — the names it
/// shortens, the "Edit Styles…" it pads — to one measured budget, so the bar
/// is a fixed width that fills the row and **no style a user can name will
/// ever grow it**.
///
/// The row sits between the shortcut readout and the Recent list because which
/// style is in effect is the one dictation setting worth changing mid-flow. The
/// choice is **sticky**: a selection holds until the user makes another, so a
/// switch is not something to redo before every dictation.
struct StyleRow: View {
  /// Already decoded and resolved by `ReadyView`, which observes the slots —
  /// this view is pure render-and-write.
  let profiles: [StyleProfile]
  /// The active profile's id, or `nil` for Default — with no profiles defined
  /// the store resolves to the same base styling, so `nil` always shows
  /// Default as the selection.
  let activeID: StyleProfile.ID?
  /// The "Edit Styles…" item's action — opens Settings deep-linked to the
  /// Advanced pane, where styles are edited. Handed down from
  /// `MainWindowRoot`, which sets `AppDelegate.settingsOpensOnAdvanced` before
  /// calling the `openSettings` environment action.
  var editStyles: () -> Void

  /// What a menu item resolves to. `edit` is a *command* parked in the same
  /// menu rather than a style, which is why the selection is a computed
  /// `Binding` (below) instead of stored state: choosing it runs an action and
  /// writes nothing, so the pop-up snaps straight back to the active style.
  private enum Choice: Hashable {
    case defaultStyle
    case profile(StyleProfile.ID)
    case edit
  }

  var body: some View {
    // Left-aligned, so the label starts on the same line the caption above the
    // card starts on and the card's contents read down a single left edge with
    // the Recent list below. The trailing `Spacer` is `minLength: 0` because
    // there is nothing left for it to hold: the bar takes the width the label
    // doesn't.
    //
    // The bar fills the row, but nothing here asks it to: a macOS pop-up hugs
    // its widest *item*, and `.frame(maxWidth: .infinity)` widens only the
    // frame — the bar then draws at its own width, centered in it, adrift in
    // the card. (Checked against a scratch app: a `Picker` with labels hidden
    // at either alignment, and a `Menu` plain or with a `Spacer` in its label,
    // all behave the same. Filling it for real would mean wrapping
    // `NSPopUpButton` with hugging turned off — an AppKit representable for a
    // cosmetic gain.) So the width comes from the item text instead, in `Bar`
    // below: "Edit Styles…" is padded out to the width the card has room for,
    // which makes it the widest item and so the bar's size.
    HStack(spacing: Self.labelSpacing) {
      // The label is its own `Text` rather than the `Picker`'s, because a
      // `Picker` lays its built-in label out *with* the control as one unit and
      // then centers that unit inside whatever frame it's given — so the label
      // drifted off the left edge as soon as the pop-up grew. Split apart, the
      // label anchors left and the bar starts where it ends. The picker keeps
      // the same string as its own (hidden) label so the control still reports
      // a name to VoiceOver.
      Text(Self.label)
      Picker(Self.label, selection: choice) {
        // Writes go through the store — never the raw slot — so the store
        // keeps owning how a choice is encoded (a profile's id, or the
        // store's "default" sentinel; see `HotkeyStepView.selection` for the
        // precedent).
        Text(StyleProfileStore.defaultStyleName).tag(Choice.defaultStyle)
        ForEach(profiles) { profile in
          Text(Bar.fitted(profile.name)).tag(Choice.profile(profile.id))
        }
        // Below the line is the door to where styles are *made*, not another
        // thing to be in effect — the divider is what says so, and it is why
        // this item can share a menu with the selection without reading as
        // one of them. Always offered, including at `profileLimit`: editing
        // and deleting stay useful once adding stops, and Settings enforces
        // the cap on its own Add button.
        Divider()
        Text(Bar.editTitle).tag(Choice.edit)
      }
      // Explicit, not inherited: the pop-up is the whole point (see the type's
      // note on why segmented can't work here), so it doesn't get to change
      // with the context this view is dropped into.
      .pickerStyle(.menu)
      .labelsHidden()
      .accessibilityIdentifier(UITestIdentifiers.styleProfilePickerFromMain)
      Spacer(minLength: 0)
    }
    .background(shortcuts)
    .padding(.horizontal, Self.cardPadding)
    .padding(.vertical, 9)
    // Full width, like the Recent card below: both stretch to the one content
    // width `ReadyView`'s horizontal padding leaves, so the two cards' edges
    // align by construction rather than by matching numbers.
    .frame(maxWidth: .infinity)
    // The Recent card's container, so the two surfaces read as one family:
    // the design's warm card fill with its hairline, rather than the system
    // `.quinary` material this used to take.
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(BlurtBrand.cardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .strokeBorder(BlurtBrand.cardBorder, lineWidth: 1)
    )
  }

  /// The row's own label. Named because `Bar.titleBudget` measures it: the
  /// pop-up gets the width the label leaves, so the two have to be the same
  /// string.
  ///
  /// Trailing colon, the macOS convention for a label introducing a control
  /// (the Settings panes' `Form` rows get theirs from the form; this one is a
  /// bare `HStack`, so it says it).
  private static let label = "Output Styles:"

  /// The gap between the label and the bar, and the card's own inset — both
  /// subtracted by `Bar.titleBudget`. 9 vertical, so the card lands on the
  /// design's 42 pt around a 24 pt control row.
  private static let labelSpacing: CGFloat = 8
  private static let cardPadding: CGFloat = 12

  /// The width of the bar, which is set by the widest item in its menu rather
  /// than by any frame this view can apply (see `body`). Both halves of that
  /// are here so they can't drift apart: `editTitle` pads the one item whose
  /// text we own out to `titleBudget`, and `fitted` holds every user-authored
  /// name at or under the same budget. Together they mean the bar is one fixed
  /// width — it fills the row, and **no style a user can name will ever grow
  /// it**, which matters because a pop-up that outgrew the card would push its
  /// own right edge, and then the window's, past the design's 480 pt.
  private enum Bar {
    /// The font AppKit draws a menu item's title in, so the budget is measured
    /// in the same metrics the pop-up will lay out with.
    private static let font = NSFont.menuFont(ofSize: 0)

    private static func width(_ text: String) -> CGFloat {
      (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The pop-up's own furniture either side of the title: the bezel's insets
    /// and the chevron well. Measured off a build rather than derived — at a
    /// 46 pt allowance the bar landed 7 pt inside the card's padding line, so
    /// the real figure is 39 — and then rounded *up* by 2, because undershoot
    /// leaves a sliver of card while overshoot spills the bar over the card's
    /// edge, and only one of those is worth risking.
    private static let chrome: CGFloat = 41

    /// How many points of title the bar can show with its right edge landing
    /// on the card's. Derived from the same constants the layout uses, so a
    /// change to the window width or the margins moves the budget with it.
    static let titleBudget: CGFloat =
      MainWindow.contentWidth - 2 * MainWindow.contentMargin
      - 2 * StyleRow.cardPadding - width(StyleRow.label) - StyleRow.labelSpacing - chrome

    /// "Edit Styles…" with enough trailing space to make it the widest item.
    /// The padding is non-breaking spaces, not ordinary ones: trailing
    /// whitespace is exactly the sort of thing a text layout is entitled to
    /// trim, and a trimmed pad would silently collapse the bar.
    static let editTitle: String = {
      var padded = "Edit Styles…"
      while width(padded + "\u{00A0}") <= titleBudget { padded += "\u{00A0}" }
      return padded
    }()

    /// A style name shortened to the budget, tail-truncated with an ellipsis.
    /// Names are user-authored up to `nameLimit` (24), and 24 wide glyphs
    /// measure more than the card can show — so the row's own limit is a
    /// width, not a character count, and the full name stays available in
    /// Settings. This is the same trade the button row that preceded this
    /// pop-up made with `.truncationMode(.tail)`; a menu item has no such
    /// modifier, so the shortening happens here.
    static func fitted(_ name: String) -> String {
      guard width(name) > titleBudget else { return name }
      var shortened = name
      while !shortened.isEmpty, width(shortened + "…") > titleBudget {
        shortened.removeLast()
      }
      return shortened + "…"
    }
  }

  /// The pop-up's selection: derived from `activeID` on the way out and
  /// dispatched to the store on the way in, so the store stays the single
  /// owner of what's in effect and this view holds no state that could drift
  /// from it. `.edit` is the exception that makes a computed binding the right
  /// shape — it runs its action and writes nothing, so the next `get` returns
  /// the style that was already selected.
  private var choice: Binding<Choice> {
    Binding(
      get: { activeID.map(Choice.profile) ?? .defaultStyle },
      set: { chosen in
        switch chosen {
        case .defaultStyle:
          StyleProfileStore().activateDefault()
        case .profile(let id):
          // Resolved against the list this view was handed rather than
          // re-read from the store: the tag came from that same list, so a
          // profile deleted underneath us simply finds nothing and no-ops.
          if let profile = profiles.first(where: { $0.id == id }) {
            StyleProfileStore().activate(profile)
          }
        case .edit:
          editStyles()
        }
      })
  }

  /// Keyboard shortcuts for the styles: ⌘1 selects Default, ⌘2…⌘5 the profiles
  /// in menu order. Hidden buttons rather than a `Commands` menu block, because
  /// the scoping is the point: a menu command fires while *any* of the app's
  /// windows is key (Settings included), whereas a button's shortcut is
  /// resolved through the window that hosts it — so these fire exactly while
  /// the main window is key, and not at all while it shows the wizard (this
  /// view doesn't exist then). `.hidden()` keeps the buttons out of sight,
  /// layout (they're parked in `background`) and accessibility while leaving
  /// their shortcuts registered; the writes go through the same store calls as
  /// the pop-up. Every style they reach is also in the pop-up, so nothing here
  /// is *only* reachable by shortcut — but the pop-up now takes a click to
  /// open, which is what makes them worth keeping.
  private var shortcuts: some View {
    Group {
      Button(StyleProfileStore.defaultStyleName) { StyleProfileStore().activateDefault() }
        .keyboardShortcut("1", modifiers: .command)
      // The store caps the list at `profileLimit` (4), so the digits end at ⌘5.
      ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
        Button(profile.name) { StyleProfileStore().activate(profile) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: .command)
      }
    }
    .hidden()
  }
}
