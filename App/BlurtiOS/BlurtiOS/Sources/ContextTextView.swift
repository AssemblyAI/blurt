import SwiftUI
import UIKit

/// A text view with a fixed input context, so iOS restores the keyboard last
/// used in it — the Blurt keyboard, once the user has switched to it here.
final class ContextTextView: UITextView {
  override var textInputContextIdentifier: String? { "com.assemblyai.blurt.iphone.try-it" }
}
