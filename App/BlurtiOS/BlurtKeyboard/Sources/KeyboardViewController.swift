import BlurtiOSCore
import KeyboardKit
import SwiftUI
import UIKit

/// The keyboard's entry point — what iOS instantiates when the user picks Blurt
/// from the globe key. KeyboardKit's controller draws Apple's keyboard
/// (`KeyboardView`) and owns the view, its height, its gestures and its
/// pages; this adds Blurt's own (`BlurtKeyboardView`, `BlurtActionHandler`)
/// and forwards the lifecycle to `KeyboardModel`, which does the talking to
/// the app. It never hears anything: iOS lets no keyboard use the microphone,
/// so the app listens and this inserts.
final class KeyboardViewController: KeyboardInputViewController {
  private let model = BlurtiOSCore.KeyboardModel()
  /// The host app leaving — resigning active, going to the background —
  /// with the keyboard still up: the field goes with it, so the model ends
  /// a dictation it owns (`KeyboardModel.hostLeaving`). Removed in `deinit`.
  private var hostObservers: [any NSObjectProtocol] = []
  private static let hostLeavingNotifications: [Notification.Name] = [
    .NSExtensionHostWillResignActive, .NSExtensionHostDidEnterBackground,
  ]

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
  }

  /// KeyboardKit's setup, with Blurt's action handler in place first, as its
  /// docs have it: the free core, no licence, English only (`KeyboardApp.blurt`).
  override func viewWillSetupKeyboardKit() {
    super.viewWillSetupKeyboardKit()
    let handler = BlurtActionHandler(controller: self)
    handler.model = model
    services.actionHandler = handler
    setupKeyboardKit(for: .blurt) { [weak self] _ in self?.configureState() }
  }

  /// Apple's keyboard as Apple ships it: the emoji switcher's slot goes to
  /// the mic (there is no emoji keyboard on the free core), a hold on the
  /// space bar moves the cursor, and autocorrect — Pro, not wired — is off.
  private func configureState() {
    state.emojiSettings.isEmojiSwitcherEnabled = false
    state.keyboardSettings.spacebarLongPressBehavior = .moveInputCursor
    state.autocompleteSettings.isAutocorrectEnabled = false
  }

  /// Not `super`: KeyboardKit says it costs extra draw passes. The model,
  /// never `self`, is captured — the builder outlives this controller's own
  /// references, and a captured self would leak it.
  override func viewWillSetupKeyboardView() {
    let model = self.model
    setupKeyboardView { controller in
      BlurtKeyboardView(services: controller.services, state: controller.state, model: model)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    model.appeared()
  }

  /// The host's traits and text are resolved by now where they may not have
  /// been in `viewWillAppear`. Never from a trait-change registration — that
  /// callback runs inside the host's layout pass, and a model change made
  /// there left the mic's drawing uncommitted in Messages (nothing drew,
  /// every time).
  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    model.contextChanged()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    model.disappeared()
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    super.textDidChange(textInput)
    model.contextChanged()
    applyTermCase()
  }

  /// The highlight moved without the text changing — a word selected, or the
  /// selection cleared: the + follows it (`KeyboardModel.selectedTerm`).
  override func selectionDidChange(_ textInput: (any UITextInput)?) {
    super.selectionDidChange(textInput)
    model.contextChanged()
  }

  /// While the term field is open, the case is the term's rule, not the
  /// host's sentence: KeyboardKit re-reads the host on every text change
  /// (the hardware-typing claim deletes back from it), and the term's rule
  /// must win.
  private func applyTermCase() {
    guard model.termDraft != nil else { return }
    state.keyboardContext.keyboardCase = model.termWantsUppercase ? .uppercased : .lowercased
  }
}
