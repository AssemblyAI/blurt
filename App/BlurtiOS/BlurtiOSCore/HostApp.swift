import ObjectiveC
import UIKit

/// The app the keyboard is up in, by bundle id — what the hop carries so the
/// app can bring it back (`BlurtShared.startURL(reason:host:)`, `HopReturn`).
///
/// iOS gives a keyboard no such API. The keyboard's view controller, or one of
/// its parents, has held the host's bundle id as `_hostBundleID` since iOS 8
/// (the way every keyboard that adapts to its host reads it). Private, so it
/// is read without ever asking KVC for a key nothing backs — that raises and
/// would take the keyboard down: a getter is called only when the object
/// responds to it, an ivar read only when the class declares it. Nothing
/// found is nil, and the hop then ends on the app's "◀" hint instead.
package enum HostApp {
  /// The names the id has gone by, tried in this order.
  package static let keys = ["_hostBundleID", "hostBundleID"]

  package static func bundleID(of controller: UIInputViewController) -> String? {
    for object in holders(of: controller) {
      for key in keys {
        if let id = read(key, from: object) { return id }
      }
    }
    return nil
  }

  /// Where the id may be: the controller, its parents up the chain, and its
  /// extension context — by class name, for the log when none has it.
  package static func holderNames(of controller: UIInputViewController) -> [String] {
    holders(of: controller).map { NSStringFromClass(type(of: $0)) }
  }

  private static func holders(of controller: UIInputViewController) -> [NSObject] {
    var holders: [NSObject] = []
    var next: UIViewController? = controller
    while let current = next {
      holders.append(current)
      next = current.parent
    }
    if let context = controller.extensionContext { holders.append(context) }
    return holders
  }

  /// `key` as a getter the object answers to, else as an ivar its class
  /// declares; a bundle id is a non-empty string that is not KVC's "<null>".
  static func read(_ key: String, from object: NSObject) -> String? {
    let selector = NSSelectorFromString(key)
    if object.responds(to: selector) {
      return usable(object.perform(selector)?.takeUnretainedValue())
    }
    var cls: AnyClass? = type(of: object)
    while let current = cls {
      if let ivar = class_getInstanceVariable(current, key) {
        return usable(object_getIvar(object, ivar))
      }
      cls = class_getSuperclass(current)
    }
    return nil
  }

  private static func usable(_ value: Any?) -> String? {
    guard let id = (value as? String).trimmedNonEmpty(), id != "<null>" else { return nil }
    return id
  }
}
