import Testing

@testable import BlurtEngine

/// Which apps' notes a command's plan is given.
@Suite("AppNotes")
struct AppNotesTests {
  private func names(_ command: String, app: String?, window: String? = nil) -> [String] {
    AppNotes.notes(for: command, in: ScreenContext(appName: app, windowTitle: window)).map { $0.names[0] }
  }

  @Test("the front app's note, the web app's in a browser window, and an app the command names")
  func matching() {
    #expect(names("close this tab", app: "Terminal") == ["Terminal"])
    #expect(
      names("make this a heading", app: "Google Chrome", window: "Plan - Google Docs - Google Chrome - Alex (Work)")
        == ["Google Docs"])
    #expect(names("open Slack and go to incidents", app: "Google Chrome") == ["Slack"])
    #expect(names("open the command palette", app: "Code") == ["Visual Studio Code"].map { _ in "Code" })
    // Nothing for an app with none, or a word that only contains an app's name.
    #expect(names("mute", app: "Finder").isEmpty)
    #expect(names("open slackware docs", app: "Finder").isEmpty)
  }

  @Test("notes ride the user turn, after the window and before the command; none, nothing")
  func prompt() {
    let turn = VoiceCommandPlanner.prompt("new tab", context: ScreenContext(appName: "Terminal"), fence: "f")
    #expect(turn.contains("<app_notes>\nTerminal: "))
    #expect(turn.hasSuffix("</app_notes>\n\n<spoken_command>\nnew tab\n</spoken_command>"))
    #expect(!VoiceCommandPlanner.prompt("mute", context: ScreenContext(appName: "Finder")).contains("app_notes"))
    #expect(AppNotes.promptText([]) == nil)
  }
}
