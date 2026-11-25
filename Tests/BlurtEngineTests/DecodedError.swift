import Foundation
import Testing

@testable import BlurtEngine

struct DecodedError: Decodable {
  let kind: String
  let error: String
  let ts: String
  let app: String?
  let window: String?
  let field: String?
}
