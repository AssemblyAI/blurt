extension AppCoordinator {
  /// Spawns a MainActor observer that runs `action` for each value of `stream`
  /// until cancelled — the shared shape behind the level/transcript observers.
  /// (`observePhases` stays separate: it must `await` the session for its
  /// stream before it can loop.)
  func observe<Value>(
    _ stream: AsyncStream<Value>,
    _ action: @escaping @MainActor (AppCoordinator, Value) -> Void
  ) -> Task<Void, Never> {
    Task { [weak self] in
      for await value in stream {
        guard let self else {
          return
        }
        if Task.isCancelled {
          return
        }
        action(self, value)
      }
    }
  }
}
