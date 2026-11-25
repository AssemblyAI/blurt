/// What the planner is told about one app, only when it's relevant: the
/// app is in front, it's the web app in the front browser window, or the
/// command names it ("open Slack and go to incidents", said over Chrome —
/// the steps after `open_app` happen in Slack). Kept out of the base
/// instruction: there, each app's advice reached every other app's plans —
/// Docs' "normal text" became a find-and-select (2026-11-04).
struct AppNote: Sendable, Equatable {
  /// The app's name as the screen read names it (`ScreenContext.appName`)
  /// and as a command would say it.
  let names: [String]
  /// For a web app: what the front browser window's title carries for it —
  /// " - Google Docs", which Chrome follows with its own name and profile.
  var titleMark: String?
  /// A few lines of what plans in it need: shortcuts it has, the menu an
  /// item is really in, what a command it often hears means.
  let text: String
}
