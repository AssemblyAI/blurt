import Foundation

/// A Darwin-notification subscription that lives as long as this object does.
///
/// The handler runs on whichever thread the system delivers on and is
/// `@Sendable` for that reason; hop to the main actor inside it when the work
/// is UI. A class rather than a token so `deinit` can deregister — a listener
/// left behind outlives its owner, since the system holds the callback.
nonisolated final class DarwinObserver: Sendable {
  private let name: String
  private let handler: @Sendable () -> Void

  init(name: String, handler: @escaping @Sendable () -> Void) {
    self.name = name
    self.handler = handler
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue().handler()
      }, name as CFString, nil, .deliverImmediately)
  }

  deinit {
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(name as CFString), nil)
  }
}
