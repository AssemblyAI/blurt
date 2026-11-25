import Foundation

struct UploadResponse: Decodable {
  enum CodingKeys: String, CodingKey {
    case uploadURL = "upload_url"
  }

  let uploadURL: URL
}
