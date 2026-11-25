/// When the app, brought forward by the keyboard's hop, goes back to the app
/// the keyboard was in: once the record says the window is open and the mic
/// will stay live without the app in front — at once under a held mic (the
/// capture, started in front, carries on), once the keeper reports under
/// Picture in Picture (`ListeningState.idle == .pip`), or at
/// `BlurtShared.hopReturnCap` past the open if it has not. Pure: the
/// coordinator reads it off every record it publishes.
package nonisolated enum HopReturn {
  package static func isReady(_ record: ListeningState, keeperExpected: Bool, capPassed: Bool) -> Bool {
    record.window == .open && (!keeperExpected || record.idle == .pip || capPassed)
  }
}
