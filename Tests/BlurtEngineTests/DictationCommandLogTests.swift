import Foundation
import Testing

@testable import BlurtEngine

/// The Control Your Mac half of the developer-mode log: each command as it
/// ended, in `commands.jsonl`, and a failure in `errors.jsonl` too.
@Suite("DictationLog · Commands")
struct DictationCommandLogTests {
  private let screen = ScreenContext(
    appName: "Mail", windowTitle: "Inbox",
    elements: [.init(id: 4, kind: "button", label: "Reply"), .init(id: 7, kind: "row", label: "Lunch")],
    incomplete: true)

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BlurtCommandLogTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("an entry holds what was said, the screen, the plan with each element's label, and how it ended")
  func entry() {
    let steps: [VoiceCommandStep] = [
      .select(7), .pressElement(4), .type("On my way"),
      .shortcut(KeyChord(modifiers: [.command, .shift], key: .character("d"))),
      .openURL(URL(string: "https://example.com/a?b=c")!), .scroll(.down, element: nil),
    ]
    let entry = DictationLog.makeCommandEntry(
      .init(
        command: "reply to lunch saying on my way", context: screen, steps: steps, outcome: .done, failure: nil,
        duration: .milliseconds(1_234)), now: Date(timeIntervalSince1970: 0))
    #expect(entry.command == "reply to lunch saying on my way")
    #expect(entry.app == "Mail")
    #expect(entry.window == "Inbox")
    #expect(entry.elements == 2)
    #expect(entry.incomplete)
    #expect(
      entry.steps == [
        "select #7 (row \"Lunch\")", "press #4 (button \"Reply\")", "type \"On my way\"", "shortcut shift+cmd+d",
        "open_url https://example.com/a?b=c", "scroll down",
      ])
    #expect(entry.outcome == "done")
    #expect(entry.milliseconds == 1_234)
  }

  @Test("a command a press abandoned is logged as abandoned, with the steps that ran before it stopped")
  func abandoned() {
    let entry = DictationLog.makeCommandEntry(
      .init(
        command: "open slack and search for budget", context: screen, steps: [.openApp("Slack"), .type("budget")],
        outcome: nil, failure: nil, duration: .milliseconds(700),
        ran: [StepRecord(step: "open_app Slack", how: "already running", milliseconds: 40, error: nil)]), now: Date())
    #expect(entry.outcome == "abandoned")
    #expect(entry.errorKind == nil)
    #expect(entry.ran.map { $0.step } == ["open_app Slack"])
  }

  @Test("a failure is written to the command log and to the error log, beside the dictations' failures")
  func failureWritesBoth() throws {
    let directory = temporaryDirectory()
    let commands = directory.appendingPathComponent("commands.jsonl")
    let errors = directory.appendingPathComponent("errors.jsonl")
    DictationLog.appendCommand(
      .init(
        command: "open figma", context: screen, steps: [.openApp("Figma")],
        outcome: .error(message: "No app named Figma is installed."),
        failure: ("VoiceCommandError.appNotFound", "No app named Figma is installed."), duration: .milliseconds(900)),
      store: DeveloperModeStore(defaults: enabledDefaults()), to: commands, errorsTo: errors)
    DictationLog.queue.sync {}
    let command = try JSONSerialization.jsonObject(with: Data(contentsOf: commands)) as? [String: Any]
    #expect(command?["outcome"] as? String == "failed")
    #expect(command?["errorKind"] as? String == "VoiceCommandError.appNotFound")
    #expect(command?["steps"] as? [String] == ["open_app Figma"])
    let error = try JSONSerialization.jsonObject(with: Data(contentsOf: errors)) as? [String: Any]
    #expect(error?["kind"] as? String == "command.VoiceCommandError.appNotFound")
    #expect(error?["error"] as? String == "No app named Figma is installed.")
    #expect(error?["app"] as? String == "Mail")
  }

  @Test("with developer mode off nothing is written; a command that worked adds nothing to the error log")
  func gated() {
    let directory = temporaryDirectory()
    let commands = directory.appendingPathComponent("commands.jsonl")
    let errors = directory.appendingPathComponent("errors.jsonl")
    let mute = DictationLog.CommandRecord(
      command: "mute", context: screen, steps: [.media(.mute)], outcome: .done, failure: nil, duration: .zero)
    DictationLog.appendCommand(
      mute, store: DeveloperModeStore(defaults: freshDefaults()), to: commands, errorsTo: errors)
    DictationLog.queue.sync {}
    #expect(!FileManager.default.fileExists(atPath: commands.path(percentEncoded: false)))

    DictationLog.appendCommand(
      mute, store: DeveloperModeStore(defaults: enabledDefaults()), to: commands, errorsTo: errors)
    DictationLog.queue.sync {}
    #expect(FileManager.default.fileExists(atPath: commands.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: errors.path(percentEncoded: false)))
  }

  @Test("the reset sweep removes the command log with the other two")
  func reset() {
    let directory = temporaryDirectory()
    let urls = ["dictations", "errors", "commands"].map { directory.appendingPathComponent("\($0).jsonl") }
    for url in urls { FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data()) }
    #expect(DictationLog.removeStoredLogs(dictations: urls[0], errors: urls[1], commands: urls[2]))
    #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
    #expect(DictationLog.defaultCommandURL.lastPathComponent == "commands.jsonl")
  }

  #if os(macOS)
    @Test("a request the cancel reached first is a cancellation, and a network failure is named by its code")
    func cancellations() {
      #expect(SelectionSpeechRouter.isCancellation(URLError(.cancelled)))
      #expect(SelectionSpeechRouter.isCancellation(CancellationError()))
      #expect(!SelectionSpeechRouter.isCancellation(URLError(.timedOut)))
      #expect(SelectionSpeechRouter.logName(of: URLError(.timedOut)) == "URLError(-1001)")
    }
  #endif

  private func enabledDefaults() -> UserDefaults {
    let defaults = freshDefaults()
    defaults.set(true, forKey: DeveloperModeStore.defaultsKey)
    return defaults
  }

  @Test("an entry carries what the model saw and answered, and how each step ran")
  func entryTrace() {
    let record = DictationLog.CommandRecord(
      id: "abc", command: "reply", context: screen, steps: [.pressElement(4)], outcome: .done, failure: nil,
      duration: .milliseconds(10),
      ran: [StepRecord(step: "press #4 (button \"Reply\")", how: "AXPress", milliseconds: 260, error: nil)],
      trace: .init(prompt: "<window>…</window>", replies: ["{}", "{\"steps\":[]}"], model: "m", promptVersion: "v1"))
    let entry = DictationLog.makeCommandEntry(record, now: Date(timeIntervalSince1970: 0))
    #expect(entry.id == "abc")
    #expect(entry.ran.first?.how == "AXPress")
    #expect(entry.prompt == "<window>…</window>")
    #expect(entry.replies.count == 2)
    #expect(entry.promptVersion == "v1")
  }

  @Test("a complaint is logged against the command it's about, and as a reported failure")
  func feedback() throws {
    let directory = temporaryDirectory()
    let commands = directory.appendingPathComponent("commands.jsonl")
    let errors = directory.appendingPathComponent("errors.jsonl")
    let last = DictationLog.CommandRecord(
      id: "cmd-1", command: "go to github.com", context: screen, steps: [], outcome: .done, failure: nil,
      duration: .zero)
    DictationLog.appendFeedback(
      "that didn't work", about: last, store: DeveloperModeStore(defaults: enabledDefaults()), to: commands,
      errorsTo: errors)
    DictationLog.queue.sync {}
    let entry = try JSONSerialization.jsonObject(with: Data(contentsOf: commands)) as? [String: Any]
    #expect(entry?["feedback"] as? String == "that didn't work")
    #expect(entry?["about"] as? String == "cmd-1")
    #expect(entry?["aboutCommand"] as? String == "go to github.com")
    let error = try JSONSerialization.jsonObject(with: Data(contentsOf: errors)) as? [String: Any]
    #expect(error?["kind"] as? String == "command.userReported")
  }

  @Test("a short complaint is feedback; a command that only mentions it isn't")
  func complaints() {
    for said in [
      "That last command didn't work.", "that didn’t work", "That's wrong", "it failed", "not what I wanted",
      "Nothing works.", "Nothing happened.", "That didn't do anything.",
    ] {
      #expect(CommandFeedback.isComplaint(said), "\(said)")
    }
    for said in [
      "open Slack", "type the wrong answer is four and send it to the team before the meeting starts",
      "undo that", "work on the report",
    ] {
      #expect(!CommandFeedback.isComplaint(said), "\(said)")
    }
  }
}
