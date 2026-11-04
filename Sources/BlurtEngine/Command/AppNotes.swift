import Foundation

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

enum AppNotes {
  /// One entry per app, each from a plan that went wrong in it.
  static let all: [AppNote] = [
    AppNote(
      names: ["Google Docs"], titleMark: " - Google Docs",
      text: """
        A heading is Format › Paragraph styles › Heading 1 (to 6), and normal text is Format › Paragraph \
        styles › Normal text. Center, left and right alignment are cmd+shift+e, cmd+shift+l and cmd+shift+r. \
        A numbered list is cmd+shift+7 and a bulleted list cmd+shift+8. Replacing a word is cmd+shift+h, \
        type it, tab, type its replacement, then press_button "Replace all" and escape.
        """),
    AppNote(
      names: ["Slack"],
      text: """
        Going to a channel or a person is cmd+k, type the name, return. Threads is shift+cmd+t. Activity, \
        Home and DMs are listed tabs: press them. Marking a channel as read is escape.
        """),
    AppNote(
      names: ["Terminal"],
      text: """
        "Run" a command is type it, then return, into the window. A new tab is cmd+t. Bigger or smaller \
        text is View › Bigger or View › Smaller.
        """),
    AppNote(
      names: ["TextEdit"],
      text: "Bigger or smaller text is Format › Font › Bigger or Format › Font › Smaller."),
    AppNote(
      names: ["Code", "Visual Studio Code", "VS Code"],
      text: """
        The command palette is shift+cmd+p, opening a file by name cmd+p, then type it and return. Going \
        to a line is ctrl+g. The terminal is ctrl+`, the sidebar cmd+b.
        """),
    AppNote(
      names: ["Mail"],
      text: """
        Getting new mail is shift+cmd+n, a new message cmd+n, searching mail option+cmd+f. Mailboxes \
        (Inbox, Sent, Drafts) are listed rows: select them.
        """),
    AppNote(
      names: ["Preview"],
      text: """
        The next or previous page is down or up, the first or last page home or end. A page by its number \
        is Go › Go to Page…, type the number, return.
        """),
    AppNote(
      names: ["Safari"],
      // Not shift+cmd+\: a backslash the model writes into its JSON reply
      // ends the string early, and the reply ran on to the token cap.
      text: "Reader mode is shift+cmd+r. Showing all tabs is View › Show Tab Overview."),
  ]

  /// The notes for a command said over `context`: the front app's, the web
  /// app's in a front browser window, then any app the command names.
  static func notes(for command: String, in context: ScreenContext, from table: [AppNote] = all) -> [AppNote] {
    let front = context.appName.map(NameMatch.normalized)
    let title = context.windowTitle ?? ""
    let said = " " + NameMatch.normalized(command).split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
    return table.filter { note in
      if let mark = note.titleMark, title.contains(mark) { return true }
      return note.names.contains { name in
        NameMatch.normalized(name) == front || said.contains(" \(NameMatch.normalized(name)) ")
      }
    }
  }

  /// The notes as the user turn carries them, or nil for none.
  static func promptText(_ notes: [AppNote]) -> String? {
    guard !notes.isEmpty else { return nil }
    let lines = notes.map { "\($0.names[0]): \($0.text)" }
    return "<app_notes>\n" + lines.joined(separator: "\n") + "\n</app_notes>"
  }

  /// Every note's text, for the prompt version: a changed note is a changed prompt.
  static var versionText: String { all.map { $0.names.joined() + $0.text }.joined(separator: "\n") }
}
