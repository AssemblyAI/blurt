import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
  /// A shared list of Blurt key terms: JSON, `.blurtterms`, declared in
  /// `project.yml` so a tap on one in Messages opens Blurt.
  package nonisolated static let blurtTerms = UTType(exportedAs: "com.assemblyai.blurt.terms", conformingTo: .json)
}

/// A list of key terms on its way to a friend — a group chat's names and
/// slang, so everyone's dictation gets them right. Shared as a `.blurtterms`
/// file (the share sheet writes it), opened by a tap; also readable from a
/// `blurt://terms?add=a,b,c&name=…&from=…` link.
package nonisolated struct TermPack: Codable, Identifiable, Transferable {
  package var name: String
  package var from: String?
  package var terms: [String]

  package init(name: String, from: String?, terms: [String]) {
    self.name = name
    self.from = from
    self.terms = terms
  }

  package var id: String { "\(name)|\(from ?? "")|\(terms.joined(separator: ","))" }

  /// The request's own cap on key terms (`keyterms_prompt`, 100), which is
  /// also as many as a list is worth; a file over this size, or a term, name
  /// or sender longer than a line, is refused.
  package static let termCap = 100
  package static let fileCap = 64 * 1024
  package static let lengthCap = 80

  package static var transferRepresentation: some TransferRepresentation {
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

  /// The shared file's name: the list's name with anything a file name can't
  /// carry taken out, or a plain one when nothing is left.
  var fileStem: String {
    let stem = name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
      .trimmingCharacters(in: .whitespaces)
    return stem.isEmpty ? "Blurt key terms" : stem
  }

  /// The list as plain text, for the message beside the file — a friend
  /// without Blurt still gets the words.
  package var plainText: String {
    let lead = from.map { "\($0)'s Blurt key terms" } ?? "Blurt key terms"
    return "\(lead) (\(name)): \(KeyTermList.join(terms))"
  }

  /// Whether a URL is meant to be a pack at all — a `.blurtterms` file or a
  /// `blurt://terms` link — so a broken one can be reported rather than
  /// ignored.
  package static func looksLikePack(_ url: URL) -> Bool {
    if url.isFileURL { return url.pathExtension.lowercased() == "blurtterms" }
    return url.scheme == BlurtShared.urlScheme && url.host() == "terms"
  }

  /// A pack from a file tapped in Messages or a `blurt://terms` link; nil for
  /// anything else the app is asked to open, or a pack over the caps. A file
  /// iOS handed over in the app's Inbox is deleted once read.
  package static func from(_ url: URL) -> TermPack? {
    guard looksLikePack(url) else { return nil }
    if url.isFileURL {
      defer { if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) } }
      guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= fileCap,
        let data = try? Data(contentsOf: url), let pack = try? JSONDecoder().decode(TermPack.self, from: data)
      else { return nil }
      return pack.capped()
    }
    guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    let value = { (name: String) in items.first { $0.name == name }?.value }
    return TermPack(
      name: value("name") ?? "Shared key terms", from: value("from"), terms: KeyTermList.parse(value("add") ?? "")
    ).capped()
  }

  /// The pack within the caps, or nil when nothing usable is left.
  private func capped() -> TermPack? {
    let kept = KeyTermList.parse(KeyTermList.join(terms)).filter { $0.count <= Self.lengthCap }
    let terms = Array(kept.prefix(Self.termCap))
    guard !terms.isEmpty else { return nil }
    return TermPack(
      name: String(name.prefix(Self.lengthCap)), from: from.map { String($0.prefix(Self.lengthCap)) }, terms: terms)
  }
}
