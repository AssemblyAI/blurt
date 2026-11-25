public import Foundation

/// What Blurt keeps about a "Sign in with AssemblyAI" connection, beside the API
/// key itself (which lives in the ordinary key item, so every reader of the key
/// works unchanged whether it was pasted or signed in for).
public struct SignInSession: Codable, Sendable, Equatable {
  /// Without `keyRotatesAt`, renew this far ahead of the key's expiry (the
  /// server's usual rotation window), so the next key is in place before the
  /// old one stops working mid-dictation. One renewal per key is all the
  /// refresh token needs: its sliding lifetime (three months) dwarfs a key's
  /// (two weeks).
  public static let expiryMargin: TimeInterval = 2 * 24 * 60 * 60
  /// When the exchange didn't say when the key expires: renew this long after
  /// the last renewal instead.
  public static let unknownExpiryInterval: TimeInterval = 24 * 60 * 60

  /// Mints fresh access tokens. Rotated by the server on some refreshes, so the
  /// latest one is always written back.
  public var refreshToken: String
  /// Who signed in, for the account row. Nil when the ID token didn't say.
  public var email: String?
  /// When the connection's key stops working, as the exchange reported it.
  public var keyExpiresAt: Date?
  /// When to renew: from when the exchange mints the next key, as it reported
  /// it (`api_key_rotates_at`). Nil from a server that doesn't say, or a
  /// session saved before it did.
  public var keyRotatesAt: Date?
  /// The last successful refresh and exchange.
  public var renewedAt: Date

  /// When the next renewal is due: when the server said the key rotates, else
  /// `expiryMargin` before it expires.
  public var renewalDue: Date {
    keyRotatesAt
      ?? keyExpiresAt.map { $0.addingTimeInterval(-Self.expiryMargin) }
      ?? renewedAt.addingTimeInterval(Self.unknownExpiryInterval)
  }

  public init(
    refreshToken: String, email: String?, keyExpiresAt: Date?, renewedAt: Date, keyRotatesAt: Date? = nil
  ) {
    self.refreshToken = refreshToken
    self.email = email
    self.keyExpiresAt = keyExpiresAt
    self.keyRotatesAt = keyRotatesAt
    self.renewedAt = renewedAt
  }

  /// After a renewal that brought back a key still due for renewal (a server
  /// that didn't rotate it early): push the next renewal to the key's expiry,
  /// when any server rotates, or once it has expired, a day out, rather than
  /// asking again every minute. A dictation the key fails meanwhile still
  /// renews at once (`AssemblyAIAccount.keyWasRejected`).
  mutating func deferRenewalIfStillDue(now: Date) {
    guard renewalDue <= now else {
      return
    }
    if let keyExpiresAt, keyExpiresAt > now {
      keyRotatesAt = keyExpiresAt
    } else {
      keyRotatesAt = now.addingTimeInterval(Self.unknownExpiryInterval)
    }
  }

  /// Whether a renewal should refresh and exchange now: it's due, or no key is
  /// stored at all.
  public func isRenewalDue(now: Date, hasKey: Bool) -> Bool {
    !hasKey || now >= renewalDue
  }
}

extension JSONEncoder {
  static var signIn: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  static var signIn: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
