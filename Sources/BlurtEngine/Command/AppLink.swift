import Foundation

/// A link that means an app: the planner writes "switch to Slack" as
/// `open_url https://slack.com`, or "open Slack" as a web search for "Slack",
/// however its instruction is worded (2026-11-04) — so an `open_url` that is
/// only an installed app's name, on a command that never asked for the web,
/// opens the app instead.
enum AppLink {
  /// Words that ask for the web itself, which leave a link alone.
  static let webWords = ["website", "web site", "site", "dot com", "search", "google", "web", "page", "look up", "url"]

  /// The name a link stands for, if it's nothing more: a bare site
  /// (`slack.com`, `www.notion.so`) or a web search of a few words.
  static func name(in url: URL) -> String? {
    guard var host = url.host?.lowercased() else {
      return nil
    }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    let labels = host.split(separator: ".")
    if labels.first == "google", url.path == "/search" {
      let items = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false  // mutate-ok: step URLs are absolute, nothing to resolve
      )?.queryItems
      let rawQuery = items?.first { $0.name == "q" }?.value
      // A form-encoded "+" is a space, which `URLComponents` leaves as it is.
      guard let query = rawQuery?.replacingOccurrences(of: "+", with: " "), query.split(separator: " ").count <= 3
      else {
        return nil
      }
      return query
    }
    guard labels.count == 2, url.path.isEmpty || url.path == "/", url.query == nil else {
      return nil
    }
    return String(labels[0])
  }

  static func asksForWeb(_ said: String) -> Bool {
    let words = " " + NameMatch.normalized(said).split { !$0.isLetter && $0 != "." }.joined(separator: " ") + " "
    return said.contains(".") && said.range(of: #"\.[a-z]{2,}"#, options: .regularExpression) != nil
      || webWords.contains { words.contains(" \($0) ") }
  }

  /// `steps` with each link that only names an installed app (`app`, which
  /// answers the app's own name) opening that app — and a bare "open Zoom"
  /// planned as one step of any other kind (a press on Mail's mailbox
  /// "Zoom", 2026-11-04) opening the app it names.
  static func preferApps(
    _ steps: [VoiceCommandStep], said: String, listed: [ScreenContext.Element] = [], app: (String) -> String?
  ) -> [VoiceCommandStep] {
    // A command that's only "open Mail" means the app, whatever single step
    // was planned for it: a link (`mailto:` opened a new message), or a
    // press on something listed by that name.
    if let named = openedName(said), let installed = app(named), let only = steps.onlyElement,
      Self.standsForApp(only, named: named, listed: listed)
    {
      return [.openApp(installed)]
    }
    guard !asksForWeb(said) else {
      return steps
    }
    return steps.map { step in
      guard case .openURL(let url) = step, let name = name(in: url), let installed = app(name) else {
        return step
      }
      return .openApp(installed)
    }
  }

  /// Whether a bare "open X"'s one step can only have meant the app: a link,
  /// ⌘Tab (Preview, 2026-11-04), or a press or select of something listed
  /// under X's own name (Mail's mailbox "Zoom"). Never another shortcut or
  /// a menu item — "go to home" in Finder is ⇧⌘H, not the Home app — nor a
  /// press of something else that's listed.
  static func standsForApp(_ step: VoiceCommandStep, named: String, listed: [ScreenContext.Element]) -> Bool {
    switch step {
    case .openURL:
      return true

    case .shortcut(let chord):
      return chord.spelled == "cmd+tab"

    case .pressElement(let id), .select(let id):
      return listed.first { $0.id == id }.map { NameMatch.normalized($0.label) == NameMatch.normalized(named) } ?? false

    default:
      return false
    }
  }

  /// What a command that's only "open X" (or "switch to", "launch", "go
  /// to") names, else nil.
  static func openedName(_ said: String) -> String? {
    let words = NameMatch.normalized(said).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    for verb in [["open"], ["launch"], ["switch", "to"], ["go", "to"]] where words.starts(with: verb) {
      let rest = words.dropFirst(verb.count).drop { $0 == "the" }
      let name = (rest.last == "app" ? rest.dropLast() : rest[...]).joined(separator: " ")
      return name.isEmpty ? nil : name
    }
    return nil
  }
}
