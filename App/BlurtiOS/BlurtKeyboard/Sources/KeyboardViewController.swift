import BlurtDesign
import BlurtiOSCore
import SwiftUI
import UIKit

/// The keyboard's entry point — what iOS instantiates when the user picks Blurt
/// from the globe key. Thin on purpose: it hosts the SwiftUI keyboard, sizes it
/// to the layout the user chose, and forwards the lifecycle to `KeyboardModel`,
/// which does the talking to the app. It never hears anything: iOS lets no
/// keyboard use the microphone, so the app listens and this inserts.
final class KeyboardViewController: UIInputViewController, UIGestureRecognizerDelegate {
  private let model = KeyboardModel()

  /// The input view says it wants clicks, so `UIDevice.playInputClick()` on
  /// each key press plays the system's keyboard click — and only if the
  /// user has keyboard clicks on in Settings. Their setting, not ours.
  private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

  }

  private var heightConstraint: NSLayoutConstraint?
  private var hasAppeared = false
  private let floor = UIView()

  /// The least the floor can be painted and still be the keyboard's to the
  /// host — never zero. In the host material's own colour, so the 1 % adds
  /// nothing the eye can see: 1 % black over the light material was a
  /// keyboard a shade darker than the border around it.
  private static let floorAlpha: CGFloat = 0.01

  override func loadView() {
    view = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    model.attach(to: self)
    // The floor. The host hands the keyboard only the touches that land on
    // pixels it drew: where the keyboard is fully transparent — and the
    // surface is clear, the host's own material showing through — a touch
    // never reaches this process at all (its hit test is not even asked),
    // and goes to the host's keyboard chrome instead. So the panel's empty
    // space, where a finger swipes the carousel, must be painted, if only
    // just: a floor the eye cannot see but the compositor can (`paintFloor`).
    floor.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(floor)
    let host = UIHostingController(rootView: KeyboardRootView(model: model))
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    host.view.backgroundColor = .clear
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      floor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      floor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      floor.topAnchor.constraint(equalTo: view.topAnchor),
      floor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
    // The carousel's swipe, on the input view itself: it sees every touch the
    // keyboard gets — a key, the mic, the floor — where a SwiftUI gesture on
    // the hosted root only sees what SwiftUI hit-tests. It runs beside
    // SwiftUI's own gestures and cancels none of them: the keys and the mic
    // keep their touch and apply their travel rules (`KeyboardInteraction`),
    // so a swipe across a key never types and one across the mic never
    // dictates.
    let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped))
    swipe.cancelsTouchesInView = false
    swipe.delaysTouchesBegan = false
    swipe.delaysTouchesEnded = false
    swipe.delegate = self
    view.addGestureRecognizer(swipe)
  }

  @objc private func swiped(_ swipe: UIPanGestureRecognizer) {
    guard swipe.state == .ended else { return }
    let travel = swipe.translation(in: view)
    guard let direction = KeyboardInteraction.flip(CGSize(width: travel.x, height: travel.y)) else { return }
    model.flipPanel(towardsLeading: direction == .towardsLeading)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    model.appeared()
    paintFloor()
    hasAppeared = true
    view.setNeedsUpdateConstraints()
  }

  /// The host's traits are resolved by now where they may not have been in
  /// `viewWillAppear`: the face is read again here, so a dark host is dark
  /// from the first frame. Never from a trait-change registration — that
  /// callback runs inside the host's layout pass, and a model change made
  /// there left the mic element's drawing uncommitted in Messages (nothing
  /// drew, every time).
  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    model.contextChanged()
    paintFloor()
  }

  /// The floor in the face's material at `floorAlpha`: the host's own
  /// keyboard colour, measured, so nothing shows through the paint but the
  /// touches reach the keyboard.
  private func paintFloor() {
    floor.backgroundColor = UIColor(model.palette.material).withAlphaComponent(Self.floorAlpha)
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
    // The field's appearance can change with the field.
    paintFloor()
  }

  /// The highlight moved without the text changing — a word selected, or the
  /// selection cleared: the + follows it (`KeyboardModel.selectedTerm`).
  override func selectionDidChange(_ textInput: (any UITextInput)?) {
    super.selectionDidChange(textInput)
    model.contextChanged()
  }
}
