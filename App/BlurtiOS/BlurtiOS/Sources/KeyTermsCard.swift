import AssemblyAI
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// The key terms as the design system's pills, a field to add more, and the
/// list's share link. They live in the App Group, where the keyboard's + adds
/// one on the spot, so this reads and writes the shared slot.
struct KeyTermsCard: View {
  /// The App Group the terms live in — the coordinator's.
  let store: SharedStore
  let contactNames: Int
  /// The list as stored, comma-separated, in `store`: bound in `init`.
  @AppStorage private var raw: String
  @State private var draft = ""

  var body: some View {
    // Parsed once per redraw, which every keystroke in the field causes.
    let terms = KeyTermList.parse(raw)
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow("Key terms")
      if !terms.isEmpty {
        FlowLayout {
          ForEach(terms, id: \.self) { term in
            TermPill(term: term) { store.keyTerms = terms.filter { $0 != term } }
          }
        }
      }
      HStack(spacing: DesignTokens.Metrics.appChipGap) {
        TextField("Add a name or product term", text: $draft)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .submitLabel(.done)
          .onSubmit { add(to: terms) }
          .brandInput()
        Button("Add") { add(to: terms) }
          .buttonStyle(BrandButtonStyle())
          .fixedSize()
          .disabled(KeyTermList.parse(draft).isEmpty || terms.count >= KeyTerms.termCap)
      }
      Text(
        "Spelled exactly as written in every dictation. Separate several with commas, or add one from the "
          + "keyboard with the + beside the mic. \(terms.count) of \(KeyTerms.termCap)."
          + (contactNames > 0 ? " Your \(contactNames) contact names come along automatically." : "")
      )
      .brandFootnote()
      if !terms.isEmpty {
        shareLink(for: terms)
      }
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  init(store: SharedStore, contactNames: Int) {
    self.store = store
    self.contactNames = contactNames
    _raw = AppStorage(wrappedValue: "", SharedStore.keyTermsKey, store: store.defaults)
  }

  /// The whole list, for a friend: a `.blurtterms` file plus the words as text.
  private func shareLink(for terms: [String]) -> some View {
    let pack = TermPack(name: "Key terms", from: nil, terms: terms)

    return ShareLink(
      item: pack,
      subject: Text("Blurt key terms"),
      message: Text(pack.plainText),
      // The share sheet's preview icon, a Transferable image rather than a view, so it
      // takes no accessibility modifiers; the sheet labels the preview with its title.
      // swiftlint:disable:next accessibility_label_for_image
      preview: SharePreview(pack.name, icon: Image(systemName: "text.badge.plus"))
    ) {
      Label("Share key terms", systemImage: "square.and.arrow.up")
        .bodyFont(DesignTokens.Typography.sizeCaption, bold: true)
    }
    .tint(BlurtBrand.accent)
  }

  private func add(to terms: [String]) {
    // Nothing past the request's term cap, so a term that couldn't be sent
    // isn't kept; a list the keyboard's + took over it keeps every term.
    let updated = KeyTermList.appending(draft, to: terms, maxCount: KeyTerms.termCap)
    guard updated != terms else {
      return
    }
    store.keyTerms = updated
    draft = ""
  }
}
