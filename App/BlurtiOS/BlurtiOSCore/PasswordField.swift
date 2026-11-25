import UIKit

extension UITextDocumentProxy {
  /// Whether the field the keyboard is attached to holds a password: secure
  /// text entry, or a content type that says so. iOS hands a secure-entry
  /// field to the system keyboard, so the content type is the case a
  /// third-party keyboard actually meets — a sign-up form's or a web page's
  /// password box that doesn't mask. Both traits are optional requirements,
  /// hence the flattening.
  package var isPasswordField: Bool {
    if isSecureTextEntry == true { return true }
    guard let type = textContentType ?? nil else { return false }
    return type == .password || type == .newPassword
  }
}
