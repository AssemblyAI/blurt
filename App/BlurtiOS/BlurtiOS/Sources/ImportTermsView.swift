import SwiftUI

/// "Add these key terms?" — what a shared list opens into. Every term is
/// ticked; untick any, and Add merges the rest into Blurt's key terms
/// without duplicates.
struct ImportTermsView: View {
  let pack: TermPack
  @Environment(\.dismiss) private var dismiss
  @State private var excluded: Set<String> = []

  private var chosen: [String] { pack.terms.filter { !excluded.contains($0) } }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(pack.terms, id: \.self) { term in
            Toggle(term, isOn: binding(for: term))
          }
        } header: {
          Eyebrow(pack.from.map { "From \($0)" } ?? "Shared with you")
        } footer: {
          Text(
            "They'll ride along with every dictation so Blurt spells them right. Terms you already have are skipped; "
              + "the first \(TermPack.termCap) terms ride each request, so keep the list to what matters.")
        }
      }
      .brandForm()
      .navigationTitle(pack.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add \(chosen.count)") {
            for term in chosen { SharedStore.addKeyTerm(term) }
            dismiss()
          }
          .disabled(chosen.isEmpty)
        }
      }
    }
    .tint(BlurtBrand.accent)
  }

  private func binding(for term: String) -> Binding<Bool> {
    Binding(
      get: { !excluded.contains(term) },
      set: { on in
        if on { excluded.remove(term) } else { excluded.insert(term) }
      })
  }
}
