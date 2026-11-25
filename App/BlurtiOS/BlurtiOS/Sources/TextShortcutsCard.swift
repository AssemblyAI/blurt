import BlurtDesign
import BlurtEngine
import SwiftUI

/// The text shortcuts, each with its ×, over two fields that add one. The
/// session expands them on the phone (`TextShortcutExpander`), so nothing here
/// goes to AssemblyAI. The store owns the JSON: this binds the raw slot only to
/// redraw, and writes through `TextShortcutStore`.
struct TextShortcutsCard: View {
  private enum Field { case trigger, expansion }

  @AppStorage(TextShortcutStore.defaultsKey)
  private var raw = ""
  @State private var trigger = ""
  @State private var expansion = ""
  @FocusState private var focus: Field?
  private let store = TextShortcutStore()

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
      addForm
      Text("Say the phrase anywhere in a dictation and Blurt types the full text instead. They stay on this phone.")
        .brandFootnote()
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  /// The two fields and the button that add a shortcut.
  private var addForm: some View {
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
      if TextShortcut.isTaken(trigger, by: takenKeys) {
        Text("Another shortcut already uses this phrase.")
          .bodyFont(DesignTokens.Typography.sizeCaption)
          .foregroundStyle(BlurtBrand.errorOrange)
          .fixedSize(horizontal: false, vertical: true)
      }
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
  }

  /// Every shortcut's match key: a phrase one of them holds is refused, as on
  /// the Mac, rather than silently replacing that shortcut.
  private var takenKeys: Set<String> { Set(shortcuts.map { TextShortcut.matchKey(for: $0.trigger) }) }

  private var canAdd: Bool {
    TextShortcut.canSave(trigger: trigger, expansion: expansion, otherKeys: takenKeys)
      && shortcuts.count < TextShortcutStore.shortcutLimit
  }

  private func add() {
    guard canAdd else {
      return
    }
    store.shortcuts = [TextShortcut(trigger: trigger, expansion: expansion)] + shortcuts
    trigger = ""
    expansion = ""
    focus = nil
  }
}
