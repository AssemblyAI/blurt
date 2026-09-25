import SwiftUI
import UIKit

/// The keyboard's entry point — what iOS instantiates when the user picks Blurt
/// from the globe key. Thin on purpose: it hosts the SwiftUI keyboard, sizes it
/// to the layout the user chose, and forwards the lifecycle to `KeyboardModel`,
/// which does the talking to the app. It never hears anything: iOS lets no
/// keyboard use the microphone, so the app listens and this inserts.
final class KeyboardViewController: UIInputViewController {
  private let model = KeyboardModel()
  private var heightConstraint: NSLayoutConstraint?

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
    // The keyboard's height is ours to declare; iOS honours a constraint on the
    // input view at just under required priority.
    let height = view.heightAnchor.constraint(equalToConstant: model.layout.height)
    height.priority = UILayoutPriority(999)
    height.isActive = true
    heightConstraint = height
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    model.appeared()
    heightConstraint?.constant = model.layout.height
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
