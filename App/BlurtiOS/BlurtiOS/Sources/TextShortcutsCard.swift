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

  var body: some View {
    // Decoded once per redraw, which every keystroke in either field causes.
    let shortcuts = store.shortcuts(decoding: raw)
    // Every shortcut's match key: a phrase one of them holds is refused, as on
    // the Mac, rather than silently replacing that shortcut.
    let takenKeys = Set(shortcuts.map { TextShortcut.matchKey(for: $0.trigger) })
    let canAdd =
      TextShortcut.canSave(trigger: trigger, expansion: expansion, otherKeys: takenKeys)
      && shortcuts.count < TextShortcutStore.shortcutLimit
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow("Text shortcuts")
      if !shortcuts.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
            if index > 0 { Rectangle().fill(BlurtBrand.cardBorder).frame(height: DesignTokens.Metrics.cardBorder) }
            ShortcutRow(shortcut: shortcut) { store.remove(id: shortcut.id) }
          }
        }
      }
      addForm(isTaken: TextShortcut.isTaken(trigger, by: takenKeys), canAdd: canAdd)
      Text("Say the phrase anywhere in a dictation and Blurt types the full text instead. They stay on this phone.")
        .brandFootnote()
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  /// The two fields and the button that add a shortcut, with the note under
  /// the phrase field while another shortcut already holds it.
  private func addForm(isTaken: Bool, canAdd: Bool) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appChipGap) {
      TextField("When I say… (my email)", text: $trigger)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.next)
        .focused($focus, equals: .trigger)
        .onSubmit { focus = .expansion }
        .onChange(of: trigger) { _, value in
          let clamped = TextShortcutStore.clampedTrigger(value)
          if clamped != value { trigger = clamped }
        }
        .brandInput()
      if isTaken {
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
          let clamped = TextShortcutStore.clampedExpansion(value)
          if clamped != value { expansion = clamped }
        }
        .brandInput()
      Button("Add shortcut") { if canAdd { add() } }
        .buttonStyle(BrandButtonStyle())
        .disabled(!canAdd)
    }
  }

  /// Called only when `body`'s `canAdd` holds.
  private func add() {
    store.insertFirst(TextShortcut(trigger: trigger, expansion: expansion))
    trigger = ""
    expansion = ""
    focus = nil
  }
}
