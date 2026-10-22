import BlurtDesign
import SwiftUI
import UIKit

/// "Try it here": a text box on the home screen for trying the Blurt keyboard
/// without leaving the app. iOS offers no public way for an app to choose a
/// third-party keyboard for its own field, but it remembers the keyboard last
/// used in a field that names itself (`textInputContextIdentifier`), so after
/// the first switch with the globe key the box opens on Blurt every time. The
/// keyboard inserts at the cursor, so dictating mid-sentence lands there.
struct TryItBox: View {
  @State private var text = ""

  var body: some View {
    RememberingTextView(text: $text)
      .frame(minHeight: DesignTokens.Metrics.appTryBoxHeight, alignment: .topLeading)
      .overlay(alignment: .topLeading) {
        if text.isEmpty {
          Text("Try it here")
            .font(BlurtType.body(DesignTokens.Typography.sizeBody))
            .foregroundStyle(BlurtBrand.muted)
            .allowsHitTesting(false)
        }
      }
      .brandInput()
  }
}

/// The box's text view, in UIKit because only a `UIResponder` can name its
/// input context, which is what makes iOS remember the keyboard chosen in it.
private struct RememberingTextView: UIViewRepresentable {
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

  func updateUIView(_ view: ContextTextView, context: Context) {
    if view.text != text { view.text = text }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContextTextView, context: Context) -> CGSize? {
    guard let width = proposal.width else { return nil }
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: fitted.height)
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, UITextViewDelegate {
    private let text: Binding<String>

    init(text: Binding<String>) { self.text = text }

    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text
    }
  }
}

/// A text view with a fixed input context, so iOS restores the keyboard last
/// used in it — the Blurt keyboard, once the user has switched to it here.
private final class ContextTextView: UITextView {
  override var textInputContextIdentifier: String? { "com.assemblyai.blurt.iphone.try-it" }
}
