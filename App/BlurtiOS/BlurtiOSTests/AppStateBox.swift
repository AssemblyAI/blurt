import UIKit

/// The application's state, as the window reads it.
@MainActor
final class AppStateBox {
  var state = UIApplication.State.active
}
