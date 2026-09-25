import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
  /// A shared list of Blurt key terms: JSON, `.blurtterms`, declared in
  /// `project.yml` so a tap on one in Messages opens Blurt.
  nonisolated static let blurtTerms = UTType(exportedAs: "dev.alex.blurt.terms", conformingTo: .json)
}

/// A list of key terms on its way to a friend — a group chat's names and
/// slang, so everyone's dictation gets them right. Shared as a `.blurtterms`
/// file (the share sheet writes it), opened by a tap; also readable from a
/// `blurt://terms?add=a,b,c&name=…&from=…` link.
nonisolated struct TermPack: Codable, Hashable, Transferable {
  var name: String
  var from: String?
  var terms: [String]

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .blurtTerms) { pack in
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(pack.fileStem, isDirectory: false)
        .appendingPathExtension("blurtterms")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(pack).write(to: url, options: .atomic)
      return SentTransferredFile(url)
    }
  }

  private var fileStem: String {
    let stem = name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
      .trimmingCharacters(in: .whitespaces)
    return stem.isEmpty ? "Blurt key terms" : stem
  }

  /// The list as plain text, for the message beside the file — a friend
  /// without Blurt still gets the words.
  var plainText: String {
    let lead = from.map { "\($0)'s Blurt key terms" } ?? "Blurt key terms"
    return "\(lead) (\(name)): \(KeyTermList.join(terms))"
  }

  /// A pack from a file tapped in Messages or a `blurt://terms` link; nil for
  /// anything else the app is asked to open.
  static func from(_ url: URL) -> TermPack? {
    if url.isFileURL {
      guard url.pathExtension.lowercased() == "blurtterms", let data = try? Data(contentsOf: url),
        var pack = try? JSONDecoder().decode(TermPack.self, from: data)
      else { return nil }
      pack.terms = KeyTermList.parse(KeyTermList.join(pack.terms))
      return pack.terms.isEmpty ? nil : pack
    }
    guard url.scheme == BlurtShared.urlScheme, url.host() == "terms",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    let value = { (name: String) in items.first { $0.name == name }?.value }
    let terms = KeyTermList.parse(value("add") ?? "")
    guard !terms.isEmpty else { return nil }
    return TermPack(name: value("name") ?? "Shared key terms", from: value("from"), terms: terms)
  }
}
