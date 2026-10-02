import AssemblyAI
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// The Words tab: key terms the speech model should spell exactly, and text
/// shortcuts that turn a spoken phrase into longer text. Both apply to every
/// dictation, from the app and from the keyboard, as on Blurt for Mac.
struct WordsView: View {
  var coordinator: DictationCoordinator
  let showSettings: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appSectionGap) {
        HStack {
          Text("Words")
            .font(BlurtType.heading(DesignTokens.Typography.sizeTitle))
            .foregroundStyle(BlurtBrand.text)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          SettingsButton(action: showSettings)
        }
        .frame(height: DesignTokens.Metrics.appHeaderHeight)
        KeyTermsCard(contactNames: coordinator.lexiconNameCount)
        TextShortcutsCard()
      }
      .padding(.horizontal, DesignTokens.Metrics.appPagePad)
      .padding(.bottom, DesignTokens.Metrics.appSectionGap)
    }
    .scrollDismissesKeyboard(.interactively)
    .page()
  }
}

/// The gear in each tab's header, which opens Settings.
struct SettingsButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "gearshape")
        .font(.system(size: DesignTokens.Metrics.appIcon, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(BlurtBrand.muted)
    }
    .accessibilityLabel("Settings")
  }
}

/// The key terms as the design system's pills, a field to add more, and the
/// list's share link. They live in the App Group, where the keyboard's + adds
/// one on the spot, so this reads and writes the shared slot.
private struct KeyTermsCard: View {
  let contactNames: Int
  @AppStorage(SharedStore.keyTermsKey, store: SharedStore.defaults) private var raw = ""
  @State private var draft = ""

  private var terms: [String] { KeyTerms.parse(raw) }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow("Key terms")
      if !terms.isEmpty {
        FlowLayout {
          ForEach(terms, id: \.self) { term in
            TermPill(term: term) { SharedStore.keyTerms = terms.filter { $0 != term } }
          }
        }
      }
      HStack(spacing: DesignTokens.Metrics.appChipGap) {
        TextField("Add a name or product term", text: $draft)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit(add)
          .brandInput()
        Button("Add", action: add)
          .buttonStyle(BrandButtonStyle())
          .fixedSize()
          .disabled(KeyTerms.parse(draft).isEmpty || terms.count >= KeyTerms.termCap)
      }
      Text(
        "Spelled exactly as written in every dictation. Separate several with commas, or add one from the "
          + "keyboard with the + beside the mic. \(terms.count) of \(KeyTerms.termCap)."
          + (contactNames > 0 ? " Your \(contactNames) contact names come along automatically." : "")
      )
      .brandFootnote()
      if !terms.isEmpty {
        ShareLink(
          item: pack, subject: Text("Blurt key terms"), message: Text(pack.plainText),
          preview: SharePreview(pack.name, icon: Image(systemName: "text.badge.plus"))
        ) {
          Label("Share key terms", systemImage: "square.and.arrow.up")
            .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
        }
        .tint(BlurtBrand.accent)
      }
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  /// The whole list, for a friend: a `.blurtterms` file plus the words as text.
  private var pack: TermPack { TermPack(name: "Key terms", from: nil, terms: terms) }

  private func add() {
    let updated = WordsEdit.addingKeyTerms(draft, to: terms)
    guard updated != terms else { return }
    SharedStore.keyTerms = updated
    draft = ""
  }
}

/// A key term as the design system's pill: full radius, the page's fill inside
/// the card, a hairline, the body face. Its × removes it.
private struct TermPill: View {
  let term: String
  let remove: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Metrics.appLineGap) {
      Text(term)
        .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
        .foregroundStyle(BlurtBrand.text)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: DesignTokens.Typography.sizePillGlyph, weight: .bold))
          .foregroundStyle(BlurtBrand.muted)
          .frame(width: DesignTokens.Metrics.appPillRemove, height: DesignTokens.Metrics.appPillRemove)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(term)")
    }
    .padding(.leading, DesignTokens.Metrics.appChipPadX)
    .padding(.trailing, DesignTokens.Metrics.appPillPadY)
    .padding(.vertical, DesignTokens.Metrics.appPillPadY)
    .background(BlurtBrand.page, in: Capsule())
    .overlay(Capsule().strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
  }
}

/// The text shortcuts, each with its ×, over two fields that add one. The
/// session expands them on the phone (`TextShortcutExpander`), so nothing here
/// goes to AssemblyAI. The store owns the JSON: this binds the raw slot only to
/// redraw, and writes through `TextShortcutStore`.
private struct TextShortcutsCard: View {
  @AppStorage(TextShortcutStore.defaultsKey) private var raw = ""
  @State private var trigger = ""
  @State private var expansion = ""
  @FocusState private var focus: Field?
  private let store = TextShortcutStore()

  private enum Field { case trigger, expansion }

  private var shortcuts: [TextShortcut] { store.shortcuts(decoding: raw) }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow("Text shortcuts")
      if !shortcuts.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
            if index > 0 { Rectangle().fill(BlurtBrand.cardBorder).frame(height: DesignTokens.Metrics.cardBorder) }
            ShortcutRow(shortcut: shortcut) { store.shortcuts = shortcuts.filter { $0.id != shortcut.id } }
          }
        }
      }
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appChipGap) {
        TextField("When I say… (my email)", text: $trigger)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.next)
          .focused($focus, equals: .trigger)
          .onSubmit { focus = .expansion }
          .onChange(of: trigger) { _, value in
            if value.count > TextShortcutStore.triggerLimit {
              trigger = String(value.prefix(TextShortcutStore.triggerLimit))
            }
          }
          .brandInput()
        TextField("Type this (me@example.com)", text: $expansion, axis: .vertical)
          .lineLimit(1...4)  // literal-ok: the field's rows
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($focus, equals: .expansion)
          .onChange(of: expansion) { _, value in
            if value.count > TextShortcutStore.expansionLimit {
              expansion = String(value.prefix(TextShortcutStore.expansionLimit))
            }
          }
          .brandInput()
        Button("Add shortcut", action: add)
          .buttonStyle(BrandButtonStyle())
          .disabled(!canAdd)
      }
      Text("Say the phrase anywhere in a dictation and Blurt types the full text instead. They stay on this phone.")
        .brandFootnote()
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  private var canAdd: Bool {
    WordsEdit.canAddShortcut(trigger: trigger, expansion: expansion)
      && shortcuts.count < TextShortcutStore.shortcutLimit
  }

  private func add() {
    guard canAdd else { return }
    store.shortcuts = WordsEdit.addingShortcut(trigger: trigger, expansion: expansion, to: shortcuts)
    trigger = ""
    expansion = ""
    focus = nil
  }
}

private struct ShortcutRow: View {
  let shortcut: TextShortcut
  let remove: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Metrics.appStackGap) {
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
        Eyebrow(shortcut.trigger, color: BlurtBrand.accent)
        Text(shortcut.expansion)
          .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
          .foregroundStyle(BlurtBrand.text)
          .lineLimit(2)  // literal-ok: two lines of the replacement
      }
      Spacer(minLength: 0)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: DesignTokens.Typography.sizeRemoveGlyph, weight: .semibold))
          .foregroundStyle(BlurtBrand.muted)
          .frame(width: DesignTokens.Metrics.appRowRemove, height: DesignTokens.Metrics.appRowRemove)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(shortcut.trigger)")
    }
    .padding(.vertical, DesignTokens.Metrics.appRowPadY)
  }
}
