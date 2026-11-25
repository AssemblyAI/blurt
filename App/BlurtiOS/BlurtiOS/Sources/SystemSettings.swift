import AVFoundation
import UIKit

/// Blurt's page in the Settings app.
enum SystemSettings {
  static func open() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      return
    }
    UIApplication.shared.open(url)
  }
}
