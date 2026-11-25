import BlurtDesign
import SwiftUI
import UIKit

/// The box's text view, in UIKit because only a `UIResponder` can name its
/// input context, which is what makes iOS remember the keyboard chosen in it.
struct RememberingTextView: UIViewRepresentable {
  final class Coordinator: NSObject, UITextViewDelegate {
    private let text: Binding<String>

    init(text: Binding<String>) { self.text = text }

    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text
    }
  }

  @Binding var text: String

  func makeUIView(context: Context) -> ContextTextView {
    let view = ContextTextView()
    view.delegate = context.coordinator
    view.font = .systemFont(ofSize: DesignTokens.Typography.sizeBody)
    view.textColor = UIColor(BlurtBrand.text)
    view.backgroundColor = .clear
    // Growing with its text, as the brand's inputs do, rather than scrolling.
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.accessibilityLabel = "Try it here"
    return view
  }

  func updateUIView(_ view: ContextTextView, context _: Context) {
    if view.text != text { view.text = text }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContextTextView, context _: Context) -> CGSize? {
    guard let width = proposal.width else {
      return nil
    }
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: fitted.height)
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
}
