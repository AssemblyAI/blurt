import AssemblyAI

// Signing out: ending the connection server-side, and forgetting it here.
extension AssemblyAIAccount {
  /// Ends the connection server-side, then forgets it here. Returns the failure
  /// to show, with everything left in place, when the server couldn't confirm:
  /// the connection is still live and its key still works, so claiming a
  /// sign-out would be wrong. A refresh token the server already refuses means
  /// the connection is already over, which counts as signed out. Nil on success.
  public func signOut() async -> APIKeySubmission.FailureReport? {
    // A second click while the first is still talking to the server: that one
    // reports.
    guard !signingOut else {
      return nil
    }
    signingOut = true
    defer { signingOut = false }
    if let renewal { await renewal.value }
    let session: SignInSession
    switch store.load {
    case .session(let stored):
      session = stored

    case .empty:
      forget()
      return nil

    case .unavailable:
      return .inline(message: Self.keychainUnreadableMessage)
    }
    // A build without sign-in configured can't reach the server, but the
    // session it inherited must still be removable: forget it here.
    guard let client else {
      forget()
      return nil
    }
    let started = generation
    do throws(OAuthClient.Failure) {
      // The rotated token is kept before the revoke: one that fails must leave
      // a token that still works.
      let (tokens, _) = try await refresh(session, with: client, generation: started)
      try await client.revoke(accessToken: tokens.accessToken)
    } catch .rejected {
      // Nothing left server-side to end.
    } catch {
      return .inline(message: Self.signOutUnconfirmedMessage)
    }
    // A sign-in that completed while this waited on the server is the user's
    // newer choice; it stays.
    if generation == started { forget() }
    return nil
  }

  /// Drops the session and its key from this Mac without telling the server,
  /// for a connection the server already ended.
  func forget() {
    generation += 1
    store.save(nil)
    apiKey.clear()
    status = .signedOut
  }
}
