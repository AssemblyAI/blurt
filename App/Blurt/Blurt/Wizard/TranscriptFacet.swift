import BlurtEngine

/// The sheet's chips: the transcript itself, the stock transforms, and the
/// user's own request. Titles and symbols are the app's; the instructions
/// behind them are the engine's (`TranscriptTransform`). Raw values key the
/// saved results, so they never change once shipped.
enum TranscriptFacet: String, Hashable, CaseIterable {
  case full, plain, meetingNotes, summary, keyPoints, actionItems, namedEntities, speakerSummary, speakerQuotes, custom

  var title: String {
    switch self {
    case .full: "Full"
    case .plain: "Plain text"
    case .meetingNotes: "Meeting notes"
    case .summary: "Summary"
    case .keyPoints: "Key points"
    case .actionItems: "To-do list"
    case .namedEntities: "Named entities"
    case .speakerSummary: "Speaker summary"
    case .speakerQuotes: "Speaker quotes"
    case .custom: "Custom"
    }
  }

  var systemImage: String {
    switch self {
    case .full: "text.alignleft"
    case .plain: "text.justify.leading"
    case .meetingNotes: "note.text"
    case .summary: "doc.text"
    case .keyPoints: "list.bullet"
    case .actionItems: "checklist"
    case .namedEntities: "person.text.rectangle"
    case .speakerSummary: "person.2"
    case .speakerQuotes: "quote.bubble"
    case .custom: "cube"
    }
  }

  /// What the text area says while this facet is on its way.
  var progressTitle: String {
    switch self {
    case .full, .plain: "Transcribing…"
    case .custom: "Working on it…"
    default: "Writing \(title.lowercased())…"
    }
  }

  /// The engine transform behind this chip; nil for Full, and for Custom
  /// until there is a request.
  func transform(custom: String) -> TranscriptTransform? {
    switch self {
    case .full, .plain: nil
    case .meetingNotes: .meetingNotes
    case .summary: .summary
    case .keyPoints: .keyPoints
    case .actionItems: .actionItems
    case .namedEntities: .namedEntities
    case .speakerSummary: .speakerSummary
    case .speakerQuotes: .speakerQuotes
    case .custom: custom.isEmpty ? nil : .custom(custom)
    }
  }
}
