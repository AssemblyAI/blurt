import Foundation

/// The user-facing content of the alert an update check ends in: title, body,
/// button titles, and — for an available update — the URL the default button
/// downloads.
///
/// Owned here rather than in the AppKit shell for the same reason as
/// `OverlayUIState.accessibilityLabel` and `MenuBarStatus.symbolName`: it is a
/// pure projection of an engine result into wording, and the shell that draws it
/// has no test target, so wording assembled at the `NSAlert` call site was
/// covered by nothing. `UpdateCheckModel` keeps only the AppKit plumbing —
/// resolve one of these, build the alert from it, and open `downloadURL` when
/// the default button comes back.
public struct UpdateAlertContent: Equatable, Sendable {
  /// How prominently the shell presents the alert. Only "couldn't check" is a
  /// caution: a result the user asked for isn't a warning.
  public enum Style: Equatable, Sendable {
    case informational
    case warning
  }

  /// Alert title (`NSAlert.messageText`).
  public let title: String
  /// Explanatory body (`NSAlert.informativeText`).
  public let message: String
  /// Button titles in presentation order; the first is the default action.
  /// Never empty — an alert with no button can't be dismissed.
  public let buttons: [String]
  /// What the *default* button downloads, or `nil` when it only dismisses.
  ///
  /// Carrying the URL here is what keeps "which button downloads" from being
  /// re-derived at the call site by matching a button title: the shell opens
  /// this if and only if the first button was chosen.
  public let downloadURL: URL?
  public let style: Style

  /// Private so every value comes from one of the named results below — a new
  /// alert can't be assembled ad hoc in the shell, which is the whole point of
  /// owning the wording here.
  private init(
    title: String, message: String, buttons: [String], downloadURL: URL? = nil,
    style: Style = .informational
  ) {
    self.title = title
    self.message = message
    self.buttons = buttons
    self.downloadURL = downloadURL
    self.style = style
  }

  /// "Blurt 0.1.31" — the running-version label, also shown as the title of the
  /// Settings window's Updates row. Takes an optional so the unparseable-bundle
  /// -version case has one answer too (the bare product name; the check still
  /// works, it just can't name a version). Published here so the alerts and the
  /// Settings row can't word the same fact two ways.
  public static func appVersionLabel(_ version: SemanticVersion?) -> String {
    guard let version else { return productName }
    return "\(productName) \(version)"
  }

  /// The product name as it appears in user-facing copy — distinct from
  /// `BlurtIdentity.subsystem`, which is the reverse-DNS identity.
  private static let productName = "Blurt"

  /// The reassuring result a user-initiated check always shows, so pressing
  /// "Check for Updates" visibly confirms it ran.
  public static func upToDate(current: SemanticVersion) -> UpdateAlertContent {
    UpdateAlertContent(
      title: "You’re up to date",
      message: "\(appVersionLabel(current)) is the latest version.",
      buttons: ["OK"])
  }

  /// A newer release exists. **Download** (the default) opens the release DMG in
  /// the browser; **Later** dismisses. There is no in-place install, so these are
  /// the only two choices — see the manual-update policy in `UpdateChecker`.
  public static func available(
    current: SemanticVersion, latest: SemanticVersion, dmgURL: URL
  ) -> UpdateAlertContent {
    UpdateAlertContent(
      title: "A new version of \(productName) is available",
      message: "\(appVersionLabel(latest)) is available—you have \(current). Download it now?",
      buttons: ["Download", "Later"],
      downloadURL: dmgURL)
  }

  /// A recoverable "couldn't check" — offline, GitHub unreachable, a malformed
  /// response, or a bundle version that wouldn't parse. Every one of those is the
  /// same thing to the user (try again later), which is why `UpdateChecker`
  /// throws rather than enumerating them.
  public static let checkFailed = UpdateAlertContent(
    title: "Couldn’t check for updates",
    message: "Check your internet connection and try again.",
    buttons: ["OK"],
    style: .warning)

  /// The alert an **unprompted** check should show, or `nil` when the result isn't
  /// worth interrupting for. Today only an available update speaks: "you're up to
  /// date" answers a question nobody asked, and a modal saying it at launch is a
  /// nuisance (offline, on a plane, GitHub down).
  ///
  /// Owned here, beside the wording and next to `AutomaticUpdateCheck.shouldRun`,
  /// for the reason the rest of this type is: *whether to speak* is the same class
  /// of rule as *whether to check*, and the shell that applies it has no test
  /// target. It's also exhaustive over `UpdateCheckResult`, so a result added later
  /// has to decide here — the shell previously did this with
  /// `guard case .available = result else { return }`, where a new case would have
  /// silently made the launch check go quiet.
  ///
  /// A check that *failed* never reaches this: it throws, and the caller returns
  /// without a result rather than mapping to `checkFailed`.
  public static func forUnpromptedCheck(
    result: UpdateCheckResult, current: SemanticVersion
  ) -> UpdateAlertContent? {
    switch result {
    case .upToDate: nil
    case .available(let version, let dmgURL):
      .available(current: current, latest: version, dmgURL: dmgURL)
    }
  }

  /// The alert for a completed check. The throwing paths map to `checkFailed`
  /// at the call site, where the error is caught.
  public init(result: UpdateCheckResult, current: SemanticVersion) {
    switch result {
    case .upToDate:
      self = .upToDate(current: current)
    case .available(let version, let dmgURL):
      self = .available(current: current, latest: version, dmgURL: dmgURL)
    }
  }
}
