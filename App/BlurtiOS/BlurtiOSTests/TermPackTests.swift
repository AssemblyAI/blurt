import Foundation
import Testing

@testable import BlurtiOS

@Suite("Term packs")
struct TermPackTests {
  @Test("a blurt://terms link carries terms, a name and a sender")
  func link() throws {
    let url = try #require(URL(string: "blurt://terms?add=Rizz,Skibidi,%20rizz%20&name=Group%20chat&from=Neil"))
    let pack = try #require(TermPack.from(url))
    #expect(pack.terms == ["Rizz", "Skibidi"])
    #expect(pack.name == "Group chat")
    #expect(pack.from == "Neil")
  }

  @Test("a link with no terms, or any other link, is not a pack")
  func notAPack() throws {
    #expect(TermPack.from(try #require(URL(string: "blurt://terms?add="))) == nil)
    #expect(TermPack.from(try #require(URL(string: "blurt://start"))) == nil)
    #expect(TermPack.from(try #require(URL(string: "https://example.com/?add=a"))) == nil)
  }

  @Test("a .blurtterms file round-trips and is parsed by the key-term rules")
  func file() throws {
    let pack = TermPack(name: "Chat", from: "Neil", terms: ["Rizz", "rizz", " Blurt "])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).blurtterms")
    try JSONEncoder().encode(pack).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let read = try #require(TermPack.from(url))
    #expect(read.terms == ["Rizz", "Blurt"])
    #expect(read.name == "Chat")
  }

  @Test("the plain text names the sender and lists the words")
  func plainText() {
    let pack = TermPack(name: "Chat", from: "Neil", terms: ["Rizz", "Blurt"])
    #expect(pack.plainText == "Neil's Blurt key terms (Chat): Rizz, Blurt")
  }
}
