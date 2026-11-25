import SwiftUI

/// A spinner beside a word on what it's waiting for: every progress state in
/// the page, spelled once.
struct ProgressLine: View {
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(title).foregroundStyle(.secondary)
    }
  }

  init(_ title: String) { self.title = title }
}
