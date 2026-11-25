import BlurtEngine
import SwiftUI

/// The view over the transcript, as a toolbar menu under an AI icon — the
/// transcript itself (Full, and Plain text where it differs), then the stock
/// transforms, then Custom, which asks for its request in a popover. The
/// current view is checked here and named in the window's subtitle.
struct TranscriptFacetMenu: View {
  var model: TranscriptsModel
  @State private var isEditingCustom = false
  @State private var customDraft = ""

  /// Custom is selected only once it has a request: choosing it without one
  /// asks first, and Cancel leaves the selection where it was.
  private var selection: Binding<TranscriptFacet> {
    Binding(
      get: { model.selection },
      set: { facet in
        if facet == .custom, model.customRequest.isEmpty {
          editCustom()
        } else {
          model.select(facet)
        }
      }
    )
  }

  var body: some View {
    let facets = model.availableFacets
    Menu {
      Picker("View", selection: selection) {
        ForEach(facets.filter { $0 == .full || $0 == .plain }, id: \.self, content: item)
        Divider()
        ForEach(facets.filter { ![.full, .plain, .custom].contains($0) }, id: \.self, content: item)
        Divider()
        item(.custom)
      }
      .pickerStyle(.inline)
      // Re-choosing the selected item doesn't reach the binding, so a
      // request already applied is changed from here.
      if model.selection == .custom {
        Button("Edit Custom Request…", action: editCustom)
      }
    } label: {
      Label("View", systemImage: "sparkles")
    }
    .help("Show the transcript or a task on it")
    .accessibilityIdentifier(UITestIdentifiers.facetPicker)
    .popover(isPresented: $isEditingCustom, arrowEdge: .bottom) { customEditor }
  }

  /// Custom's request, asked for under the toolbar's View menu.
  private var customEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("What should Blurt do with this transcript?")
        .font(.headline)
      TextField(
        "Custom request", text: $customDraft, prompt: Text("e.g. Write it up as a blog post"), axis: .vertical
      )
      .lineLimit(2...4)
      .textFieldStyle(.roundedBorder)
      .onSubmit(apply)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { isEditingCustom = false }
          .keyboardShortcut(.cancelAction)
        Button("Apply", action: apply)
          .keyboardShortcut(.defaultAction)
          .disabled(customDraft.trimmedNonEmpty() == nil)
      }
    }
    .padding(14)
    .frame(width: 320)
  }

  /// One view in the menu. Custom reads "Custom…" until it has a request,
  /// since choosing it asks for one first.
  private func item(_ facet: TranscriptFacet) -> some View {
    let title = facet == .custom && model.customRequest.isEmpty ? "Custom…" : facet.title
    return Label(title, systemImage: facet.systemImage).tag(facet)
  }

  private func editCustom() {
    customDraft = model.customRequest
    isEditingCustom = true
  }

  private func apply() {
    model.applyCustom(customDraft)
    isEditingCustom = false
  }
}
