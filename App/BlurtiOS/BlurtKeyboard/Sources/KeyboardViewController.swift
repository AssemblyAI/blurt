import SwiftUI
import UIKit

/// The keyboard's entry point — what iOS instantiates when the user picks Blurt
/// from the globe key. Thin on purpose: it hosts the SwiftUI keyboard, sizes it
/// to the layout the user chose, and forwards the lifecycle to `KeyboardModel`,
/// which does the talking to the app. It never hears anything: iOS lets no
/// keyboard use the microphone, so the app listens and this inserts.
final class KeyboardViewController: UIInputViewController {
  private let model = KeyboardModel()

  /// The input view says it wants clicks, so `UIDevice.playInputClick()` on
  /// each key press plays the system's keyboard click — and only if the
  /// user has keyboard clicks on in Settings. Their setting, not ours.
  private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
  }

  private var heightConstraint: NSLayoutConstraint?
  private var hasAppeared = false

  override func loadView() {
    view = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    model.attach(to: self)
    let host = UIHostingController(rootView: KeyboardRootView(model: model))
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    host.view.backgroundColor = .clear
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    // The keyboard's height is ours to declare, at just under required
    // priority, and only once the view has appeared (from
    // updateViewConstraints): activated from viewDidLoad it fights the host's
    // first layout and the keyboard flashes at the wrong size. What the host
    // draws *around* the keyboard — iOS 26's rounded container, inset above
    // and below — is the host's, and nothing here changes it.
    let height = view.heightAnchor.constraint(equalToConstant: model.effectiveLayout.height)
    height.priority = .required - 1
    heightConstraint = height
    // The panel's carousel changes the keyboard's height when it flips.
    model.onLayoutChange = { [weak self] in self?.updateHeight(animated: true) }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    model.appeared()
    hasAppeared = true
    view.setNeedsUpdateConstraints()
  }

  override func updateViewConstraints() {
    super.updateViewConstraints()
    guard hasAppeared, let heightConstraint else { return }
    heightConstraint.constant = model.effectiveLayout.height
    if !heightConstraint.isActive { heightConstraint.isActive = true }
  }

  private func updateHeight(animated: Bool) {
    heightConstraint?.constant = model.effectiveLayout.height
    view.setNeedsUpdateConstraints()
    guard animated else { return }
    UIView.animate(withDuration: DesignTokens.Motion.heightChange) { self.view.superview?.layoutIfNeeded() }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    model.disappeared()
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    super.textDidChange(textInput)
    model.contextChanged()
  }
}
