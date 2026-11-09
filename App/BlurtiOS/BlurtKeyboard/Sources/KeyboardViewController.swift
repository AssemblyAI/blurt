import BlurtDesign
import BlurtiOSCore
import SwiftUI
import UIKit
import os

/// The keyboard's entry point — what iOS instantiates when the user picks Blurt
/// from the globe key. Thin on purpose: it hosts the SwiftUI keyboard, sizes it
/// to the layout the user chose at the profile this phone and OS get
/// (`KeyboardProfile`, built once per appearance), and forwards the lifecycle
/// to `KeyboardModel`, which does the talking to the app. It never hears
/// anything: iOS lets no keyboard use the microphone, so the app listens and
/// this inserts.
final class KeyboardViewController: UIInputViewController, UIGestureRecognizerDelegate {
  private let model = KeyboardModel()
  /// The numbers for this appearance: the OS generation, the width, the
  /// globe. Read again at `viewIsAppearing`, when the host's container is
  /// readable, and the hosted view rebuilt if it changed.
  private var profile = KeyboardProfile.standIn(width: DesignTokens.Metrics.glassReferenceWidth)
  private var host: UIHostingController<KeyboardRootView>?
  /// One line per appearance under the `Container` category: the inset the
  /// host leaves around the keyboard and the profile it decided —
  /// `log show --predicate 'subsystem == "com.assemblyai.blurt.iphone" AND
  /// category == "Container"'` on the simulator reads it (DESIGN.md). Under
  /// the contract's subsystem, as `KeyboardLog` is: the engine's
  /// `HostIdentity` is never configured in the keyboard's process, so its
  /// logger would write under the Mac app's name, where that predicate
  /// never looks.
  nonisolated private static let log = Logger(subsystem: BlurtShared.logSubsystem, category: "Container")
  /// The keyboard's height constraint sits at just under required: iOS
  /// honours a keyboard's height there and fights one at required
  /// (DESIGN.md › The two processes: height change).
  private static let heightPriority: UILayoutPriority = .required - 1

  /// The input view says it wants clicks, so `UIDevice.playInputClick()` on
  /// each key press plays the system's keyboard click — and only if the
  /// user has keyboard clicks on in Settings. Their setting, not ours.
  private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

  }

  private var heightConstraint: NSLayoutConstraint?
  private var hasAppeared = false
  private let floor = UIView()
  /// The host app leaving — resigning active, going to the background —
  /// with the keyboard still up: the field goes with it, so the model ends
  /// a dictation it owns (`KeyboardModel.hostLeaving`). Removed in `deinit`.
  private var hostObservers: [any NSObjectProtocol] = []
  private static let hostLeavingNotifications: [Notification.Name] = [
    .NSExtensionHostWillResignActive, .NSExtensionHostDidEnterBackground,
  ]

  /// The least the floor can be painted and still be the keyboard's to the
  /// host — never zero. In the host material's own colour, so the 1 % adds
  /// nothing the eye can see: 1 % black over the light material was a
  /// keyboard a shade darker than the border around it.
  private static let floorAlpha: CGFloat = 0.01

  override func loadView() {
    view = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
  }

  /// iOS drops a keyboard's controller without a word once the host is done
  /// with it: the model's observers, heartbeat and ticks must not fire into
  /// a keyboard that is gone. A controller is released on the main thread,
  /// which is what lets the main-actor model be told from here.
  deinit {
    MainActor.assumeIsolated {
      for observer in hostObservers { NotificationCenter.default.removeObserver(observer) }
      model.detach()
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    model.attach(to: self)
    hostObservers = Self.hostLeavingNotifications.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        Task { @MainActor in self?.model.hostLeaving() }
      }
    }
    // The floor. The host hands the keyboard only the touches that land on
    // pixels it drew: where the keyboard is fully transparent — and the
    // surface is clear, the host's own material showing through — a touch
    // never reaches this process at all (its hit test is not even asked),
    // and goes to the host's keyboard chrome instead. So the panel's empty
    // space, where a finger swipes the carousel, must be painted, if only
    // just: a floor the eye cannot see but the compositor can (`paintFloor`).
    floor.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(floor)
    let host = UIHostingController(rootView: KeyboardRootView(model: model, profile: profile))
    self.host = host
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
    let height = view.heightAnchor.constraint(equalToConstant: model.effectiveLayout.height(profile: profile))
    height.priority = Self.heightPriority
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
    // A first profile from what is known here (the width, the globe); the
    // container is read for real in viewIsAppearing, once the view is in the
    // host's hierarchy.
    refreshProfile(logging: false)
    paintFloor()
    hasAppeared = true
    view.setNeedsUpdateConstraints()
  }

  /// The host's traits are resolved by now where they may not have been in
  /// `viewWillAppear`: the face is read again here, so a dark host is dark
  /// from the first frame, and so is the container around the keyboard, so
  /// the profile is the one this host gets. Never from a trait-change
  /// registration — that callback runs inside the host's layout pass, and a
  /// model change made there left the mic element's drawing uncommitted in
  /// Messages (nothing drew, every time).
  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    model.contextChanged()
    refreshProfile(logging: true)
    paintFloor()
  }

  /// How far the host insets the keyboard inside its own material, above or
  /// below: the input view's frame against its superview's bounds. Nil
  /// before the view is in a hierarchy.
  private func hostContainerInset() -> CGFloat? {
    guard let superview = view.superview else { return nil }
    let above = view.frame.minY - superview.bounds.minY
    let below = superview.bounds.maxY - view.frame.maxY
    return max(above, below, 0)
  }

  /// The profile for this appearance, and the hosted keyboard rebuilt on it
  /// when it changed: the width the host gives the keyboard, the globe, the
  /// container inset — and the OS, read once by `KeyboardProfile`.
  private func refreshProfile(logging: Bool) {
    let inset = hostContainerInset()
    let width = view.bounds.width > 0 ? view.bounds.width : profile.width
    let next = KeyboardProfile.resolve(width: width, hasGlobe: needsInputModeSwitchKey, hostContainerInset: inset)
    if logging {
      let superview = view.superview.map { "\(type(of: $0)) \($0.bounds.size)" } ?? "none"
      Self.log.info(
        """
        container inset \(inset.map { "\($0)" } ?? "unread", privacy: .public) \
        → \(next.generation.rawValue, privacy: .public) \(next.sizeClass.rawValue, privacy: .public) \
        at \(width, privacy: .public) pt, globe \(next.hasGlobe, privacy: .public); \
        view \(self.view.frame.debugDescription, privacy: .public) in \(superview, privacy: .public); \
        window \(self.view.window?.bounds.size.debugDescription ?? "none", privacy: .public)
        """)
    }
    guard next != profile else { return }
    profile = next
    host?.rootView = KeyboardRootView(model: model, profile: next)
    updateHeight(animated: false)
  }

  /// The floor in the face's material at `floorAlpha`: the host's own
  /// keyboard colour, measured, so nothing shows through the paint but the
  /// touches reach the keyboard.
  private func paintFloor() {
    floor.backgroundColor = UIColor(model.palette(for: profile).material).withAlphaComponent(Self.floorAlpha)
  }

  override func updateViewConstraints() {
    super.updateViewConstraints()
    guard hasAppeared, let heightConstraint else { return }
    heightConstraint.constant = model.effectiveLayout.height(profile: profile)
    if !heightConstraint.isActive { heightConstraint.isActive = true }
  }

  private func updateHeight(animated: Bool) {
    heightConstraint?.constant = model.effectiveLayout.height(profile: profile)
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
